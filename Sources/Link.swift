// 已配对两台之间「保持连着」的那层：不依赖固定 IP，断线、开机、换 IP 都能自己恢复。
//   - 两台都在 TCP 24810 监听，并用 Bonjour 广播 _mackvm._tcp（TXT 里带本机设备 ID）；
//   - 设备 ID 小的那台负责主动连接：浏览 _mackvm._tcp 按设备 ID 找到对方，连不上时改连上次成功的 IP，
//     两种目标轮流试，每 2 秒一次；ID 大的那台只等着被连。
//     这样连接方向和谁是主控无关：对调角色不用重新建连，任一台先启动都能连上。
//   - 新连接通过密钥校验后才顶替旧连接（没有密钥的人连上来挤不掉正在用的连接）。
// 连上之后收发什么消息归 AppModel / 角色对象管，这里只负责连接本身。

import CryptoKit
import Foundation
import Network

let kLinkPort: UInt16 = 24810

final class Link {
    let me: DeviceIdentity
    let peerID: String
    let key: SymmetricKey
    let port: UInt16            // 本机监听端口
    let peerPort: UInt16        // 按 IP 后备连接时对方的端口
    let useBonjour: Bool
    let serviceType: String
    var lastAddress: String?

    var onAuthenticated: ((Peer) -> Void)?
    var onMessage: ((Peer, Msg, Data) -> Void)?
    var onDisconnected: (() -> Void)?
    var onAddressLearned: ((String) -> Void)?

    private(set) var active: Peer?
    private var pending: [ObjectIdentifier: Peer] = [:]
    private var listener: NWListener?
    private var browser: BonjourBrowser?
    private var bonjourEndpoint: NWEndpoint?
    private var dialing: Peer?
    private var failStreak = 0
    private var attempt = 0
    private var stopped = true
    private var connectTimer: DispatchSourceTimer?

    var isInitiator: Bool { me.id < peerID }

    init(me: DeviceIdentity, peerID: String, key: SymmetricKey, lastAddress: String?,
         port: UInt16 = kLinkPort, peerPort: UInt16 = kLinkPort,
         useBonjour: Bool = true, serviceType: String = kLinkServiceType) {
        self.me = me
        self.peerID = peerID
        self.key = key
        self.lastAddress = lastAddress
        self.port = port
        self.peerPort = peerPort
        self.useBonjour = useBonjour
        self.serviceType = serviceType
    }

    func start() {
        stopped = false
        log("连接：开始\(isInitiator ? "主动寻找并连接对方" : "等待对方连接")（本机 ID \(me.id.prefix(8))，对方 ID \(peerID.prefix(8))，上次地址 \(lastAddress ?? "无")）")
        startListener()
        if isInitiator {
            if useBonjour {
                let b = BonjourBrowser(type: serviceType, label: "重连查找")
                b.onChange = { [weak self] list in
                    guard let self else { return }
                    let ep = list.first(where: { $0.id == self.peerID })?.endpoint
                    if ep != self.bonjourEndpoint {
                        self.bonjourEndpoint = ep
                        log("连接：局域网里\(ep == nil ? "暂时看不到对方" : "找到对方：\(ep!)")")
                        if ep != nil, self.active == nil { self.dial() }
                    }
                }
                browser = b
                b.start()
            }
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 0.2, repeating: 2)
            t.setEventHandler { [weak self] in self?.dial() }
            t.resume()
            connectTimer = t
        }
    }

    func stop() {
        stopped = true
        connectTimer?.cancel()
        connectTimer = nil
        browser?.stop()
        browser = nil
        listener?.cancel()
        listener = nil
        let all = Array(pending.values) + [active, dialing].compactMap { $0 }
        active = nil
        dialing = nil
        pending.removeAll()
        for p in all {
            p.onClose = nil
            p.close("本机停止连接")
        }
    }

    // MARK: 监听（两台都开）

    private func startListener() {
        guard !stopped else { return }
        let l: NWListener
        do {
            l = try NWListener(using: Peer.tcpParameters(), on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            log("错误：创建 TCP \(port) 监听失败：\(error)，5 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startListener() }
            return
        }
        if useBonjour {
            l.service = NWListener.Service(name: bonjourName("MacKVM \(me.id.prefix(8))"), type: serviceType,
                                           domain: nil, txtRecord: makeTXT(id: me.id, name: me.name))
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, !self.stopped else { return }
            switch st {
            case .ready:
                log("连接：正在监听 TCP \(self.port)\(self.useBonjour ? "，并在局域网广播 \(self.serviceType)" : "")")
            case .waiting(let e):
                log("连接：监听暂时不可用：\(describeNetworkError(e))")
            case .failed(let e):
                log("错误：监听失败：\(describeNetworkError(e))，5 秒后重试")
                l?.cancel()
                self.listener = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startListener() }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: .main)
        listener = l
    }

    private func accept(_ conn: NWConnection) {
        guard !stopped else { conn.cancel(); return }
        let p = Peer(conn: conn, key: key, name: "对方 \(conn.endpoint)")
        p.verbose = false
        pending[ObjectIdentifier(p)] = p
        wire(p)
        p.start()
    }

    // MARK: 主动连接（只有 ID 小的那台）

    private func dial() {
        guard !stopped, isInitiator, active == nil, dialing == nil else { return }
        // Bonjour 找到的目标和上次成功的 IP 轮流试；只有一种就一直用它
        var targets: [(NWEndpoint, String)] = []
        if let ep = bonjourEndpoint { targets.append((ep, "局域网发现的 \(ep)")) }
        if let ip = lastAddress {
            targets.append((.hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: peerPort)!),
                            "上次的地址 \(ip):\(peerPort)"))
        }
        guard !targets.isEmpty else {
            if failStreak % 30 == 0 { log("连接：还没在局域网发现对方，也没有上次的地址，继续等") }
            failStreak += 1
            return
        }
        let (ep, desc) = targets[attempt % targets.count]
        attempt += 1
        let p = Peer(conn: NWConnection(to: ep, using: Peer.tcpParameters()), key: key, name: "对方（\(desc)）")
        // 对方长时间不在时别每 2 秒刷两行日志：连续失败的前 3 次和之后每 30 次才记
        p.verbose = failStreak < 3 || failStreak % 30 == 0
        if p.verbose { log("连接：正在连接\(desc)（连续失败 \(failStreak) 次）") }
        dialing = p
        wire(p)
        p.start()
    }

    // MARK: 公共回调

    private func wire(_ p: Peer) {
        p.onAuthenticated = { [weak self] p in self?.authenticated(p) }
        p.onMessage = { [weak self] p, t, d in
            guard let self, p === self.active else { return }
            self.onMessage?(p, t, d)
        }
        p.onClose = { [weak self] p, _ in self?.closed(p) }
    }

    private func authenticated(_ p: Peer) {
        pending.removeValue(forKey: ObjectIdentifier(p))
        if dialing === p { dialing = nil }
        failStreak = 0
        let old = active
        active = p
        if let old, old !== p {
            log("连接：新连接通过校验，关掉旧连接")
            old.onClose = nil
            old.close("被新连接替换")
        }
        if let ip = p.remoteIP, ip != lastAddress {
            lastAddress = ip
            onAddressLearned?(ip)
        }
        onAuthenticated?(p)
    }

    private func closed(_ p: Peer) {
        pending.removeValue(forKey: ObjectIdentifier(p))
        if dialing === p {
            dialing = nil
            failStreak += 1
        }
        if active === p {
            active = nil
            onDisconnected?()
            if isInitiator, !stopped {
                // 刚断开时稍等再连，给对方的进程重启留点时间
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.dial() }
            }
        }
    }
}

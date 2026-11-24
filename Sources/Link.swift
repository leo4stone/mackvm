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

// MARK: - 多对端连接中心（主控一控多 + 被控复用同一端口）

/// 用一个 TCP 24810 监听 + 一个 Bonjour 浏览器同时管理 1..N 个已配对设备与 0..N 个待通知的解除配对目标。
/// 入站连接先读出第一帧（hello），按各对端的长期密钥试解（ChaChaPoly 认证标签天然唯一识别是谁连进来的），
/// 再转交给对应的 Peer 状态机。
final class LinkHub {
    struct Entry {
        var peerID: String
        var name: String
        var key: SymmetricKey
        var lastAddress: String?
        var port: UInt16 = kLinkPort
    }

    private final class Slot {
        var entry: Entry
        let isUnpairOnly: Bool
        var active: Peer?
        var dialing: Peer?
        var pending: [ObjectIdentifier: Peer] = [:]
        var failStreak = 0
        var attempt = 0

        init(entry: Entry, isUnpairOnly: Bool) {
            self.entry = entry
            self.isUnpairOnly = isUnpairOnly
        }
    }

    private final class InboundProbe {
        let conn: NWConnection
        var buffer = Data()
        var closed = false
        var timeout: DispatchWorkItem?
        var onFrame: ((InboundProbe, Data, Data) -> Void)?
        var onDead: ((InboundProbe) -> Void)?

        init(conn: NWConnection) { self.conn = conn }

        func start() {
            conn.stateUpdateHandler = { [weak self] st in
                guard let self, !self.closed else { return }
                switch st {
                case .ready:
                    self.receive()
                case .failed, .waiting, .cancelled:
                    self.fail()
                default:
                    break
                }
            }
            conn.start(queue: .main)
            let w = DispatchWorkItem { [weak self] in self?.fail() }
            timeout = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
        }

        private func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.buffer.append(data) }
                if self.buffer.count >= 4 {
                    let len = Int(self.buffer.readBE(0, UInt32.self)!)
                    guard len >= 12 + 1 + 16, len <= 1 << 20 else { self.fail(); return }
                    if self.buffer.count >= 4 + len {
                        let s = self.buffer.startIndex
                        let frame = Data(self.buffer[(s + 4)..<(s + 4 + len)])
                        let all = self.buffer
                        self.detach()
                        self.onFrame?(self, frame, all)
                        return
                    }
                }
                if err != nil || done { self.fail(); return }
                self.receive()
            }
        }

        func detach() {
            closed = true
            timeout?.cancel()
            timeout = nil
            conn.stateUpdateHandler = nil
        }

        func fail() {
            guard !closed else { return }
            detach()
            conn.cancel()
            onDead?(self)
        }
    }

    let me: DeviceIdentity
    let port: UInt16
    let useBonjour: Bool
    let serviceType: String

    var onAuthenticated: ((String, Peer) -> Void)?
    var onMessage: ((String, Peer, Msg, Data) -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onAddressLearned: ((String, String) -> Void)?
    var onUnpairDelivered: ((String) -> Void)?

    private var slots: [String: Slot] = [:]
    private var unpairSlots: [String: Slot] = [:]
    private var probes: [ObjectIdentifier: InboundProbe] = [:]
    private var listener: NWListener?
    private var browser: BonjourBrowser?
    private var bonjourEndpoints: [String: NWEndpoint] = [:]
    private var connectTimer: DispatchSourceTimer?
    private var stopped = true

    init(me: DeviceIdentity, port: UInt16 = kLinkPort, useBonjour: Bool = true, serviceType: String = kLinkServiceType) {
        self.me = me
        self.port = port
        self.useBonjour = useBonjour
        self.serviceType = serviceType
    }

    var connectedPeerIDs: Set<String> {
        Set(slots.compactMap { $0.value.active != nil ? $0.key : nil })
    }

    func activePeer(for peerID: String) -> Peer? {
        slots[peerID]?.active
    }

    func start() {
        guard stopped else { return }
        stopped = false
        startListener()
        if useBonjour {
            let b = BonjourBrowser(type: serviceType, label: "重连查找")
            b.onChange = { [weak self] list in
                guard let self, !self.stopped else { return }
                var next: [String: NWEndpoint] = [:]
                for d in list { next[d.id] = d.endpoint }
                for (id, slot) in self.slots {
                    let prev = self.bonjourEndpoints[id]
                    let ep = next[id]
                    if prev != ep {
                        log("连接（\(slot.entry.name)）：局域网里\(ep == nil ? "暂时看不到对方" : "找到对方：\(ep!)")")
                    }
                }
                self.bonjourEndpoints = next
                for (id, slot) in self.slots where next[id] != nil && slot.active == nil && slot.dialing == nil {
                    if self.isInitiator(id) { self.dial(id, unpair: false) }
                }
                for (id, slot) in self.unpairSlots where next[id] != nil && slot.active == nil && slot.dialing == nil {
                    if self.isInitiator(id) { self.dial(id, unpair: true) }
                }
            }
            browser = b
            b.start()
        }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.2, repeating: 2)
        t.setEventHandler { [weak self] in self?.dialAll() }
        t.resume()
        connectTimer = t
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        connectTimer?.cancel()
        connectTimer = nil
        browser?.stop()
        browser = nil
        listener?.cancel()
        listener = nil
        bonjourEndpoints.removeAll()
        for (_, probe) in probes { probe.fail() }
        probes.removeAll()
        for (_, slot) in slots { closeSlot(slot, reason: "本机停止连接") }
        slots.removeAll()
        for (_, slot) in unpairSlots { closeSlot(slot, reason: "本机停止连接") }
        unpairSlots.removeAll()
    }

    func setPeers(_ list: [Entry]) {
        let toDial = syncSlots(&slots, entries: list, isUnpairOnly: false)
        for id in toDial { dial(id, unpair: false) }
    }

    func setUnpairTargets(_ list: [Entry]) {
        let toDial = syncSlots(&unpairSlots, entries: list, isUnpairOnly: true)
        for id in toDial { dial(id, unpair: true) }
    }

    private func syncSlots(_ map: inout [String: Slot], entries: [Entry], isUnpairOnly: Bool) -> [String] {
        let wanted = Set(entries.map(\.peerID))
        for id in Array(map.keys) where !wanted.contains(id) {
            if let old = map.removeValue(forKey: id) {
                closeSlot(old, reason: isUnpairOnly ? "解除配对通知结束" : "设备已移除")
            }
        }
        var toDial: [String] = []
        for e in entries {
            if let existing = map[e.peerID] {
                let sameKey = existing.entry.key.withUnsafeBytes { Data($0) } == e.key.withUnsafeBytes { Data($0) }
                if sameKey {
                    existing.entry = e
                    continue
                }
                closeSlot(existing, reason: "密钥已更新")
            }
            let slot = Slot(entry: e, isUnpairOnly: isUnpairOnly)
            map[e.peerID] = slot
            if !stopped {
                log("连接（\(e.name)）：开始\(isInitiator(e.peerID) ? "主动寻找并连接对方" : "等待对方连接")（本机 ID \(me.id.prefix(8))，对方 ID \(e.peerID.prefix(8))，上次地址 \(e.lastAddress ?? "无")）")
                if isInitiator(e.peerID) { toDial.append(e.peerID) }
            }
        }
        return toDial
    }

    private func closeSlot(_ slot: Slot, reason: String) {
        let all = Array(slot.pending.values) + [slot.active, slot.dialing].compactMap { $0 }
        slot.active = nil
        slot.dialing = nil
        slot.pending.removeAll()
        for p in all {
            p.onClose = nil
            p.close(reason)
        }
    }

    private func isInitiator(_ peerID: String) -> Bool { me.id < peerID }

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
        l.newConnectionHandler = { [weak self] conn in self?.acceptInbound(conn) }
        l.start(queue: .main)
        listener = l
    }

    private func acceptInbound(_ conn: NWConnection) {
        guard !stopped else { conn.cancel(); return }
        let probe = InboundProbe(conn: conn)
        let pid = ObjectIdentifier(probe)
        probes[pid] = probe
        probe.onDead = { [weak self] pr in
            self?.probes.removeValue(forKey: ObjectIdentifier(pr))
        }
        probe.onFrame = { [weak self] pr, frame, all in
            guard let self else { pr.conn.cancel(); return }
            self.probes.removeValue(forKey: ObjectIdentifier(pr))
            self.routeInbound(conn: pr.conn, firstFrame: frame, fullBuffer: all)
        }
        probe.start()
    }

    private func routeInbound(conn: NWConnection, firstFrame: Data, fullBuffer: Data) {
        guard !stopped else { conn.cancel(); return }
        func match(in map: [String: Slot]) -> Slot? {
            for (_, slot) in map {
                if let plain = Peer.tryOpen(firstFrame, using: slot.entry.key), plain.first == Msg.hello.rawValue {
                    return slot
                }
            }
            return nil
        }
        guard let slot = match(in: slots) ?? match(in: unpairSlots) else {
            log("连接：收到未知对端 \(conn.endpoint)（无法通过任何配对密钥解密），断开")
            conn.cancel()
            return
        }
        let p = Peer(conn: conn, key: slot.entry.key, name: "\(slot.entry.name) \(conn.endpoint)")
        p.verbose = false
        slot.pending[ObjectIdentifier(p)] = p
        wire(p, slot: slot)
        p.startAccepted(initialBuffer: fullBuffer)
    }

    private func dialAll() {
        guard !stopped else { return }
        for id in Array(slots.keys) where isInitiator(id) { dial(id, unpair: false) }
        for id in Array(unpairSlots.keys) where isInitiator(id) { dial(id, unpair: true) }
    }

    private func dial(_ peerID: String, unpair: Bool) {
        guard !stopped, isInitiator(peerID) else { return }
        guard let slot = (unpair ? unpairSlots[peerID] : slots[peerID]),
              slot.active == nil, slot.dialing == nil else { return }
        var targets: [(NWEndpoint, String)] = []
        if let ep = bonjourEndpoints[peerID] { targets.append((ep, "局域网发现的 \(ep)")) }
        if let ip = slot.entry.lastAddress {
            targets.append((.hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: slot.entry.port)!),
                            "上次的地址 \(ip):\(slot.entry.port)"))
        }
        guard !targets.isEmpty else {
            if slot.failStreak % 30 == 0 { log("连接（\(slot.entry.name)）：还没在局域网发现对方，也没有上次的地址，继续等") }
            slot.failStreak += 1
            return
        }
        let (ep, desc) = targets[slot.attempt % targets.count]
        slot.attempt += 1
        let p = Peer(conn: NWConnection(to: ep, using: Peer.tcpParameters()), key: slot.entry.key, name: "\(slot.entry.name)（\(desc)）")
        p.verbose = slot.failStreak < 3 || slot.failStreak % 30 == 0
        if p.verbose { log("连接（\(slot.entry.name)）：正在连接\(desc)（连续失败 \(slot.failStreak) 次）") }
        slot.dialing = p
        wire(p, slot: slot)
        p.start()
    }

    private func wire(_ p: Peer, slot: Slot) {
        let id = slot.entry.peerID
        let unpair = slot.isUnpairOnly
        p.onAuthenticated = { [weak self, weak slot] p in
            guard let self, let slot else { return }
            self.peerAuthenticated(p, slot: slot)
        }
        p.onMessage = { [weak self, weak slot] p, t, d in
            guard let self, let slot, !unpair, slot.active === p else { return }
            self.onMessage?(id, p, t, d)
        }
        p.onClose = { [weak self, weak slot] p, _ in
            guard let self, let slot else { return }
            self.peerClosed(p, slot: slot)
        }
    }

    private func peerAuthenticated(_ p: Peer, slot: Slot) {
        slot.pending.removeValue(forKey: ObjectIdentifier(p))
        if slot.dialing === p { slot.dialing = nil }
        slot.failStreak = 0
        let old = slot.active
        slot.active = p
        if let old, old !== p {
            log("连接（\(slot.entry.name)）：新连接通过校验，关掉旧连接")
            old.onClose = nil
            old.close("被新连接替换")
        }
        let id = slot.entry.peerID
        if slot.isUnpairOnly {
            p.send(.unpair) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self, ok else { return }
                    self.onUnpairDelivered?(id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        if let s = self?.unpairSlots.removeValue(forKey: id) {
                            self?.closeSlot(s, reason: "已通知解除配对")
                        }
                    }
                }
            }
            return
        }
        if let ip = p.remoteIP, ip != slot.entry.lastAddress {
            slot.entry.lastAddress = ip
            onAddressLearned?(id, ip)
        }
        onAuthenticated?(id, p)
    }

    private func peerClosed(_ p: Peer, slot: Slot) {
        slot.pending.removeValue(forKey: ObjectIdentifier(p))
        if slot.dialing === p {
            slot.dialing = nil
            slot.failStreak += 1
        }
        if slot.active === p {
            slot.active = nil
            if !slot.isUnpairOnly {
                onDisconnected?(slot.entry.peerID)
                if isInitiator(slot.entry.peerID), !stopped {
                    let pid = slot.entry.peerID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.dial(pid, unpair: false) }
                }
            }
        }
    }
}

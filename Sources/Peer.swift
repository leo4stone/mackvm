// 已配对两台之间的加密连接（一条 TCP 连接一个 Peer 对象）：
//   ChaChaPoly 加密帧、hello 交换会话号、序号严格递增防重放、1 秒心跳 / 3 秒超时。
// 密钥是配对时双方协商出的长期密钥（见 Pairing.swift）。连接由谁发起、断了怎么重连归 Link.swift 管。
//
// 帧：4 字节大端长度 + ChaChaPoly 密文（12 字节随机 nonce + 密文 + 16 字节认证标签）。
// 明文：1 字节类型 + 内容。
//   hello：类型 + 8 字节「我方会话号」（连接建立后双方各发一次）
//   其它：类型 + 8 字节「对方会话号」+ 8 字节递增序号 + 负载
// 会话号是每条连接随机生成的，序号严格递增：被录下来的旧数据换一条连接或原样重发都会被拒绝。

import CryptoKit
import Foundation
import Network

enum Msg: UInt8 {
    case hello = 1
    case heartbeat = 2
    case enter = 3      // 主控 → 被控：JSON CrossPayload（落到被控哪块屏、哪条边、第几毫米）
    case leave = 4      // 被控 → 主控：JSON CrossPayload（落到主控哪块屏、哪条边、第几毫米）；空表示重置键鼠状态，主控把光标放到它的主屏中心
    case move = 5       // 主控 → 被控：Int32 dx, Int32 dy
    case button = 6     // 主控 → 被控：UInt8 按键编号, UInt8 是否按下
    case event = 7      // 主控 → 被控：CGEvent 序列化数据（滚轮/键盘/修饰键/媒体键）
    case release = 8    // 主控 → 被控：主控用热键 Ctrl+Option+Cmd+L 强制收回，被控退出活动状态
    case settings = 9   // 双向：共享设置（JSON，见 Settings.swift 的 SharedSettings）
    case unpair = 10    // 双向：对方解除了配对，收到的一方也清除配对
    case info = 11      // 双向：本机信息（JSON：设备 ID、设备名、是否笔记本），连上后各发一次
    case screens = 12   // 双向：本机屏幕清单（JSON [ScreenInfo]），连上后、屏幕变化时发
}

/// 连接对端的 IP：IPv4 去掉网卡后缀；IPv6 保留「%网卡」（链路本地地址要靠它才连得上）。
/// 经 Bonjour 连上时系统常选 IPv6 链路本地地址，只认 IPv4 会一直记不下后备地址。
func remoteIPString(_ conn: NWConnection) -> String? {
    guard case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint ?? Optional(conn.endpoint) else { return nil }
    switch host {
    case .ipv4(let a): return "\(a)".split(separator: "%").first.map(String.init)
    case .ipv6(let a): return "\(a)"
    default: return nil
    }
}

final class Peer {
    let conn: NWConnection
    let key: SymmetricKey
    let name: String
    var verbose = true
    var onMessage: ((Peer, Msg, Data) -> Void)?
    var onAuthenticated: ((Peer) -> Void)?
    var onClose: ((Peer, String) -> Void)?

    private(set) var authenticated = false
    private(set) var closed = false
    private var buffer = Data()
    private let mySession = UInt64.random(in: 1...UInt64.max)
    private var peerSession: UInt64?
    private var sendSeq: UInt64 = 0
    private var recvSeq: UInt64 = 0
    private var lastRecv = Date()
    private var timer: DispatchSourceTimer?
    private var hbCount = 0
    private var hbWindowStart = Date()
    private var firstReport = true   // 连上后约 10 秒先报一次，之后每 60 秒报一次

    init(conn: NWConnection, key: SymmetricKey, name: String) {
        self.conn = conn
        self.key = key
        self.name = name
    }

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let p = NWParameters(tls: nil, tcp: tcp)
        p.allowLocalEndpointReuse = true
        return p
    }

    /// 连接对端的 IP 地址（连上之后才有），用来记住「上次成功的地址」作 Bonjour 的后备
    var remoteIP: String? { remoteIPString(conn) }

    func start() {
        lastRecv = Date()
        conn.stateUpdateHandler = { [weak self] st in self?.stateChanged(st) }
        conn.start(queue: .main)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stateChanged(_ st: NWConnection.State) {
        switch st {
        case .ready:
            if verbose { log("TCP 已建立：\(name)") }
            send(.hello)
            receive()
        case .failed(let e):
            close("连接失败：\(e)")
        case .waiting(let e):
            close("连不上：\(e)")
        case .cancelled:
            close("连接已取消")
        default:
            break
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse()
            }
            if self.closed { return }
            if let error { self.close("接收出错：\(error)"); return }
            if isComplete { self.close("对端关闭了连接"); return }
            self.receive()
        }
    }

    private func parse() {
        while !closed, buffer.count >= 4 {
            let len = Int(buffer.readBE(0, UInt32.self)!)
            guard len >= 12 + 1 + 16, len <= 1 << 20 else {
                close("帧长度异常（\(len) 字节），对端可能不是 MacKVM")
                return
            }
            guard buffer.count >= 4 + len else { return }
            let s = buffer.startIndex
            let frame = Data(buffer[(s + 4)..<(s + 4 + len)])
            buffer = Data(buffer[(s + 4 + len)...])
            let plain: Data
            do {
                let box = try ChaChaPoly.SealedBox(combined: frame)
                plain = try ChaChaPoly.open(box, using: key)
            } catch {
                close("解密失败：对端的配对密钥和本机不一致（或数据被篡改），断开连接")
                return
            }
            handle(plain)
        }
    }

    private func handle(_ plain: Data) {
        guard let t = plain.first else { close("收到空消息"); return }
        if t == Msg.hello.rawValue {
            guard peerSession == nil, let s = plain.readBE(1, UInt64.self) else {
                close("hello 消息不合法或重复")
                return
            }
            peerSession = s
            send(.heartbeat) // 立刻回一个绑定了对方会话号的心跳，证明自己有密钥
            return
        }
        guard let sess = plain.readBE(1, UInt64.self), let seq = plain.readBE(9, UInt64.self) else {
            close("消息太短")
            return
        }
        guard sess == mySession else { close("会话号不符（可能是被重放的旧数据），断开"); return }
        guard seq > recvSeq else { close("序号没有递增（可能是被重放的数据），断开"); return }
        recvSeq = seq
        lastRecv = Date()
        if !authenticated {
            authenticated = true
            hbWindowStart = Date()
            hbCount = 0
            firstReport = true
            log("对端已连上并通过密钥校验：\(name)")
            onAuthenticated?(self)
        }
        guard let type = Msg(rawValue: t) else {
            // 能解密就说明是持有配对密钥的自己人，未知类型多半是更新版本加的新消息：忽略这一条，不断开
            log("收到未知消息类型 \(t)，忽略")
            return
        }
        if type == .heartbeat { hbCount += 1; return }
        onMessage?(self, type, Data(plain[(plain.startIndex + 17)...]))
    }

    /// 发送一条消息。completion 在数据交给系统发出后（或发送失败、连接已关）调用，参数表示是否成功交出。
    func send(_ type: Msg, _ payload: Data = Data(), completion: ((Bool) -> Void)? = nil) {
        guard !closed else { completion?(false); return }
        var plain = Data([type.rawValue])
        if type == .hello {
            plain.appendBE(mySession)
        } else {
            guard let ps = peerSession else { completion?(false); return }
            sendSeq += 1
            plain.appendBE(ps)
            plain.appendBE(sendSeq)
            plain.append(payload)
        }
        guard let box = try? ChaChaPoly.seal(plain, using: key) else {
            log("错误：加密失败")
            completion?(false)
            return
        }
        let c = box.combined
        var frame = Data()
        frame.appendBE(UInt32(c.count))
        frame.append(c)
        conn.send(content: frame, completion: .contentProcessed { [weak self] err in
            if let err { self?.close("发送出错：\(err)") }
            completion?(err == nil)
        })
    }

    private func tick() {
        guard !closed else { return }
        send(.heartbeat)
        if Date().timeIntervalSince(lastRecv) > 3 {
            close(authenticated ? "心跳超时（超过 3 秒没收到对端任何消息）" : "握手超时（3 秒内没连上或没通过密钥校验）")
            return
        }
        let w = Date().timeIntervalSince(hbWindowStart)
        if authenticated, w >= (firstReport ? 10 : 60) {
            firstReport = false
            log("心跳正常：过去 \(Int(w)) 秒收到 \(hbCount) 个心跳（\(name)）")
            hbCount = 0
            hbWindowStart = Date()
        }
    }

    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        conn.stateUpdateHandler = nil
        conn.cancel()
        if verbose || authenticated { log("连接断开（\(name)）：\(reason)") }
        onClose?(self, reason)
    }
}

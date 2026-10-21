// 首次配对：用被控方屏幕上的 8 位配对码，在局域网上协商出两台共用的长期密钥（32 字节）。
//
// 为什么不是「X25519 交换 + 用配对码对握手做 HMAC 确认」那么简单：那样做时，先把 HMAC 发出去的一方
// 会被主动中间人拿到一个可以离线暴力的目标（中间人知道自己那一侧的共享密钥，1 亿个码几秒就能试完），
// 再拿猜出的码去骗另一台。所以这里把配对码揉进 X25519 的「基点」里（CPace 的做法）：
//   G = SHA-256(域标签, 配对码, 双方随机数, 双方设备 ID) 当作 X25519 的 u 坐标；
//   双方各取临时私钥 a、b，交换 Ya = X25519(a, G)、Yb = X25519(b, G)，得 K = X25519(a, Yb) = X25519(b, Ya)。
// 配对码不对，两边的 G 就不同、K 就对不上；中间人每次连接只能试一个码（被控方输错 5 次就换码），
// 拿到的确认 HMAC 也没法离线验证别的码（要算 K 得解离散对数）。被动监听者即使事后知道配对码也算不出 K。
// 说明：任意 32 字节在 X25519 里不是落在曲线上就是落在它的扭曲线上，Curve25519 对扭曲线同样安全；
// 代价是 Y 落在哪条线上会泄露配对码 1 比特，对一次性的 8 位码无关紧要。
//
// 线上格式（明文 TCP，被控方监听、主控方连接）：每帧 4 字节大端长度 + JSON。
//   1. 主控 → 被控  hello   {id, name, laptop, nonce}
//   2. 被控 → 主控  hello   {id, name, laptop, nonce, y=Y被控}      （正在和别人配对时回 busy）
//   3. 主控 → 被控  confirm {y=Y主控, mac=HMAC(K派生的主控确认密钥, 握手摘要)}
//   4. 被控 → 主控  confirm {mac=HMAC(K派生的被控确认密钥, 握手摘要)}  或 wrong {left, renewed}
//   5. 主控 → 被控  done
// 长期密钥 = HKDF-SHA256(K, salt=握手摘要, info="MacKVM long-term key v1")。
// 握手摘要覆盖双方 ID、设备名、随机数和两个 Y，任何一项被改，确认都过不去。

import CryptoKit
import Foundation
import Network

// MARK: - 纯密码学部分（自测直接调用）

enum PairingCrypto {
    static let maxFailures = 5

    /// 随机 8 位数字配对码（可以有前导 0）
    static func newCode() -> String {
        String(format: "%08u", UInt32.random(in: 0..<100_000_000))
    }

    /// 只留数字
    static func digits(_ s: String) -> String { String(s.filter { $0.isASCII && $0.isNumber }) }

    private static func lp(_ d: Data) -> Data {
        var o = Data()
        o.appendBE(UInt32(d.count))
        o.append(d)
        return o
    }
    private static func lp(_ s: String) -> Data { lp(Data(s.utf8)) }

    /// 由配对码和本次会话信息导出的 X25519 基点（u 坐标，32 字节小端，最高位清零）
    static func generator(code: String, nonceC: Data, nonceI: Data, idC: String, idI: String) -> Data {
        var h = SHA256()
        h.update(data: lp("MacKVM-CPace-X25519-v1"))
        h.update(data: lp(code))
        h.update(data: lp(nonceC))
        h.update(data: lp(nonceI))
        h.update(data: lp(idC))
        h.update(data: lp(idI))
        var g = Data(h.finalize())
        g[g.startIndex + 31] &= 0x7f
        return g
    }

    /// X25519(私钥, 任意 u 坐标)。结果全 0（对方给了低阶点）时抛错。
    static func x25519(_ priv: Curve25519.KeyAgreement.PrivateKey, _ u: Data) throws -> Data {
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: u)
        let s = try priv.sharedSecretFromKeyAgreement(with: pub)
        let d = s.withUnsafeBytes { Data($0) }
        guard d.contains(where: { $0 != 0 }) else { throw PairFailure.failed("密钥交换结果无效") }
        return d
    }

    struct Hello {
        let id: String
        let name: String
        let nonce: Data
    }

    /// 握手摘要：双方身份、随机数、两个 Y
    static func transcript(c: Hello, i: Hello, yI: Data, yC: Data) -> Data {
        var h = SHA256()
        h.update(data: lp("MacKVM-pair-transcript-v1"))
        for d in [lp(c.id), lp(c.name), lp(c.nonce), lp(i.id), lp(i.name), lp(i.nonce), lp(yI), lp(yC)] {
            h.update(data: d)
        }
        return Data(h.finalize())
    }

    struct Keys {
        let confirmC: SymmetricKey
        let confirmI: SymmetricKey
        let longTerm: SymmetricKey
    }

    static func keys(k: Data, transcript: Data) -> Keys {
        let ikm = SymmetricKey(data: k)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: transcript, info: Data(info.utf8), outputByteCount: 32)
        }
        return Keys(confirmC: derive("MacKVM confirm controller v1"),
                    confirmI: derive("MacKVM confirm controlled v1"),
                    longTerm: derive("MacKVM long-term key v1"))
    }

    static func mac(_ key: SymmetricKey, _ transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript, using: key))
    }

    static func verify(_ mac: Data, _ key: SymmetricKey, _ transcript: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: transcript, using: key)
    }

    /// 日志里用的密钥指纹（SHA-256 前 4 字节），两台对得上就说明密钥一致
    static func fingerprint(_ key: SymmetricKey) -> String {
        let d = key.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) }
        return d.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 结果与错误

struct PairingResult {
    let peerID: String
    let peerName: String
    let peerIsLaptop: Bool
    let key: SymmetricKey
    let peerAddress: String?
}

enum PairFailure: Error, Equatable {
    case wrongCode(left: Int)   // 配对码不对，对方还允许再试 left 次
    case renewed                // 输错太多次，对方已经换了新配对码
    case busy                   // 对方正在和别的设备配对
    case failed(String)         // 网络或协议问题
}

struct PairMsg: Codable {
    var t: String
    var v: Int?
    var id: String?
    var name: String?
    var laptop: Bool?
    var nonce: String?
    var y: String?
    var mac: String?
    var left: Int?
    var renewed: Bool?
}

struct DeviceIdentity {
    let id: String
    let name: String
    let isLaptop: Bool
}

// MARK: - 帧通道（4 字节长度 + JSON）

final class PairChannel {
    let conn: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((PairMsg) -> Void)?
    var onClose: ((String) -> Void)?
    private var buffer = Data()
    private(set) var closed = false
    private var timeout: DispatchWorkItem?

    init(conn: NWConnection) { self.conn = conn }

    func start(timeout seconds: Double = 10) {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self, !self.closed else { return }
            switch st {
            case .ready:
                self.receive()
                self.onReady?()
            case .failed(let e): self.close("连接失败：\(describeNetworkError(e))")
            case .waiting(let e): self.close("连不上：\(describeNetworkError(e))")
            case .cancelled: self.close("连接已取消")
            default: break
            }
        }
        conn.start(queue: .main)
        let w = DispatchWorkItem { [weak self] in self?.close("配对握手超时") }
        timeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    var remoteIP: String? { remoteIPString(conn) }

    func send(_ m: PairMsg, then: (() -> Void)? = nil) {
        guard !closed, let body = try? JSONEncoder().encode(m) else { return }
        var frame = Data()
        frame.appendBE(UInt32(body.count))
        frame.append(body)
        conn.send(content: frame, completion: .contentProcessed { _ in then?() })
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            while self.buffer.count >= 4, !self.closed {
                let len = Int(self.buffer.readBE(0, UInt32.self)!)
                guard len > 0, len <= 65536 else { self.close("配对消息长度异常"); return }
                guard self.buffer.count >= 4 + len else { break }
                let s = self.buffer.startIndex
                let body = Data(self.buffer[(s + 4)..<(s + 4 + len)])
                self.buffer = Data(self.buffer[(s + 4 + len)...])
                guard let m = try? JSONDecoder().decode(PairMsg.self, from: body) else {
                    self.close("配对消息不是合法 JSON")
                    return
                }
                self.onMessage?(m)
            }
            if self.closed { return }
            if let err { self.close("接收出错：\(err)"); return }
            if done { self.close("对方关闭了连接"); return }
            self.receive()
        }
    }

    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        conn.stateUpdateHandler = nil
        conn.cancel()
        onClose?(reason)
    }
}

private func b64(_ d: Data) -> String { d.base64EncodedString() }
private func unb64(_ s: String?, _ n: Int) -> Data? {
    guard let s, let d = Data(base64Encoded: s), d.count == n else { return nil }
    return d
}

// MARK: - 被控方：发起邀请（广播 + 监听 + 校验配对码）

final class PairingInviter {
    let me: DeviceIdentity
    let advertise: Bool
    let serviceType: String
    private(set) var code = PairingCrypto.newCode()
    private(set) var failures = 0
    /// 配对码换了（renewed = 因为输错太多次）
    var onCodeChanged: ((String, Bool) -> Void)?
    var onPaired: ((PairingResult) -> Void)?
    var onProblem: ((String?) -> Void)?
    var onReady: ((UInt16) -> Void)?

    private var listener: NWListener?
    private var session: PairChannel?
    private var stopped = false

    init(me: DeviceIdentity, advertise: Bool = true, serviceType: String = kPairServiceType) {
        self.me = me
        self.advertise = advertise
        self.serviceType = serviceType
    }

    func start() {
        stopped = false
        let l: NWListener
        do {
            l = try NWListener(using: Peer.tcpParameters(), on: .any)
        } catch {
            log("配对：创建监听失败：\(error)")
            onProblem?("创建监听失败：\(error)")
            return
        }
        if advertise {
            l.service = NWListener.Service(name: bonjourName(me.name), type: serviceType, domain: nil,
                                           txtRecord: makeTXT(id: me.id, name: me.name))
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, !self.stopped else { return }
            switch st {
            case .ready:
                let p = l?.port?.rawValue ?? 0
                log("配对：开始等待主控方连接（端口 \(p)\(self.advertise ? "，正在局域网广播 \(self.serviceType)" : "")）")
                self.onProblem?(nil)
                self.onReady?(p)
            case .waiting(let e):
                log("配对：广播暂时不可用：\(describeNetworkError(e))")
                self.onProblem?(describeNetworkError(e))
            case .failed(let e):
                log("配对：监听失败：\(describeNetworkError(e))，5 秒后重试")
                self.onProblem?(describeNetworkError(e))
                l?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.start()
                }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        session?.close("停止邀请")
        session = nil
    }

    private func accept(_ conn: NWConnection) {
        let ch = PairChannel(conn: conn)
        if session != nil {
            // 同一时间只和一台握手，免得有人并发猜码
            ch.onReady = { [weak ch] in
                ch?.send(PairMsg(t: "busy")) { ch?.close("正忙") }
            }
            ch.start(timeout: 3)
            return
        }
        log("配对：收到连接 \(conn.endpoint)")
        session = ch
        var helloC: PairingCrypto.Hello?
        var helloI: PairingCrypto.Hello?
        var secret: Curve25519.KeyAgreement.PrivateKey?
        var yI: Data?
        var peerLaptop = false
        let codeAtStart = code

        ch.onClose = { [weak self, weak ch] reason in
            guard let self, self.session === ch else { return }
            self.session = nil
            log("配对：本次握手结束（\(reason)）")
        }
        ch.onMessage = { [weak self, weak ch] m in
            guard let self, let ch else { return }
            switch m.t {
            case "hello":
                guard helloC == nil, let id = m.id, !id.isEmpty, let name = m.name,
                      let nonce = unb64(m.nonce, 16) else { ch.close("hello 不合法"); return }
                let hc = PairingCrypto.Hello(id: id, name: name, nonce: nonce)
                var n = Data(count: 16)
                for i in 0..<16 { n[i] = UInt8.random(in: 0...255) }
                let hi = PairingCrypto.Hello(id: self.me.id, name: self.me.name, nonce: n)
                let s = Curve25519.KeyAgreement.PrivateKey()
                let g = PairingCrypto.generator(code: codeAtStart, nonceC: hc.nonce, nonceI: hi.nonce,
                                                idC: hc.id, idI: hi.id)
                guard let y = try? PairingCrypto.x25519(s, g) else { ch.close("基点无效"); return }
                helloC = hc; helloI = hi; secret = s; yI = y
                peerLaptop = m.laptop ?? false
                log("配对：对方是「\(name)」（\(id)），等它提交配对码")
                ch.send(PairMsg(t: "hello", v: 1, id: hi.id, name: hi.name, laptop: self.me.isLaptop,
                                nonce: b64(hi.nonce), y: b64(y)))
            case "confirm":
                guard let hc = helloC, let hi = helloI, let s = secret, let yi = yI,
                      let yc = unb64(m.y, 32), let macC = unb64(m.mac, 32) else {
                    ch.close("confirm 不合法"); return
                }
                let tr = PairingCrypto.transcript(c: hc, i: hi, yI: yi, yC: yc)
                let k = try? PairingCrypto.x25519(s, yc)
                let keys = k.map { PairingCrypto.keys(k: $0, transcript: tr) }
                guard let keys, PairingCrypto.verify(macC, keys.confirmC, tr) else {
                    self.failures += 1
                    if self.failures >= PairingCrypto.maxFailures {
                        self.failures = 0
                        self.code = PairingCrypto.newCode()
                        log("配对：对方连续 \(PairingCrypto.maxFailures) 次输错配对码，旧码作废，已换新码")
                        ch.send(PairMsg(t: "wrong", left: 0, renewed: true)) { ch.close("配对码错误（已换码）") }
                        self.onCodeChanged?(self.code, true)
                    } else {
                        let left = PairingCrypto.maxFailures - self.failures
                        log("配对：对方输入的配对码不对（还可再试 \(left) 次）")
                        ch.send(PairMsg(t: "wrong", left: left, renewed: false)) { ch.close("配对码错误") }
                    }
                    return
                }
                let result = PairingResult(peerID: hc.id, peerName: hc.name, peerIsLaptop: peerLaptop,
                                           key: keys.longTerm, peerAddress: ch.remoteIP)
                ch.send(PairMsg(t: "confirm", mac: b64(PairingCrypto.mac(keys.confirmI, tr)))) { [weak self] in
                    guard let self, !self.stopped else { return }
                    log("配对：配对码校验通过，与「\(hc.name)」配对成功（密钥指纹 \(PairingCrypto.fingerprint(keys.longTerm))）")
                    self.onPaired?(result)
                }
            case "done":
                ch.close("对方确认完成")
            default:
                ch.close("意外的消息 \(m.t)")
            }
        }
        ch.start()
    }
}

// MARK: - 主控方：连上被控方并提交配对码

final class PairingSeeker {
    let me: DeviceIdentity
    private var channel: PairChannel?

    init(me: DeviceIdentity) { self.me = me }

    func cancel() {
        channel?.onClose = nil
        channel?.close("取消")
        channel = nil
    }

    /// expectedID：从 Bonjour 记录里看到的对方 ID；对上了才继续（nil 表示不检查，只给自测用）
    func pair(endpoint: NWEndpoint, expectedID: String?, code: String,
              completion: @escaping (Result<PairingResult, PairFailure>) -> Void) {
        cancel()
        let ch = PairChannel(conn: NWConnection(to: endpoint, using: Peer.tcpParameters()))
        channel = ch
        var n = Data(count: 16)
        for i in 0..<16 { n[i] = UInt8.random(in: 0...255) }
        let hc = PairingCrypto.Hello(id: me.id, name: me.name, nonce: n)
        let s = Curve25519.KeyAgreement.PrivateKey()
        var finished = false
        var keys: PairingCrypto.Keys?
        var tr = Data()
        var hi: PairingCrypto.Hello?
        var peerLaptop = false

        func finish(_ r: Result<PairingResult, PairFailure>) {
            guard !finished else { return }
            finished = true
            completion(r)
        }
        ch.onReady = { [weak ch] in
            log("配对：已连上 \(endpoint)，发送握手")
            ch?.send(PairMsg(t: "hello", v: 1, id: hc.id, name: hc.name, laptop: self.me.isLaptop, nonce: b64(hc.nonce)))
        }
        ch.onClose = { reason in
            finish(.failure(.failed(reason)))
        }
        ch.onMessage = { [weak ch] m in
            guard let ch else { return }
            switch m.t {
            case "busy":
                finish(.failure(.busy))
                ch.close("对方正忙")
            case "hello":
                guard hi == nil, let id = m.id, !id.isEmpty, let name = m.name,
                      let nonce = unb64(m.nonce, 16), let yi = unb64(m.y, 32) else {
                    ch.close("对方 hello 不合法"); return
                }
                if let expectedID, expectedID != id {
                    ch.close("对方设备 ID 和局域网记录不一致"); return
                }
                let h = PairingCrypto.Hello(id: id, name: name, nonce: nonce)
                hi = h
                peerLaptop = m.laptop ?? false
                let g = PairingCrypto.generator(code: code, nonceC: hc.nonce, nonceI: h.nonce, idC: hc.id, idI: h.id)
                guard let yc = try? PairingCrypto.x25519(s, g), let k = try? PairingCrypto.x25519(s, yi) else {
                    ch.close("密钥交换失败"); return
                }
                tr = PairingCrypto.transcript(c: hc, i: h, yI: yi, yC: yc)
                let ks = PairingCrypto.keys(k: k, transcript: tr)
                keys = ks
                ch.send(PairMsg(t: "confirm", y: b64(yc), mac: b64(PairingCrypto.mac(ks.confirmC, tr))))
            case "wrong":
                if m.renewed == true {
                    finish(.failure(.renewed))
                } else {
                    finish(.failure(.wrongCode(left: m.left ?? 0)))
                }
                ch.close("配对码错误")
            case "confirm":
                guard let ks = keys, let h = hi, let macI = unb64(m.mac, 32),
                      PairingCrypto.verify(macI, ks.confirmI, tr) else {
                    ch.close("对方的确认码不对，可能遭到中间人攻击，放弃配对"); return
                }
                let result = PairingResult(peerID: h.id, peerName: h.name, peerIsLaptop: peerLaptop,
                                           key: ks.longTerm, peerAddress: ch.remoteIP)
                log("配对：与「\(h.name)」配对成功（密钥指纹 \(PairingCrypto.fingerprint(ks.longTerm))）")
                ch.send(PairMsg(t: "done")) { ch.close("完成") }
                finish(.success(result))
            default:
                ch.close("意外的消息 \(m.t)")
            }
        }
        ch.start()
    }
}

// 主控角色（键鼠接在本机）：截获本机全部输入，光标移动的连线穿过某条相邻规则的蓝色边段（可用区域的边，见 CrossingMap.hit）时，
// 把输入转发给对方；对方把光标从它那边的规则边段推回来时切回本地，落点按毫米对应到本机那块屏那条边。
// 热键 Ctrl+Option+Cmd+L 强制回本地（在截获回调里处理）；被控那台的「重置键鼠状态」见 ControlledRole。
// 切回本地的落点分三种（见 LocalLanding）：对方推回来时按它给的毫米落点；本机热键和对方发来空载荷 leave（被控那台
// 点了重置按钮或按了热键）都是「重置」，落到主屏（菜单栏所在那块）中心；角色停止、对方断线或重连的安全兜底落回跨出去时的点。
// 远端期间本机光标藏起来、停在主屏中心；发给对方的位移取事件的位移字段（见 remoteMove）。
// 连接由 Link 管，这里通过 AppModel 给的闭包拿「对方在不在线」「当前生效的规则和屏幕」和发送通道。
// 角色可以在运行中开关（对调角色、解除配对），stop() 会把截获通道整个拆掉。

import AppKit
import Foundation

// MARK: - 私有接口：让后台进程也能隐藏光标
// 用 dlsym 运行时查找，而不是 @_silgen_name 链接：符号不存在时只记日志，不会链接失败或崩溃，
// 而且按 C 调用约定调用，不依赖 Swift 调用约定碰巧兼容。
// 主控方每次隐藏光标前都调一次，被控方启动时调一次；失败时写日志。

typealias CGSDefaultConnectionFn = @convention(c) () -> Int32
typealias CGSSetConnectionPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

private var backgroundCursorFns: (CGSDefaultConnectionFn, CGSSetConnectionPropertyFn)?
private var backgroundCursorLookupDone = false

func enableBackgroundCursorHiding() {
    if !backgroundCursorLookupDone {
        backgroundCursorLookupDone = true
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let p1 = dlsym(rtldDefault, "_CGSDefaultConnection"), let p2 = dlsym(rtldDefault, "CGSSetConnectionProperty") {
            backgroundCursorFns = (unsafeBitCast(p1, to: CGSDefaultConnectionFn.self),
                                   unsafeBitCast(p2, to: CGSSetConnectionPropertyFn.self))
        } else {
            log("警告：找不到私有接口 _CGSDefaultConnection / CGSSetConnectionProperty，后台进程可能藏不住光标")
        }
    }
    guard let fns = backgroundCursorFns else { return }
    let cid = fns.0()
    let err = fns.1(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    if err != 0 { log("警告：设置 SetsCursorInBackground 失败，错误码 \(err)，光标可能藏不住") }
}

// MARK: - 进程退出兜底：显示光标
// 正常退出（菜单「退出」、SIGTERM / SIGINT）都会先走 AppModel.shutdown → ControllerRole.stop → goLocal；
// atexit 钩子保证别的 exit() 路径也不会把光标留在隐藏状态。

/// 本进程当前是否有一次未配平的 CGDisplayHideCursor（主屏）
var controllerCursorHidden = false
private var cursorExitHookInstalled = false

func installCursorExitHook() {
    guard !cursorExitHookInstalled else { return }
    cursorExitHookInstalled = true
    atexit {
        if controllerCursorHidden {
            controllerCursorHidden = false
            _ = CGDisplayShowCursor(CGMainDisplayID())
        }
    }
}

// MARK: - 截获回调（C 函数指针，不能捕获上下文，所以走全局 theController）

var theController: ControllerRole?

let controllerTapCallback: CGEventTapCallBack = { _, type, event, _ in
    guard let s = theController else { return Unmanaged.passUnretained(event) }
    return s.handle(type: type, event: event)
}

let kKeycodeL: Int64 = 37

// MARK: - 远端位移（纯逻辑，自测直接断言）

/// 远端状态下一个移动事件该发给对方的位移：事件的位移字段（mouseEventDeltaX/Y）。
/// 切到远端时光标被 warp 到主屏中心，这次跳变会混进紧接着某个事件的位移字段，所以 warp 后开一个检查窗口（后续 8 个事件）：
/// 窗口内某个事件位移字段模长超过 150、而位置落在主屏中心 200 点内，就是 warp 落地的那一下，改发「位置 − 主屏中心」并关窗口。
struct RemoteDelta {
    static let warpJump: CGFloat = 150
    static let nearCenter: CGFloat = 200   // warp 落地那个事件 = 中心 + 这一下的真实位移，快甩时能超过 100 点
    static let watchEvents = 8
    private(set) var watch = 0

    /// 刚 warp 到主屏中心：重开检查窗口
    mutating func warped() { watch = RemoteDelta.watchEvents }
    mutating func reset() { watch = 0 }

    mutating func next(field: CGPoint, loc: CGPoint, center: CGPoint) -> CGPoint {
        guard watch > 0 else { return field }
        watch -= 1
        if hypot(field.x, field.y) > RemoteDelta.warpJump,
           hypot(loc.x - center.x, loc.y - center.y) <= RemoteDelta.nearCenter {
            watch = 0
            return CGPoint(x: loc.x - center.x, y: loc.y - center.y)
        }
        return field
    }
}

// MARK: - 切回本地的落点（纯逻辑，自测直接断言）

/// 切回本地时光标落在哪
enum LocalLanding: Equatable {
    /// 对方推回来时给的落点（本机哪块屏、哪条边、第几毫米）；那块屏已不在就落回跨出点
    case payload(CrossPayload)
    /// 跨出去时的点：角色停止、对方断线或重连的安全兜底
    case exitPoint
    /// 主屏（CGMainDisplayID，菜单栏所在那块）中心：重置键鼠状态（本机热键、对方发来空载荷 leave）
    case mainCenter

    /// 对方发来的 leave 该落在哪：空载荷是被控那台的「重置键鼠状态」→ 主屏中心；
    /// 解得出落点 → 按落点；有内容却解不出（不该发生）→ 落回跨出点
    static func forLeave(_ d: Data) -> LocalLanding {
        if d.isEmpty { return .mainCenter }
        if let p = try? JSONDecoder().decode(CrossPayload.self, from: d) { return .payload(p) }
        return .exitPoint
    }

    /// 算出落点和日志里的说法。mainBounds 是主屏在全局坐标里的范围（CGDisplayBounds(CGMainDisplayID())）
    func resolve(exitPoint: CGPoint, mainBounds: CGRect, screens: [String: ScreenInfo]) -> (point: CGPoint, how: String) {
        switch self {
        case .payload(let p):
            if let s = screens[p.screen] {
                return (CrossingMap.landing(on: s, edge: p.edge, mm: p.mm), "落在「\(s.name)」\(p.edge.edgeLabel) \(fmt(p.mm)) 毫米处")
            }
            return (exitPoint, "对方给的落点那块屏不在本机，回到跨出去时的位置")
        case .exitPoint:
            return (exitPoint, "回到跨出去时的位置")
        case .mainCenter:
            return (CGPoint(x: mainBounds.midX, y: mainBounds.midY), "落在主屏中心")
        }
    }
}

final class ControllerRole {
    let myID: String
    /// 按设备 ID 取已认证的连接；nil 表示该设备不在线
    let peerFor: (String) -> Peer?
    /// 该对端是不是 Linux 设备（Linux 走平台无关的 key / scroll 消息，Mac 走 CGEvent 序列化）
    let peerIsLinux: (String) -> Bool
    /// 当前生效的相邻规则（本机视角）和全部设备屏幕信息（随时可能变，每次用时现取）
    let map: () -> CrossingMap

    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var stopped = false
    var activePeerID: String?       // nil = 本地状态；非 nil = 当前正控制这台被控设备
    var remote: Bool { activePeerID != nil }
    var activePeer: Peer? { activePeerID.flatMap(peerFor) }
    var cursorHidden = false        // 本机光标是否被这里隐藏着（主屏 hide 一次，show 时配平一次）
    var center = CGPoint.zero       // 远端状态下藏着的光标停的位置（主屏中心）
    var motion = RemoteDelta()
    var exitPoint = CGPoint.zero    // 这次跨出去时的点（对方没给落点、或那块屏已拔掉时，就回到这里）
    var lastLoc: CGPoint?           // 本地状态下上一个鼠标事件的位置（跨屏判定的连线起点）
    var transitionSeq = 0           // 每次切换加 1，进入波纹的后续环据此判断「还是不是这次进入」
    var lastLocalAt = Date.distantPast
    var fracX: CGFloat = 0, fracY: CGFloat = 0   // 发给对方的位移只能是整数，小数部分攒着
    var lastCapsLockOn = false
    let suppressSource = CGEventSource(stateID: .combinedSessionState)

    init(myID: String, peerFor: @escaping (String) -> Peer?,
         peerIsLinux: @escaping (String) -> Bool, map: @escaping () -> CrossingMap) {
        self.myID = myID
        self.peerFor = peerFor
        self.peerIsLinux = peerIsLinux
        self.map = map
    }

    func start() {
        theController = self
        installCursorExitHook()
        enableBackgroundCursorHiding()
        suppressSource?.localEventsSuppressionInterval = 0
        waitForAccessibility { [weak self] in
            guard let self, !self.stopped else { return }
            self.createTap()
        }
    }

    /// 停止主控角色：在远端就先收回，然后拆掉截获通道
    func stop() {
        guard !stopped else { return }
        if remote {
            activePeer?.send(.release)
            goLocal(.exitPoint, reason: "主控角色停止")
        }
        stopped = true
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
            log("事件截获通道已拆除")
        }
        tap = nil
        tapSource = nil
        if theController === self { theController = nil }
    }

    // MARK: 连接事件（AppModel 转过来）

    func peerOnline(peerID: String, replaced: Bool) {
        if activePeerID == peerID { goLocal(.exitPoint, reason: "对方重新连上（安全兜底）") }
        let n = map().activeViews.count
        log(n > 0 ? "对端在线（\(peerID.prefix(8))）：\(n) 条相邻规则生效，光标从规则边段推出即可切到对方"
                  : "对端在线（\(peerID.prefix(8))），当前没有生效的相邻规则")
    }

    func peerOffline(peerID: String) {
        if activePeerID == peerID { goLocal(.exitPoint, reason: "对方断线（安全兜底）") }
    }

    func message(from peerID: String, _ t: Msg, _ d: Data) {
        switch t {
        case .leave:
            guard activePeerID == peerID else {
                log("收到来自 \(peerID.prefix(8)) 的 leave，但当前不在控制它，忽略")
                return
            }
            if d.isEmpty {
                goLocal(.mainCenter, reason: "对方发来空载荷 leave：被控那台重置了键鼠状态")
                return
            }
            guard let payload = try? JSONDecoder().decode(CrossPayload.self, from: d) else {
                goLocal(.exitPoint, reason: "对方发来 leave")
                return
            }
            if let nextDev = payload.device, !nextDev.isEmpty, nextDev != myID {
                if let nextPeer = peerFor(nextDev) {
                    activePeerID = nextDev
                    fracX = 0
                    fracY = 0
                    let forward = CrossPayload(device: nextDev, screen: payload.screen, edge: payload.edge, mm: payload.mm)
                    nextPeer.send(.enter, (try? JSONEncoder().encode(forward)) ?? Data())
                    log("远端中转：\(peerID.prefix(8)) → \(nextDev.prefix(8))，落到对方屏「\(payload.screen.prefix(8))」\(payload.edge.edgeLabel) \(fmt(payload.mm)) 毫米")
                } else {
                    goLocal(.exitPoint, reason: "目标设备（\(nextDev.prefix(8))）不在线，光标退回本机")
                }
                return
            }
            goLocal(.payload(payload), reason: "对方发来 leave")
        default:
            log("主控收到意外消息类型 \(t)，忽略")
        }
    }

    // MARK: 截获

    func createTap() {
        guard !stopped, tap == nil else { return }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: CGEventMask.max,
                                        callback: controllerTapCallback, userInfo: nil) else {
            log("错误：事件截获通道创建失败（CGEventTapCreate 返回 nil），5 秒后重试")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.createTap() }
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        log("事件截获通道创建成功（HID 层，全部事件）")
    }

    /// 返回事件 = 放行给系统，nil = 吞掉
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        guard !stopped else { return pass }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("截获通道被系统停用（\(type == .tapDisabledByTimeout ? "回调超时" : "用户输入")），重新启用")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        // 自己发的「让程序坞看到光标离开」事件（见 goRemote）：放行，它送达之后重申一次隐藏；不参与跨屏判定和转发
        if event.getIntegerValueField(.eventSourceUserData) == kInjectedMarker {
            if remote {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reassertHide() }
            }
            return pass
        }

        // 紧急热键 Ctrl+Option+Cmd+L：任何状态下都强制回到本地
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == kKeycodeL {
            let f = event.flags
            if f.contains(.maskControl), f.contains(.maskAlternate), f.contains(.maskCommand) {
                if remote {
                    activePeer?.send(.release)
                    goLocal(.mainCenter, reason: "紧急热键 Ctrl+Option+Cmd+L")
                    return nil
                }
                log("紧急热键 Ctrl+Option+Cmd+L：当前已是本地状态")
                return pass
            }
        }

        if !remote {
            if isMouseMove(type) {
                // 只在「没有按住鼠标键的普通移动」时判定跨屏；按住键（拖动）时规则不触发，被规则占用的自家相通段照常可走
                if crossingEligible(type) { checkCrossing(event) }
                // 触发跨屏的这一下也吞掉：系统不能看到光标压在屏幕边上，否则它的边缘交互会启动、把藏起来的光标顶出来
                if remote { return nil }
                lastLoc = event.location
            }
            return pass
        }

        // 远端状态
        guard let pid = activePeerID, let p = peerFor(pid) else { return nil }
        let linux = peerIsLinux(pid)
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            remoteMove(event, to: p)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let b = event.getIntegerValueField(.mouseEventButtonNumber)
            p.send(.button, Data([UInt8(clamping: b), down ? 1 : 0]))
        case .scrollWheel:
            if linux {
                sendScrollToLinux(event, to: p)
            } else {
                sendSerialized(event, to: p)
            }
        case .keyDown, .keyUp, .flagsChanged:
            if linux {
                sendKeyToLinux(type: type, event: event, to: p)
            } else {
                sendSerialized(event, to: p)
            }
        default:
            if type.rawValue == 14 { // NX_SYSDEFINED：媒体键、亮度键等
                if linux {
                    sendMediaKeyToLinux(event, to: p)
                } else {
                    sendSerialized(event, to: p)
                }
            }
        }
        return nil
    }

    // 远端状态下的鼠标移动。移动量取位移字段：事件里的位置是 HID 自己累加的、会被屏幕边夹住，不能拿位置差算。
    // 藏着的光标本身一直停在主屏中心，不用管它。
    func remoteMove(_ event: CGEvent, to p: Peer) {
        let field = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX), y: event.getDoubleValueField(.mouseEventDeltaY))
        let d = motion.next(field: field, loc: event.location, center: center)
        fracX += d.x
        fracY += d.y
        let sx = fracX.rounded(.towardZero), sy = fracY.rounded(.towardZero)
        fracX -= sx
        fracY -= sy
        guard sx != 0 || sy != 0 else { return }
        var data = Data()
        data.appendBE(Int32(clamping: Int64(sx)))
        data.appendBE(Int32(clamping: Int64(sy)))
        p.send(.move, data)
    }

    func isMouseMove(_ t: CGEventType) -> Bool {
        t == .mouseMoved || t == .leftMouseDragged || t == .rightMouseDragged || t == .otherMouseDragged
    }

    func sendSerialized(_ event: CGEvent, to p: Peer) {
        guard let d = event.data else {
            log("警告：事件序列化失败，类型 \(event.type.rawValue)")
            return
        }
        p.send(.event, d as Data)
    }

    // MARK: - 跨平台编码（Linux 对端）

    static func encodeKeyEvent(keycode: UInt16, action: UInt8, flags: UInt64) -> Data {
        var d = Data(capacity: 11)
        d.appendBE(keycode)
        d.append(action)
        d.appendBE(flags)
        return d
    }

    static func encodeScrollEvent(dxLine: Int32, dyLine: Int32, dxPoint: Int32, dyPoint: Int32) -> Data {
        var d = Data(capacity: 16)
        d.appendBE(dxLine)
        d.appendBE(dyLine)
        d.appendBE(dxPoint)
        d.appendBE(dyPoint)
        return d
    }

    /// 按设备相关标志位分辨左右修饰键（比如同时按住左、右 Shift 时松开左边，.maskShift 依然为真，必须看低位设备掩码）
    static func modifierKeyIsDown(keycode: Int64, flags: CGEventFlags) -> Bool {
        let deviceBits: [Int64: UInt64] = [
            59: 0x0001, // 左 Control
            56: 0x0002, // 左 Shift
            60: 0x0004, // 右 Shift
            55: 0x0008, // 左 Command
            54: 0x0010, // 右 Command
            58: 0x0020, // 左 Option
            61: 0x0040, // 右 Option
            62: 0x2000, // 右 Control
        ]
        if let bit = deviceBits[keycode], (flags.rawValue & 0x207F) != 0 {
            return (flags.rawValue & bit) != 0
        }
        if keycode == 57 { return flags.contains(.maskAlphaShift) }
        if let m = modifierKeyFlags[keycode] { return flags.contains(m) }
        return false
    }

    private func sendKeyToLinux(type: CGEventType, event: CGEvent, to p: Peer) {
        let kc = event.getIntegerValueField(.keyboardEventKeycode)
        guard kc >= 0, kc <= Int64(UInt16.max) else { return }
        let code = UInt16(kc)
        let rawFlags = event.flags.rawValue
        switch type {
        case .keyDown:
            let rep = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            p.send(.key, Self.encodeKeyEvent(keycode: code, action: rep ? 2 : 1, flags: rawFlags))
        case .keyUp:
            p.send(.key, Self.encodeKeyEvent(keycode: code, action: 0, flags: rawFlags))
        case .flagsChanged:
            if kc == 57 {
                // CapsLock 只在状态变化时在 Linux 侧点按一次（按下+抬起），避免部分键盘松开时的二次触发
                let on = event.flags.contains(.maskAlphaShift)
                guard on != lastCapsLockOn else { return }
                lastCapsLockOn = on
                p.send(.key, Self.encodeKeyEvent(keycode: code, action: 1, flags: rawFlags))
                p.send(.key, Self.encodeKeyEvent(keycode: code, action: 0, flags: rawFlags))
                return
            }
            let down = Self.modifierKeyIsDown(keycode: kc, flags: event.flags)
            p.send(.key, Self.encodeKeyEvent(keycode: code, action: down ? 1 : 0, flags: rawFlags))
        default:
            break
        }
    }

    private func sendScrollToLinux(_ event: CGEvent, to p: Peer) {
        let dyLine = Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let dxLine = Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let dyPoint = Int32(clamping: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let dxPoint = Int32(clamping: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        p.send(.scroll, Self.encodeScrollEvent(dxLine: dxLine, dyLine: dyLine, dxPoint: dxPoint, dyPoint: dyPoint))
    }

    private func sendMediaKeyToLinux(_ event: CGEvent, to p: Peer) {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return }
        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0xFFFF
        let state = (keyFlags & 0xFF00) >> 8
        guard state == 0x0A || state == 0x0B else { return }
        let action: UInt8 = state == 0x0A ? 1 : 0
        let wireCode = UInt16(0xFF00 | (keyCode & 0xFF))
        p.send(.key, Self.encodeKeyEvent(keycode: wireCode, action: action, flags: event.flags.rawValue))
    }

    func checkCrossing(_ event: CGEvent) {
        // 刚切回本地的 0.15 秒内不往外切：切回时的 warp 会让紧接着的事件带上几千点的假位移，不挡住会来回乒乓
        guard Date().timeIntervalSince(lastLocalAt) > 0.15 else { return }
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        guard abs(dx) < 400, abs(dy) < 400 else { return }
        let loc = event.location
        // 连线起点：上一个事件的位置；终点：起点 + 这一下的位移（不受系统把光标夹在屏内的影响）。
        // 慢推时位移是亚像素，不足 1 点的按 1 点算，保证碰到边就能触发；完全没有位移的事件由 hit 的「停在边上」规则处理。
        func amp(_ v: Double) -> CGFloat { v == 0 ? 0 : (abs(v) < 1 ? (v < 0 ? -1 : 1) : v) }
        let p0 = lastLoc ?? CGPoint(x: loc.x - dx, y: loc.y - dy)
        let p1 = CGPoint(x: p0.x + amp(dx), y: p0.y + amp(dy))
        guard let hit = map().hit(from: p0, to: p1) else { return }
        let target = hit.remoteDevice
        guard !target.isEmpty, peerFor(target) != nil else { return }
        goRemote(hit, targetPeerID: target)
    }

    /// 切到远端：重设 SetsCursorInBackground → 隐藏光标 → warp 到主屏中心
    func goRemote(_ hit: CrossingHit, targetPeerID: String) {
        guard let targetPeer = peerFor(targetPeerID) else { return }
        activePeerID = targetPeerID
        exitPoint = hit.crossPoint
        lastCapsLockOn = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
        let payload = CrossPayload(device: targetPeerID, screen: hit.remoteScreen, edge: hit.remoteEdge, mm: hit.remoteMM)
        targetPeer.send(.enter, (try? JSONEncoder().encode(payload)) ?? Data())
        suppressSource?.localEventsSuppressionInterval = 0
        enableBackgroundCursorHiding()
        hideCursor()
        let b = CGDisplayBounds(CGMainDisplayID())
        center = CGPoint(x: b.midX, y: b.midY)
        let we = CGWarpMouseCursorPosition(center)
        if we != .success { log("警告：切到远端时移动光标失败，错误码 \(we.rawValue)") }
        motion.warped()
        fracX = 0
        fracY = 0
        // 光标跨出前若压过屏幕边或进过程序坞，程序坞已在跟踪光标，窗口服务器会无视后台进程的隐藏和 warp（光标就露在主屏中心）。
        // 程序坞只看送达的事件，warp 结束不了它的跟踪：从回调外发一个带标记的鼠标事件到主屏中心（handle 放行），
        // 它送达后程序坞交出控制权，再重申一次隐藏（见 reassertHide）。没被跟踪时这两步无害。
        let nudgeAt = center
        DispatchQueue.main.async { [weak self] in
            guard let self, self.remote else { return }
            let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: nudgeAt, mouseButton: .left)
            e?.setIntegerValueField(.eventSourceUserData, value: kInjectedMarker)
            e?.post(tap: .cghidEventTap)
        }
        transitionSeq += 1
        let seq = transitionSeq
        // 离开环一直出在离开点；光标又回到本机（或已开始下一次切换）就不再出新环
        playRipple(.leave, at: hit.crossPoint, present: { [weak self] in
            guard let self else { return false }
            return self.remote && self.transitionSeq == seq
        })
        log("切到远端（\(targetPeerID.prefix(8))）：从规则 \(hit.ruleID.prefix(8)) 的\(hit.localEdge.edgeLabel)段推出，跨出点 (\(Int(hit.crossPoint.x)), \(Int(hit.crossPoint.y)))，本机边上 \(fmt(hit.localMM)) 毫米 → 对方屏\(hit.remoteEdge.edgeLabel) \(fmt(hit.remoteMM)) 毫米")
    }

    /// 切回本地时把光标放到落点，并让系统 HID 层记的鼠标位置跟着对齐。
    /// 远端期间事件都被吞掉，HID 层自己记的鼠标位置早已跟着鼠标走远了（贴在跨出去那条边上）；warp 真的移动了光标时
    /// HID 层的位置会一起同步（下一个事件的位移字段里能看到跳变量）；但落点恰好是光标当前画着的位置时（重置键鼠状态：
    /// 远端期间光标一直停在主屏中心，落点也是主屏中心）warp 等于没动、HID 层不同步，之后第一个真实移动事件就把光标画到边上去。
    /// 所以落点和当前位置重合时先 warp 到旁边 1 点再 warp 回落点。CGAssociateMouseAndMouseCursorPosition 只对前台应用生效，这里用不上。
    func warpAndSync(_ p: CGPoint) {
        if let cur = CGEvent(source: nil)?.location, abs(cur.x - p.x) < 0.5, abs(cur.y - p.y) < 0.5 {
            let detour = CGPoint(x: p.x + (p.x > 1 ? -1 : 1), y: p.y)
            let de = CGWarpMouseCursorPosition(detour)
            if de != .success { log("警告：切回本地时移动光标（绕一下）失败，错误码 \(de.rawValue)") }
        }
        let we = CGWarpMouseCursorPosition(p)
        if we != .success { log("警告：切回本地时移动光标失败，错误码 \(we.rawValue)") }
    }

    /// 切回本地（热键、对方发 leave、断线、角色停止都走这里）：warp 到落点 → 显示光标。落点怎么定见 LocalLanding
    func goLocal(_ landing: LocalLanding, reason: String) {
        activePeerID = nil
        motion.reset()
        let (p, how) = landing.resolve(exitPoint: exitPoint, mainBounds: CGDisplayBounds(CGMainDisplayID()), screens: map().local)
        warpAndSync(p)
        lastLoc = p
        showCursor()
        transitionSeq += 1
        let seq = transitionSeq
        // 后续的环出现前，如果光标已经又切到远端，就不再出新环
        let stillHere: () -> Bool = { [weak self] in
            guard let self else { return false }
            return !self.remote && self.transitionSeq == seq
        }
        playRipple(.arrive, at: p, present: stillHere)
        lastLocalAt = Date()
        log("切回本地（\(reason)）：\(how) (\(Int(p.x)), \(Int(p.y)))")
    }

    /// 重申隐藏：显示一次再隐藏一次（计数不变）。被程序坞挡掉的那次隐藏不生效也不计数，所以要这样成对做
    func reassertHide() {
        guard remote, cursorHidden else { return }
        _ = CGDisplayShowCursor(CGMainDisplayID())
        let e = CGDisplayHideCursor(CGMainDisplayID())
        if e != .success { log("警告：重申隐藏光标失败，错误码 \(e.rawValue)") }
    }

    func hideCursor() {
        guard !cursorHidden else { return }
        let e = CGDisplayHideCursor(CGMainDisplayID())
        guard e == .success else {
            log("警告：隐藏光标失败，错误码 \(e.rawValue)")
            return
        }
        cursorHidden = true
        controllerCursorHidden = true
    }

    func showCursor() {
        guard cursorHidden else { return }
        let e = CGDisplayShowCursor(CGMainDisplayID())
        if e != .success { log("警告：显示光标失败，错误码 \(e.rawValue)") }
        cursorHidden = false
        controllerCursorHidden = false
    }
}

/// 跨屏判定只看「没有按住鼠标键的普通移动」：拖动中途切过去会让本机的按下永远收不到抬起
func crossingEligible(_ t: CGEventType) -> Bool { t == .mouseMoved }

// MARK: - 辅助功能授权

func waitForAccessibility(waited: Int = 0, then: @escaping () -> Void) {
    if AXIsProcessTrusted() {
        then()
        return
    }
    if waited % 60 == 0 {
        log("等待辅助功能授权（已等 \(waited) 秒，每 5 秒检查一次）：请到 系统设置 → 隐私与安全性 → 辅助功能，打开 MacKVM")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        waitForAccessibility(waited: waited + 5, then: then)
    }
}

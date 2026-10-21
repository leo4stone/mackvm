// 主控角色（键鼠接在本机）：截获本机全部输入，光标移动的连线穿过某条相邻规则的蓝色边段（可用区域的边，见 CrossingMap.hit）时，
// 把输入转发给对方；对方把光标从它那边的规则边段推回来时切回本地，落点按毫米对应到本机那块屏那条边。
// 紧急热键 Ctrl+Option+Cmd+L 和菜单「收回光标」强制回本地。
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

final class ControllerRole {
    /// 当前连着的对方（通过了密钥校验）；nil 表示不在线
    let peer: () -> Peer?
    /// 当前生效的相邻规则（本机视角）和两台屏幕信息（随时可能变，每次用时现取）
    let map: () -> CrossingMap

    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var stopped = false
    var remote = false              // false = 本地状态，true = 远端状态
    var cursorHidden = false        // 本机光标是否被这里隐藏着（主屏 hide 一次，show 时配平一次）
    var center = CGPoint.zero       // 远端状态下藏着的光标停的位置（主屏中心）
    var motion = RemoteDelta()
    var exitPoint = CGPoint.zero    // 这次跨出去时的点（对方没给落点、或那块屏已拔掉时，就回到这里）
    var lastLoc: CGPoint?           // 本地状态下上一个鼠标事件的位置（跨屏判定的连线起点）
    var transitionSeq = 0           // 每次切换加 1，进入波纹的后续环据此判断「还是不是这次进入」
    var lastLocalAt = Date.distantPast
    var fracX: CGFloat = 0, fracY: CGFloat = 0   // 发给对方的位移只能是整数，小数部分攒着
    let suppressSource = CGEventSource(stateID: .combinedSessionState)

    init(peer: @escaping () -> Peer?, map: @escaping () -> CrossingMap) {
        self.peer = peer
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
            peer()?.send(.release)
            goLocal(nil, reason: "主控角色停止")
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

    func peerOnline(replaced: Bool) {
        if remote { goLocal(nil, reason: "对方重新连上（安全兜底）") }
        let n = map().activeViews.count
        log(n > 0 ? "对方在线：\(n) 条相邻规则生效，光标从规则边段推出即可切到对方" : "对方在线，但没有生效的相邻规则：光标现在跨不到另一台")
    }

    func peerOffline() {
        if remote { goLocal(nil, reason: "对方断线（安全兜底）") }
    }

    func message(_ t: Msg, _ d: Data) {
        switch t {
        case .leave:
            guard remote else {
                log("收到 leave，但当前已是本地状态，忽略")
                return
            }
            goLocal(try? JSONDecoder().decode(CrossPayload.self, from: d), reason: "对方发来 leave")
        default:
            log("主控收到意外消息类型 \(t)，忽略")
        }
    }

    /// 菜单「收回光标」：和紧急热键一样
    func releaseCursor(_ reason: String) {
        if remote {
            peer()?.send(.release)
            goLocal(nil, reason: reason)
        } else {
            log("\(reason)：当前已是本地状态")
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
                    peer()?.send(.release)
                    goLocal(nil, reason: "紧急热键 Ctrl+Option+Cmd+L")
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
        let p = peer()
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            remoteMove(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let b = event.getIntegerValueField(.mouseEventButtonNumber)
            p?.send(.button, Data([UInt8(clamping: b), down ? 1 : 0]))
        case .scrollWheel, .keyDown, .keyUp, .flagsChanged:
            sendSerialized(event)
        default:
            if type.rawValue == 14 { sendSerialized(event) } // NX_SYSDEFINED：媒体键、亮度键等
        }
        return nil
    }

    // 远端状态下的鼠标移动。移动量取位移字段：事件里的位置是 HID 自己累加的、会被屏幕边夹住，不能拿位置差算。
    // 藏着的光标本身一直停在主屏中心，不用管它。
    func remoteMove(_ event: CGEvent) {
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
        peer()?.send(.move, data)
    }

    func isMouseMove(_ t: CGEventType) -> Bool {
        t == .mouseMoved || t == .leftMouseDragged || t == .rightMouseDragged || t == .otherMouseDragged
    }

    func sendSerialized(_ event: CGEvent) {
        guard let d = event.data else {
            log("警告：事件序列化失败，类型 \(event.type.rawValue)")
            return
        }
        peer()?.send(.event, d as Data)
    }

    func checkCrossing(_ event: CGEvent) {
        guard peer() != nil else { return }
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
        goRemote(hit)
    }

    /// 切到远端：重设 SetsCursorInBackground → 隐藏光标 → warp 到主屏中心
    func goRemote(_ hit: CrossingHit) {
        remote = true
        exitPoint = hit.crossPoint
        let payload = CrossPayload(screen: hit.remoteScreen, edge: hit.remoteEdge, mm: hit.remoteMM)
        peer()?.send(.enter, (try? JSONEncoder().encode(payload)) ?? Data())
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
        log("切到远端：从规则 \(hit.ruleID.prefix(8)) 的\(hit.localEdge.edgeLabel)段推出，跨出点 (\(Int(hit.crossPoint.x)), \(Int(hit.crossPoint.y)))，本机边上 \(fmt(hit.localMM)) 毫米 → 对方屏\(hit.remoteEdge.edgeLabel) \(fmt(hit.remoteMM)) 毫米")
    }

    /// 切回本地（紧急热键、菜单收回、对方发 leave、断线、角色停止都走这里）：warp 到落点 → 显示光标。
    /// payload 是对方给的落点（本机哪块屏、哪条边、第几毫米）；没有、或那块屏已不在，就回到跨出去时的点
    func goLocal(_ payload: CrossPayload?, reason: String) {
        remote = false
        motion.reset()
        var p = exitPoint
        var how = "回到跨出去时的位置"
        if let payload, let s = map().local[payload.screen] {
            p = CrossingMap.landing(on: s, edge: payload.edge, mm: payload.mm)
            how = "落在「\(s.name)」\(payload.edge.edgeLabel) \(fmt(payload.mm)) 毫米处"
        }
        let we = CGWarpMouseCursorPosition(p)
        if we != .success { log("警告：切回本地时移动光标失败，错误码 \(we.rawValue)") }
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

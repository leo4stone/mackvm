// 被控角色（本机被对方操作）：收到 enter 后接管本机光标，把主控发来的输入注入本机；
// 虚拟光标的移动连线穿过本机屏上某条相邻规则的蓝色边段（进入后 150ms 内不算；外侧边要在边上累计外推 15 像素，
// 规则盖住自家相通段时一穿过就算）就交还主控，落点按毫米对应到主控那块屏那条边。
// 连接由 Link 管，这里通过 AppModel 给的闭包拿发送通道和「当前生效的规则和屏幕」。
// 光标从本机推回主控、或被主控紧急收回时，短暂隐藏本机光标，离开波纹播完再显示（见 CursorHider.swift）；
// 断线、角色停止时不隐藏，并且立刻显示。

import AppKit
import Foundation

// MARK: - 离开判定的防抖（纯逻辑，自测直接断言）

/// 进入后 150 毫秒内不离开；穿过外侧边的规则段时，要在这条边上累计往外推够 15 像素才离开，
/// 这样主控偶尔发来一点反向位移也不会一碰就弹回去；规则盖住自家相通段时一穿过就离开（光标会被挪进自家另一块屏，没法累计）。
struct LeaveDebounce {
    private(set) var pendingRule: String?
    private(set) var pendingEdge: Direction?
    private(set) var push: Double = 0

    /// 返回 true 表示这一下该离开了
    mutating func feed(hit: CrossingHit?, beyond: Double, intoOwnScreen: Bool, sinceEnter: Double,
                       outwardOnPending: Double?) -> Bool {
        guard sinceEnter >= 0.15 else { reset(); return false }
        if let hit {
            if intoOwnScreen { return true }
            if hit.ruleID != pendingRule || hit.localEdge != pendingEdge {
                pendingRule = hit.ruleID
                pendingEdge = hit.localEdge
                push = 0
            }
            push += max(beyond, 0)
            return push >= 15
        }
        // 没穿过：往里退了、或已经不在那条边上，就清零；沿着边移动（外推分量为 0）保留累计
        if let o = outwardOnPending, o >= 0, pendingRule != nil { return false }
        reset()
        return false
    }

    mutating func reset() {
        pendingRule = nil
        pendingEdge = nil
        push = 0
    }
}

/// 位移朝 edge 方向往外推了多少（正数 = 往边外推）
func outwardComponent(dx: CGFloat, dy: CGFloat, _ edge: Direction) -> Double {
    switch edge {
    case .right: return Double(dx)
    case .left: return Double(-dx)
    case .down: return Double(dy)
    case .up: return Double(-dy)
    }
}

/// 未夹住的终点越过边上最后一个有效像素多少（外推量）
func beyondEdge(_ p1: CGPoint, _ hit: CrossingHit) -> Double {
    switch hit.localEdge {
    case .right: return Double(p1.x - hit.crossPoint.x)
    case .left: return Double(hit.crossPoint.x - p1.x)
    case .down: return Double(p1.y - hit.crossPoint.y)
    case .up: return Double(hit.crossPoint.y - p1.y)
    }
}

// 修饰键键码 → 对应的标志位（左右两个键共用一个标志位）
let modifierKeyFlags: [Int64: CGEventFlags] = [
    55: .maskCommand, 54: .maskCommand,
    56: .maskShift, 60: .maskShift,
    58: .maskAlternate, 61: .maskAlternate,
    59: .maskControl, 62: .maskControl,
    63: .maskSecondaryFn,
]
let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]

final class ControlledRole {
    /// 当前连着的对方（通过了密钥校验）；nil 表示不在线
    let peer: () -> Peer?
    /// 当前生效的相邻规则（本机视角）和两台屏幕信息（随时可能变，每次用时现取）
    let map: () -> CrossingMap

    var enteredAt = Date.distantPast
    var transitionSeq = 0               // 每次进入/退出加 1，进入波纹的后续环据此判断「还是不是这次进入」
    var debounce = LeaveDebounce()      // 离开判定的防抖

    var active = false
    var pos = CGPoint.zero              // 虚拟光标位置
    var flags: CGEventFlags = []        // 当前按住的修饰键
    var heldButtons = Set<Int>()
    var heldKeys = Set<Int64>()
    var heldModifiers = Set<Int64>()
    var lastClick: (button: Int, time: TimeInterval, pos: CGPoint, count: Int64)?
    let src = CGEventSource(stateID: .hidSystemState)
    let hider: CursorHider
    let inputMonitor = LocalInputMonitor()
    var stopped = false

    init(peer: @escaping () -> Peer?, map: @escaping () -> CrossingMap) {
        self.peer = peer
        self.map = map
        hider = CursorHider(
            hideCursor: {
                let e = CGDisplayHideCursor(CGMainDisplayID())
                if e != .success { log("警告：隐藏光标失败，错误码 \(e.rawValue)") }
            },
            showCursor: {
                let e = CGDisplayShowCursor(CGMainDisplayID())
                if e != .success { log("警告：显示光标失败，错误码 \(e.rawValue)") }
            })
        // 本进程注入的事件都带标记，本机输入监听据此把它们排除
        src?.userData = kInjectedMarker
        hider.onHiddenChanged = { [weak self] hidden in self?.inputMonitor.setEnabled(hidden) }
        inputMonitor.onLocalInput = { [weak self] in self?.hider.show(reason: .localInput) }
    }

    func start() {
        enableBackgroundCursorHiding()
        waitForAccessibility { [weak self] in
            log("被控方可以注入事件了（CGPreflightPostEventAccess = \(CGPreflightPostEventAccess())）")
            guard let self, !self.stopped else { return }
            self.inputMonitor.install()
        }
    }

    func stop() {
        stopped = true
        if active { deactivate(reason: "被控角色停止", hideCursor: false) }
        hider.show(reason: .roleStop)
        inputMonitor.uninstall()
    }

    // MARK: 连接事件（AppModel 转过来）

    func peerOnline(replaced: Bool) {
        if active { deactivate(reason: "对方重新连上（安全兜底）", hideCursor: false) }
        let n = map().activeViews.count
        log(n > 0 ? "对方在线：\(n) 条相邻规则生效，等光标从规则边段进来" : "对方在线，但没有生效的相邻规则")
    }

    func peerOffline() {
        if active { deactivate(reason: "连接断开", hideCursor: false) }
        hider.show(reason: .disconnect)
    }

    func message(_ t: Msg, _ d: Data) {
        switch t {
        case .enter:
            enter(try? JSONDecoder().decode(CrossPayload.self, from: d))
        case .move:
            guard active, let dx = d.readBE(0, Int32.self), let dy = d.readBE(4, Int32.self) else { return }
            move(dx: CGFloat(dx), dy: CGFloat(dy))
        case .button:
            guard active, d.count >= 2 else { return }
            button(Int(d[d.startIndex]), down: d[d.startIndex + 1] != 0)
        case .event:
            guard active else { return }
            inject(d)
        case .release:
            if active { deactivate(reason: "主控用紧急热键收回") }
        default:
            log("被控收到意外消息类型 \(t)，忽略")
        }
    }

    // MARK: 状态切换

    /// 交还主控：带上落点（主控哪块屏、哪条边、第几毫米）；hit 为 nil 时让主控回到它跨出来的位置
    func sendLeave(_ hit: CrossingHit?) {
        var d = Data()
        if let hit, let j = try? JSONEncoder().encode(CrossPayload(screen: hit.remoteScreen, edge: hit.remoteEdge,
                                                                   mm: hit.remoteMM)) {
            d = j
        }
        peer()?.send(.leave, d)
    }

    func enter(_ payload: CrossPayload?) {
        let m = map()
        let s = payload.flatMap { m.local[$0.screen] }
        guard AXIsProcessTrusted() else {
            log("收到 enter，但本机还没授权辅助功能、没法注入事件，立刻把光标还给主控")
            sendLeave(nil)
            return
        }
        let p: CGPoint
        if let payload, let s {
            p = CrossingMap.landing(on: s, edge: payload.edge, mm: payload.mm)
        } else {
            // 规则里那块屏刚好不在（拔掉了）：放到主屏中间
            let b = CGDisplayBounds(CGMainDisplayID())
            p = CGPoint(x: b.midX, y: b.midY)
            log("收到 enter，但落点那块屏不在本机，光标放到主屏中间")
        }
        hider.show(reason: .returned)
        enteredAt = Date()
        debounce = LeaveDebounce()
        pos = p
        active = true
        flags = []
        lastClick = nil
        CGWarpMouseCursorPosition(pos)
        CGAssociateMouseAndMouseCursorPosition(1)
        postMouse(.mouseMoved, .left)
        transitionSeq += 1
        let seq = transitionSeq
        // 后续的环出现前，如果已经退出活动状态（光标回主控或断线），就不再出新环
        let stillHere: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.active && self.transitionSeq == seq
        }
        playRipple(.arrive, at: pos, present: stillHere)
        if let payload, let s {
            log("进入活动状态：落在「\(s.name)」\(payload.edge.edgeLabel) \(fmt(payload.mm)) 毫米处 (\(Int(pos.x)), \(Int(pos.y)))")
        } else {
            log("进入活动状态：光标放到 (\(Int(pos.x)), \(Int(pos.y)))")
        }
    }

    // 所有退出活动状态的路径（推回主控、主控紧急收回、断线、角色停止）都在这里，统一在当前虚拟光标位置播离开波纹。
    // hideCursor：光标真正离开本机（推回主控、紧急收回）时为 true，短暂隐藏本机光标直到离开波纹播完；
    // 断线、角色停止时为 false（这些情况要立刻显示光标）。
    func deactivate(reason: String, hideCursor: Bool = true) {
        transitionSeq += 1
        let seq = transitionSeq
        releaseAll()
        active = false
        log("退出活动状态（\(reason)）")
        let token = hideCursor
            ? hider.hide(reason: "光标离开本机：\(reason)", expected: CursorHider.hideDuration(rippleConfig))
            : nil
        // 离开环一直出在离开点；光标又回到本机（再次进入）就不再出新环
        playRipple(.leave, at: pos, present: { [weak self] in
            guard let self else { return false }
            return !self.active && self.transitionSeq == seq
        }, onFinished: token.map { t in
            { [weak self] in self?.hider.show(token: t, reason: .animationDone) }
        })
    }

    func move(dx: CGFloat, dy: CGFloat) {
        let ds = activeDisplays()
        guard !ds.isEmpty else { return }
        let m = map()
        let p1 = CGPoint(x: pos.x + dx, y: pos.y + dy)
        let hit = m.hit(from: pos, to: p1)
        // 规则盖住了自家相通段：系统会把光标挪进自家另一块屏，没法在边上累计外推，所以一穿过就算
        let intoOwn = hit.map { h in
            ds.contains { $0.contains(p1) } && !(m.local[h.localScreen]?.frame.contains(p1) ?? false)
        } ?? false
        let outward = debounce.pendingEdge.map { outwardComponent(dx: dx, dy: dy, $0) }
        if debounce.feed(hit: hit, beyond: hit.map { beyondEdge(p1, $0) } ?? 0, intoOwnScreen: intoOwn,
                         sinceEnter: Date().timeIntervalSince(enteredAt), outwardOnPending: outward),
           let h = hit {
            sendLeave(h)
            deactivate(reason: "光标从规则 \(h.ruleID.prefix(8)) 的\(h.localEdge.edgeLabel)段推出，交还主控（对方屏\(h.remoteEdge.edgeLabel) \(fmt(h.remoteMM)) 毫米）")
            return
        }
        var n = CGPoint(x: pos.x + dx, y: pos.y + dy)
        if !ds.contains(where: { $0.contains(n) }) {
            let cur = ds.first(where: { $0.contains(pos) }) ?? ds[0]
            n.x = clamp(n.x, cur.minX, cur.maxX - 1)
            n.y = clamp(n.y, cur.minY, cur.maxY - 1)
        }
        pos = n
        let (type, btn, num) = dragKind()
        postMouse(type, btn, dx: Int64(dx), dy: Int64(dy), buttonNumber: num)
    }

    func dragKind() -> (CGEventType, CGMouseButton, Int64?) {
        if heldButtons.contains(0) { return (.leftMouseDragged, .left, nil) }
        if heldButtons.contains(1) { return (.rightMouseDragged, .right, nil) }
        if let b = heldButtons.min() { return (.otherMouseDragged, CGMouseButton(rawValue: UInt32(b)) ?? .center, Int64(b)) }
        return (.mouseMoved, .left, nil)
    }

    func button(_ b: Int, down: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if down {
            var count: Int64 = 1
            if let lc = lastClick, lc.button == b, now - lc.time < NSEvent.doubleClickInterval,
               hypot(pos.x - lc.pos.x, pos.y - lc.pos.y) <= 4 {
                count = lc.count + 1
            }
            lastClick = (b, now, pos, count)
            heldButtons.insert(b)
        } else {
            heldButtons.remove(b)
        }
        let count = (lastClick?.button == b ? lastClick?.count : nil) ?? 1
        postMouse(mouseType(b, down: down), CGMouseButton(rawValue: UInt32(b)) ?? .center,
                  click: count, buttonNumber: Int64(b))
    }

    func mouseType(_ b: Int, down: Bool) -> CGEventType {
        switch b {
        case 0: return down ? .leftMouseDown : .leftMouseUp
        case 1: return down ? .rightMouseDown : .rightMouseUp
        default: return down ? .otherMouseDown : .otherMouseUp
        }
    }

    func inject(_ d: Data) {
        guard let e = CGEvent(withDataAllocator: nil, data: d as CFData) else {
            log("警告：无法还原主控发来的事件（\(d.count) 字节）")
            return
        }
        e.setIntegerValueField(.eventSourceUserData, value: kInjectedMarker)
        let kc = e.getIntegerValueField(.keyboardEventKeycode)
        switch e.type {
        case .scrollWheel:
            e.location = pos
        case .keyDown:
            heldKeys.insert(kc)
            flags = e.flags.intersection(modifierMask)
        case .keyUp:
            heldKeys.remove(kc)
            flags = e.flags.intersection(modifierMask)
        case .flagsChanged:
            if let m = modifierKeyFlags[kc] {
                if e.flags.contains(m) {
                    heldModifiers.insert(kc)
                } else {
                    heldModifiers = heldModifiers.filter { modifierKeyFlags[$0] != m }
                }
            }
            flags = e.flags.intersection(modifierMask)
        default:
            break
        }
        e.post(tap: .cghidEventTap)
    }

    func postMouse(_ type: CGEventType, _ btn: CGMouseButton, dx: Int64 = 0, dy: Int64 = 0,
                   click: Int64? = nil, buttonNumber: Int64? = nil) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: btn) else {
            log("警告：创建鼠标事件失败（类型 \(type.rawValue)）")
            return
        }
        e.setIntegerValueField(.mouseEventDeltaX, value: dx)
        e.setIntegerValueField(.mouseEventDeltaY, value: dy)
        if let click { e.setIntegerValueField(.mouseEventClickState, value: click) }
        if let buttonNumber { e.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber) }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: kInjectedMarker)
        e.post(tap: .cghidEventTap)
    }

    // 离开活动状态或断线时，把还按着的键全部补发抬起，防止「键卡住」
    func releaseAll() {
        let nb = heldButtons.count, nk = heldKeys.count, nm = heldModifiers.count
        for b in heldButtons.sorted() {
            postMouse(mouseType(b, down: false), CGMouseButton(rawValue: UInt32(b)) ?? .center,
                      click: 1, buttonNumber: Int64(b))
        }
        heldButtons.removeAll()
        for k in heldKeys {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k), keyDown: false) {
                e.setIntegerValueField(.eventSourceUserData, value: kInjectedMarker)
                e.post(tap: .cghidEventTap)
            }
        }
        heldKeys.removeAll()
        var remaining = flags
        for k in heldModifiers {
            if let m = modifierKeyFlags[k] { remaining.remove(m) }
            if let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(k), keyDown: false) {
                e.type = .flagsChanged
                e.flags = remaining
                e.setIntegerValueField(.eventSourceUserData, value: kInjectedMarker)
                e.post(tap: .cghidEventTap)
            }
        }
        heldModifiers.removeAll()
        flags = []
        if nb + nk + nm > 0 {
            log("补发抬起：\(nb) 个鼠标键、\(nk) 个普通键、\(nm) 个修饰键")
        }
    }
}

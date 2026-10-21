// 被控方的「光标离开时短暂隐藏本机光标」：
//   光标从本机推回主控、被主控用热键收回、或在本机「重置键鼠状态」时，立刻隐藏本机光标；离开波纹全部播完后重新显示（光标留在离开的位置）。
//   提前显示的情况：光标又回到本机、本机自带的触控板 / 鼠标 / 键盘有输入、断线、角色切换、解除配对、退出。
//   光标特效总开关关闭时不隐藏（没有离开动画）。主控方的光标逻辑完全不走这里。
//
// 这里分两部分：
//   - CursorHider：纯状态机（隐藏 / 显示严格成对、每次隐藏一个令牌、兜底计时），系统调用和计时都由外部注入，自测里直接断言；
//   - LocalInputMonitor：只监听不拦截的事件截获，隐藏期间发现「本机真实输入」就通知显示。
//     MacKVM 自己注入的事件都打了 eventSourceUserData 标记（kInjectedMarker），再加上比对事件来源进程号，两者任一命中就不算本机输入。

import AppKit
import Foundation

/// MacKVM 注入事件时写进 eventSourceUserData 的标记（"MKVM" 的 ASCII）
let kInjectedMarker: Int64 = 0x4D4B_564D

enum CursorShowReason: String {
    case animationDone = "离开波纹播完"
    case returned = "光标回到本机"
    case localInput = "本机有输入"
    case fallback = "兜底计时到点"
    case disconnect = "连接断开"
    case roleStop = "被控角色停止（角色切换 / 解除配对 / 退出）"
}

final class CursorHider {
    /// 隐藏时长 = 离开波纹的持续时间 + 最后一个环的时长；总开关关掉时不隐藏（返回 nil）
    static func hideDuration(_ c: RippleConfig) -> Double? {
        c.enabled ? max(c.leaveTotal, 0) + c.leaveDuration : nil
    }
    /// 兜底：比预计多等 1 秒仍没显示就强制显示
    static let fallbackSlack = 1.0

    private let hideCursor: () -> Void
    private let showCursor: () -> Void
    private let now: () -> Double
    private let schedule: (Double, @escaping () -> Void) -> Void
    private let report: (String) -> Void
    var onHiddenChanged: ((Bool) -> Void)?

    private(set) var hidden = false
    private(set) var token = 0
    private var hiddenAt = 0.0

    init(hideCursor: @escaping () -> Void, showCursor: @escaping () -> Void,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (Double, @escaping () -> Void) -> Void = { d, f in
             DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f)
         },
         report: @escaping (String) -> Void = { log($0) }) {
        self.hideCursor = hideCursor
        self.showCursor = showCursor
        self.now = now
        self.schedule = schedule
        self.report = report
    }

    /// 隐藏光标。返回这次隐藏的令牌（动画结束时凭它显示，过期的令牌不起作用）；已经隐藏着或不该隐藏时返回 nil。
    @discardableResult
    func hide(reason: String, expected: Double?) -> Int? {
        guard let expected, !hidden else { return nil }
        hideCursor()
        hidden = true
        token += 1
        hiddenAt = now()
        let t = token
        report("隐藏本机光标（\(reason)），预计 \(String(format: "%.1f", expected)) 秒后随离开波纹播完重新显示")
        onHiddenChanged?(true)
        schedule(expected + CursorHider.fallbackSlack) { [weak self] in self?.show(token: t, reason: .fallback) }
        return t
    }

    /// 只在令牌仍是当前这次隐藏时才显示（动画结束、兜底计时用）
    func show(token t: Int, reason: CursorShowReason) {
        guard t == token else { return }
        show(reason: reason)
    }

    /// 所有显示路径都汇到这里；没隐藏时什么都不做，保证隐藏 / 显示成对
    func show(reason: CursorShowReason) {
        guard hidden else { return }
        showCursor()
        hidden = false
        report("重新显示本机光标（\(reason.rawValue)），实际隐藏了 \(String(format: "%.2f", now() - hiddenAt)) 秒")
        onHiddenChanged?(false)
    }
}

/// 一个事件算不算「本机真实输入」：类型是用户操作，并且不是 MacKVM 自己注入的
func isLocalUserInput(type: CGEventType, userData: Int64, sourcePID: Int64, myPID: Int64) -> Bool {
    let userTypes: Set<CGEventType> = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                       .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                       .scrollWheel, .keyDown]
    guard userTypes.contains(type) else { return false }
    if userData == kInjectedMarker { return false }
    if sourcePID == myPID { return false }
    return true
}

// MARK: - 本机输入监听（只监听，不拦截任何事件）

private var theInputMonitor: LocalInputMonitor?

private let inputMonitorCallback: CGEventTapCallBack = { _, type, event, _ in
    theInputMonitor?.observe(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

final class LocalInputMonitor {
    var onLocalInput: (() -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let myPID = Int64(getpid())

    /// 建好截获通道但先不启用；只在光标隐藏期间启用
    func install() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .scrollWheel, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: inputMonitorCallback, userInfo: nil) else {
            log("警告：本机输入监听创建失败；光标隐藏期间本机有输入也只能等波纹播完再显示")
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: false)
        theInputMonitor = self
        log("本机输入监听已就绪（只监听不拦截，只在光标隐藏期间启用）")
    }

    func setEnabled(_ on: Bool) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
    }

    func uninstall() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        if theInputMonitor === self { theInputMonitor = nil }
    }

    fileprivate func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            return   // 只在隐藏期间才需要；被系统停用就停用，下次隐藏时会重新启用
        }
        guard isLocalUserInput(type: type,
                               userData: event.getIntegerValueField(.eventSourceUserData),
                               sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
                               myPID: myPID) else { return }
        DispatchQueue.main.async { [weak self] in self?.onLocalInput?() }
    }
}

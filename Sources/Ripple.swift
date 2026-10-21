// 光标跨机器时的波纹效果（07「光标特效」页可调，两台同步）：
//   离开的那台：在离开点（固定不动）每隔「出环间隔」出一个环，直到满「持续时间」；
//              期间光标又回到本机就不再出新环（已出的环播完）。
//   进入的那台：进入点立即出第 1 个环，之后每隔「出环间隔」在光标当前位置出一个环，
//              鼠标停下、到达上限或光标离开本机就不再出新环。
// 每个环原地扩散、不跟随光标；颜色按该组颜色列表循环取（第 1 个环用第 1 个颜色）。
// 参数来自全局 rippleConfig（由 AppModel 写入）；总开关关掉时什么都不画，
// 正在出环的也在下一拍停下。
// 什么时候出、什么时候停由纯逻辑 TrailRule 决定（自测里直接断言），RingTrail 只负责按它的结论画。
// 纯视觉，不影响切换：调用方一律经 DispatchQueue.main.async 排到截获回调之后才真正画。

import AppKit
import QuartzCore

// MARK: - 样子参数

/// 当前生效的波纹参数（只在主线程读写）
var rippleConfig = RippleConfig.defaults

struct RippleParams {
    let maxRadius: CGFloat               // 最大半径（点），每个环都从 RippleStyle.minRadius 扩散到这里
    let duration: CFTimeInterval         // 单个环的时长（秒）
    let lineWidth: CGFloat               // 线宽（点）
    let opacity: Float                   // 开头的不透明度（0~1），扩散过程中淡出到 0
}

enum RippleStyle {
    static let minRadius: CGFloat = 1    // 每个环的起始半径（点）
    static let lineWidth: CGFloat = 2
    static let opacity: Float = 0.8

    static func params(_ kind: RippleKind, _ c: RippleConfig) -> RippleParams {
        kind == .leave
            ? RippleParams(maxRadius: c.leaveSize, duration: c.leaveDuration, lineWidth: lineWidth, opacity: opacity)
            : RippleParams(maxRadius: c.arriveSize, duration: c.arriveDuration, lineWidth: lineWidth, opacity: opacity)
    }
}

enum RippleKind {
    case leave      // 光标离开的那台
    case arrive     // 光标进入的那台

    var label: String { self == .leave ? "离开波纹" : "进入波纹" }
}

// MARK: - 出环规则（纯逻辑）

/// 第 1 个环在开始时立即出；之后每隔 interval 问一次 decide，决定再出一个环还是停下。
/// 所有时间都从开始那一刻算起（秒）。
struct TrailRule: Equatable {
    enum Decision: Equatable {
        case spawn
        case stop(String)
    }

    let kind: RippleKind
    let interval: Double        // 出环间隔
    let minDuration: Double     // 进入：至少持续（这段时间内鼠标动不动都照常出环）
    let idleStop: Double        // 进入：过了下限后，光标连续这么久没动就停
    let maxDuration: Double     // 进入：最长持续；离开：持续时间

    static func leave(_ c: RippleConfig) -> TrailRule {
        TrailRule(kind: .leave, interval: c.leaveInterval, minDuration: c.leaveTotal, idleStop: .infinity,
                  maxDuration: c.leaveTotal)
    }

    static func arrive(_ c: RippleConfig) -> TrailRule {
        TrailRule(kind: .arrive, interval: c.spawnInterval, minDuration: c.minDuration, idleStop: c.idleStop,
                  maxDuration: max(c.maxDuration, c.minDuration))
    }

    /// - elapsed：从开始到现在
    /// - sinceMove：离光标最后一次移动多久（只对进入波纹有意义）
    /// - present：离开波纹 = 光标仍在别处（没回到本机）；进入波纹 = 光标仍在本机
    func decide(elapsed: Double, sinceMove: Double, present: Bool) -> Decision {
        guard present else { return .stop(kind == .leave ? "光标回到本机" : "光标离开本机") }
        // 定时器触发时间有几毫秒抖动，比较时留半个间隔的余量，让「满 1 秒」这类边界落在对应的那一拍上
        let slack = interval / 2
        switch kind {
        case .leave:
            return elapsed + slack >= maxDuration ? .stop("到达持续时间") : .spawn
        case .arrive:
            if elapsed + slack >= maxDuration { return .stop("到达上限") }
            if elapsed + slack >= minDuration, sinceMove + slack >= idleStop { return .stop("鼠标停下") }
            return .spawn
        }
    }
}

// 正在播放的波纹窗口，播完就移除，不会越积越多
private var liveRipples: [ObjectIdentifier: NSPanel] = [:]
// 正在出环的波纹，停下时移除（07 页卡片预览的出环也登记在这里）
var liveTrails: [ObjectIdentifier: RingTrail] = [:]

/// 在 CG 全局坐标（原点在主屏左上角、y 向下）的点上开始一次真实的屏幕波纹。总开关关掉时不播。
/// 一律异步执行：可以在截获回调里直接调用，不会拖慢回调。
/// present 的含义见 TrailRule.decide：离开波纹问「光标还在别处吗」，进入波纹问「光标还在本机吗」。
/// onFinished：出环停下、并且最后一个环也播完的那一刻调用（没播成的情况下立即调用），
/// 被控方据此在离开波纹播完时重新显示光标。
func playRipple(_ kind: RippleKind, at cgPoint: CGPoint,
                present: @escaping () -> Bool = { true }, onFinished: (() -> Void)? = nil) {
    DispatchQueue.main.async {
        let cfg = rippleConfig
        guard cfg.enabled, !NSScreen.screens.isEmpty else {
            if cfg.enabled { log("警告：没有屏幕，跳过\(kind.label)") }
            onFinished?()
            return
        }
        let params = RippleStyle.params(kind, cfg)
        let colors = kind == .leave ? cfg.leaveColors : cfg.arriveColors
        log("\(kind.label)开始：(\(Int(cgPoint.x)), \(Int(cgPoint.y)))")
        let t = RingTrail(start: cgPoint, rule: kind == .leave ? TrailRule.leave(cfg) : TrailRule.arrive(cfg),
                          ringDuration: params.duration, quiet: false,
                          present: { rippleConfig.enabled && present() },
                          sample: { CGEvent(source: nil)?.location },
                          spawn: { pt, i in showRing(params, color: cycledColor(colors, i), at: pt) != nil })
        t.onFinished = onFinished
        t.start()
    }
}

// MARK: - 出环调度
//
// 主队列上一个每「出环间隔」触发一次的定时器：取光标当前位置（挪动超过 1 像素记为最后一次移动），
// 问 TrailRule 要不要再出一个环。离开波纹的环固定出在起点，进入波纹的环出在光标当前位置。
// 「光标在哪」和「环画在哪」由调用方注入：真实效果读系统光标、画屏幕叠加窗口；
// 07 页的卡片预览读卡片里的鼠标位置、画在卡片图层里。两边共用同一套出环规则。

final class RingTrail {
    let present: () -> Bool
    let sample: () -> CGPoint?
    let spawn: (CGPoint, Int) -> Bool       // 第 i 个环（从 0 起）出在哪个点；返回是否画成
    let rule: TrailRule
    let ringDuration: Double
    let quiet: Bool
    let origin: CGPoint
    var startTime: CFTimeInterval = 0
    var lastMoveTime: CFTimeInterval = 0
    var lastSample: CGPoint
    var rings = 0
    var lastSpawnTime: CFTimeInterval = 0
    var timer: DispatchSourceTimer?
    var onFinished: (() -> Void)?

    init(start: CGPoint, rule: TrailRule, ringDuration: Double, quiet: Bool, present: @escaping () -> Bool,
         sample: @escaping () -> CGPoint?, spawn: @escaping (CGPoint, Int) -> Bool) {
        lastSample = start
        origin = start
        self.rule = rule
        self.ringDuration = ringDuration
        self.quiet = quiet
        self.present = present
        self.sample = sample
        self.spawn = spawn
    }

    /// 立即在起点出第 1 个环，然后按间隔继续
    func start() {
        startTime = CACurrentMediaTime()
        lastMoveTime = startTime
        lastSpawnTime = startTime
        if spawn(origin, 0) { rings = 1 }
        liveTrails[ObjectIdentifier(self)] = self
        let iv = max(rule.interval, 0.02)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + iv, repeating: iv, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func tick() {
        let now = CACurrentMediaTime()
        let pt = sample() ?? lastSample
        if hypot(pt.x - lastSample.x, pt.y - lastSample.y) > 1 { lastMoveTime = now }
        lastSample = pt
        switch rule.decide(elapsed: now - startTime, sinceMove: now - lastMoveTime, present: present()) {
        case .stop(let reason):
            finish(reason)
        case .spawn:
            if spawn(rule.kind == .leave ? origin : pt, rings) {
                rings += 1
                lastSpawnTime = now
            }
        }
    }

    func finish(_ reason: String) {
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        if !quiet {
            let secs = String(format: "%.1f", CACurrentMediaTime() - startTime)
            log("\(rule.kind.label)结束（\(reason)）：共出 \(rings) 个环，持续 \(secs) 秒")
        }
        liveTrails.removeValue(forKey: ObjectIdentifier(self))
        // 最后一个环播完的时刻：最后一次出环 + 单环时长
        if let done = onFinished {
            onFinished = nil
            let wait = max(0, lastSpawnTime + ringDuration - CACurrentMediaTime())
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: done)
        }
    }
}

/// 在一个点上出一个环：单独一个叠加窗口，播完（单环时长 + 0.1 秒）关闭。返回所在屏幕的序号（从 0 起）。
@discardableResult
private func showRing(_ pr: RippleParams, color: String, at cgPoint: CGPoint) -> Int? {
    let screens = NSScreen.screens
    guard let primary = screens.first else { return nil }
    // CG 全局坐标 → AppKit 坐标（原点在主屏左下角、y 向上）。NSScreen.screens[0] 就是主屏。
    let p = NSPoint(x: cgPoint.x, y: primary.frame.maxY - cgPoint.y)
    // 找点所在的屏幕；点正好压在屏幕边线上时放宽 1 点，再不行取最近的一块
    let idx = screens.firstIndex(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(p) })
        ?? screens.indices.min(by: { distance(p, screens[$0].frame) < distance(p, screens[$1].frame) })!
    let screen = screens[idx]

    // 窗口按这一组的「最大半径 + 线宽」定尺寸，环不会被窗口边界截掉
    let r = pr.maxRadius + pr.lineWidth
    let frame = NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.setFrame(frame, display: false) // 无边框窗口不会被系统挪回屏幕内，圆心保持在原点

    let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    panel.contentView = view

    addRingLayer(to: view.layer!, center: CGPoint(x: r, y: r), params: pr, color: color,
                 scale: screen.backingScaleFactor)

    let id = ObjectIdentifier(panel)
    liveRipples[id] = panel
    panel.orderFrontRegardless()

    DispatchQueue.main.asyncAfter(deadline: .now() + pr.duration + 0.1) {
        panel.orderOut(nil)
        panel.close()
        liveRipples.removeValue(forKey: id)
    }
    return idx
}

/// 在宿主图层上加一个环：CAShapeLayer + Core Animation（easeOut 扩散、线性淡出），由系统渲染服务独立跑动画，不占主线程。
/// 真实效果（屏幕叠加窗口）和 07 页卡片预览共用这一段。center 是宿主图层坐标（原点在左下角）。
/// 播完自动移除。frozenProgress 只给离屏自查用：不加动画，直接把环定格在第几成进度（0~1）。
func addRingLayer(to host: CALayer, center: CGPoint, params pr: RippleParams, color: String, scale: CGFloat,
                  frozenProgress: Double? = nil) {
    func circle(_ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius),
               transform: nil)
    }
    let ring = CAShapeLayer()
    ring.frame = host.bounds
    ring.contentsScale = scale
    ring.fillColor = nil
    ring.strokeColor = cgColor(hex: color)
    ring.lineWidth = pr.lineWidth
    if let p = frozenProgress {
        ring.path = circle(RippleStyle.minRadius + (pr.maxRadius - RippleStyle.minRadius) * CGFloat(caEaseOut(p)))
        ring.opacity = pr.opacity * Float(1 - p)
        host.addSublayer(ring)
        return
    }
    // 模型值设成终态（最大半径、完全透明），动画结束后不会闪回起始样子
    ring.path = circle(pr.maxRadius)
    ring.opacity = 0
    let grow = CABasicAnimation(keyPath: "path")
    grow.fromValue = circle(RippleStyle.minRadius)
    grow.toValue = circle(pr.maxRadius)
    grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = pr.opacity
    fade.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [grow, fade]
    group.duration = pr.duration
    ring.add(group, forKey: "ripple")
    host.addSublayer(ring)
    DispatchQueue.main.asyncAfter(deadline: .now() + pr.duration + 0.05) { [weak ring] in ring?.removeFromSuperlayer() }
}

func cgColor(hex: String) -> CGColor {
    let (r, g, b) = parseHexColor(hex) ?? (0.157, 0.412, 0.91)
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

private func distance(_ p: NSPoint, _ r: NSRect) -> CGFloat {
    let dx = max(r.minX - p.x, 0, p.x - r.maxX)
    let dy = max(r.minY - p.y, 0, p.y - r.maxY)
    return hypot(dx, dy)
}

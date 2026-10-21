// 07「光标特效」页的卡片预览：把左右两张参数卡片当作并排的两块显示器，中间的分界线就是两块屏幕相接的边。
//   - 只有鼠标从一张卡片直接越过分界线到另一张卡片才触发：离开的那张在越线点播离开波纹，
//     进入的那张从越线点开始沿鼠标轨迹播进入波纹；从卡片上边、下边、外侧边进出都不触发。
//   - 离开效果一律用离开波纹的参数和颜色，进入效果一律用进入波纹的参数和颜色；尺寸、节奏和真实效果 1:1。
//   - 越线后马上越回来：和真实跨屏一样，原来那张的进入波纹停止出新环、在越线点播离开波纹；
//     另一张正在播的离开波纹停止出新环、开始播进入波纹。已出的环各自播完。
//   - 出环规则和真实效果共用 TrailRule + RingTrail，只是「环画在哪」换成卡片里的图层（UI/RipplePage.swift 画）。
// CardCrossTracker 是纯逻辑（越线判定），自测里直接断言。坐标一律是两张卡片所在容器的坐标（左上角为原点）。
// 环本身和真实效果一样用 CAShapeLayer + Core Animation 画（Ripple.swift 的 addRingLayer），宿主是卡片里的图层视图。

import CoreGraphics
import Foundation
import QuartzCore

enum CardSide: Equatable {
    case left, right
}

/// 越线判定：记住鼠标最后待过的那张卡片；鼠标离开整个容器（上边、下边、外侧边）就清空。
/// 新位置落在另一张卡片里、且之间没有离开过容器，就算一次越线，越线点取上一点到这一点的连线和分界线的交点。
struct CardCrossTracker {
    struct Crossing: Equatable {
        let from: CardSide
        let to: CardSide
        let at: CGPoint
    }

    var cardWidth: CGFloat = 416
    var gap: CGFloat = 4
    var height: CGFloat = 350

    private(set) var lastPoint: CGPoint?
    private(set) var lastCard: CardSide?
    /// 鼠标此刻在哪张卡片里（在两卡之间的空隙或容器外时为 nil）
    private(set) var current: CardSide?

    var midX: CGFloat { cardWidth + gap / 2 }
    var totalWidth: CGFloat { cardWidth * 2 + gap }

    func side(of p: CGPoint) -> CardSide? {
        guard p.y >= 0, p.y <= height, p.x >= 0, p.x <= totalWidth else { return nil }
        if p.x < cardWidth { return .left }
        if p.x > cardWidth + gap { return .right }
        return nil
    }

    mutating func move(to p: CGPoint) -> Crossing? {
        guard p.y >= 0, p.y <= height, p.x >= 0, p.x <= totalWidth else {
            exit()
            return nil
        }
        let s = side(of: p)
        var crossing: Crossing?
        if let s, let lc = lastCard, lc != s {
            let a = lastPoint ?? p
            let t = a.x == p.x ? 1 : min(max((midX - a.x) / (p.x - a.x), 0), 1)
            crossing = Crossing(from: lc, to: s, at: CGPoint(x: midX, y: a.y + (p.y - a.y) * t))
        }
        if let s { lastCard = s }
        current = s
        lastPoint = p
        return crossing
    }

    /// 鼠标离开了整个容器
    mutating func exit() {
        lastPoint = nil
        lastCard = nil
        current = nil
    }
}

/// 一次出环命令（自测用的记录；画环本身交给卡片里的图层视图）
struct PreviewSpawn {
    let side: CardSide
    let kind: RippleKind
    let center: CGPoint         // 容器坐标
    let maxRadius: CGFloat
    let color: String
}

/// 卡片预览的状态。出环时直接调用对应卡片图层视图注册进来的闭包画环（Core Animation 跑动画），
/// 不经过 SwiftUI 的状态刷新，卡片里的参数行、步进框不会因为出环而重算。
final class RipplePreviewModel {
    var tracker = CardCrossTracker()
    /// 两张卡片各自的画环入口：参数是卡片坐标（左上角为原点）
    private var sinks: [CardSide: (CGPoint, RippleParams, String) -> Void] = [:]
    /// 最近的出环记录（只保留最后 200 条，自测用）
    private(set) var spawned: [PreviewSpawn] = []

    func setLayout(cardWidth: CGFloat, gap: CGFloat, height: CGFloat) {
        tracker.cardWidth = cardWidth
        tracker.gap = gap
        tracker.height = height
    }

    func register(_ side: CardSide, sink: @escaping (CGPoint, RippleParams, String) -> Void) {
        sinks[side] = sink
    }

    func pointerMoved(_ p: CGPoint) {
        if let c = tracker.move(to: p) { crossed(c) }
    }

    func pointerExited() {
        tracker.exit()
    }

    private func crossed(_ c: CardCrossTracker.Crossing) {
        let cfg = rippleConfig
        guard cfg.enabled else { return }
        // 离开：固定在越线点；鼠标回到这张卡片就停
        start(.leave, side: c.from, at: c.at, cfg: cfg, present: { [weak self] in self?.tracker.current != c.from })
        // 进入：从越线点开始跟着鼠标；鼠标离开这张卡片（任何一边）就停
        start(.arrive, side: c.to, at: c.at, cfg: cfg, present: { [weak self] in self?.tracker.current == c.to })
    }

    private func start(_ kind: RippleKind, side: CardSide, at p: CGPoint, cfg: RippleConfig,
                       present: @escaping () -> Bool) {
        let params = RippleStyle.params(kind, cfg)
        let colors = kind == .leave ? cfg.leaveColors : cfg.arriveColors
        let t = RingTrail(start: p, rule: kind == .leave ? TrailRule.leave(cfg) : TrailRule.arrive(cfg),
                          ringDuration: params.duration, quiet: true,
                          present: { rippleConfig.enabled && present() },
                          sample: { [weak self] in self?.tracker.lastPoint },
                          spawn: { [weak self] pt, i in
                              guard let self else { return false }
                              self.spawn(side: side, kind: kind, at: pt, params: params, color: cycledColor(colors, i))
                              return true
                          })
        t.start()
    }

    private func spawn(side: CardSide, kind: RippleKind, at p: CGPoint, params: RippleParams, color: String) {
        spawned.append(PreviewSpawn(side: side, kind: kind, center: p, maxRadius: params.maxRadius, color: color))
        if spawned.count > 200 { spawned.removeFirst(spawned.count - 200) }
        // 容器坐标 → 卡片坐标
        let dx = side == .left ? 0 : tracker.cardWidth + tracker.gap
        sinks[side]?(CGPoint(x: p.x - dx, y: p.y), params, color)
    }
}

/// 和 Core Animation 的 easeOut（三次贝塞尔 0, 0, 0.58, 1）一致的缓动，预览环的扩散和真实效果看起来一样
func caEaseOut(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    // 贝塞尔 x(t) = 3(1-t)^2 t·0 + 3(1-t) t^2·0.58 + t^3，y(t) = 3(1-t)^2 t·0 + 3(1-t) t^2·1 + t^3
    func bx(_ t: Double) -> Double { 3 * (1 - t) * t * t * 0.58 + t * t * t }
    func by(_ t: Double) -> Double { 3 * (1 - t) * t * t + t * t * t }
    var lo = 0.0, hi = 1.0
    for _ in 0..<30 {
        let mid = (lo + hi) / 2
        if bx(mid) < x { lo = mid } else { hi = mid }
    }
    return by((lo + hi) / 2)
}

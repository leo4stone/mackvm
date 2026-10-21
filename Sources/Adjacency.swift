// 屏幕相邻规则的纯逻辑（不碰系统接口，自测里直接断言）：
//   - 屏幕信息 ScreenInfo（稳定 ID、名字、是否主屏、点坐标框、物理毫米尺寸、尺寸是否估算）；
//   - 相邻规则 AdjacencyRule = 甲屏的某条边 ↔ 乙屏的对边 + 沿边错开的毫米数。两台存同一份，各自换算成本机视角 RuleView；
//   - 毫米 ↔ 点换算（点 = 毫米 / 边的物理长度 × 边的点长度），两条边实际挨着的那一段（重叠段）；
//   - 跨屏判定：前后两点连线穿过规则段落就跨过去（快速甩过短段也不漏），落点按毫米对应到对方屏那条边；
//   - 约束校验：同两块屏只能一条规则、同一条边上各规则的段落不重叠、挨着至少 10 毫米、盖住自家相通段只提醒；
//   - 默认规则：主控最右侧屏的右边 ↔ 被控最左侧屏的左边，中点对齐；
//   - 显示器位置后缀：同一台多块屏时按系统排列加「左 / 右 / 上 / 下 / 中」及组合。
// 坐标一律是该台 Mac 的 CG 全局点坐标（原点在主屏左上角，y 向下）。「边」用 Direction 表示：up = 上边，down = 下边。
// 沿边方向：左右两条竖边沿 y（向下增大），上下两条横边沿 x（向右增大）；两台规则里的沿边坐标按这个方向对齐。

import CoreGraphics
import Foundation

/// 规则两边挨着的长度至少这么长（毫米）
let kMinTouchMM = 10.0

// MARK: - 屏幕信息

struct ScreenInfo: Codable, Equatable, Identifiable {
    var id: String              // 稳定 ID（系统给显示器的 UUID，由厂商 / 型号 / 序列号决定，跨重启、跨插拔不变）
    var name: String            // 显示名（如「DELL U2720QM」「内建屏幕」），不含位置后缀
    var isMain: Bool
    var isBuiltin: Bool
    var x: Double, y: Double, w: Double, h: Double     // 点坐标框
    var mmW: Double, mmH: Double                        // 物理尺寸（毫米）
    var estimated: Bool                                 // 物理尺寸读不到，按分辨率估算的
    /// 可用区域（点坐标框）：整块屏扣掉程序坞条（来自 NSScreen.visibleFrame，见 Screens.swift）。nil = 和整块屏一样
    /// （旧版本发来的、或读不到时）。只用来定「跨屏触发线」「回本机的落点」「藏着的光标离边多远」，毫米换算仍按整块屏
    var ux: Double? = nil, uy: Double? = nil, uw: Double? = nil, uh: Double? = nil

    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var usableFrame: CGRect {
        guard let ux, let uy, let uw, let uh else { return frame }
        let r = CGRect(x: ux, y: uy, width: uw, height: uh).intersection(frame)
        return r.isNull || r.width < 100 || r.height < 100 ? frame : r
    }

    /// 对角线英寸（取整）
    var inches: Int { Int((hypot(mmW, mmH) / 25.4).rounded()) }

    func edgeLengthPt(_ e: Direction) -> Double { e.isVertical ? w : h }
    func edgeLengthMM(_ e: Direction) -> Double { e.isVertical ? mmW : mmH }
    /// 这条边沿边方向的起点（点）
    func edgeStartPt(_ e: Direction) -> Double { e.isVertical ? x : y }

    func ptToMM(_ alongPt: Double, _ e: Direction) -> Double {
        let len = edgeLengthPt(e)
        return len > 0 ? (alongPt - edgeStartPt(e)) / len * edgeLengthMM(e) : 0
    }

    func mmToPt(_ mm: Double, _ e: Direction) -> Double {
        let len = edgeLengthMM(e)
        return edgeStartPt(e) + (len > 0 ? mm / len * edgeLengthPt(e) : 0)
    }
}

// MARK: - 规则

struct AdjacencyRule: Codable, Equatable, Identifiable {
    var id: String
    var aDevice: String
    var aScreen: String
    var aEdge: Direction        // 甲屏用哪条边；乙屏用它的对边
    var bDevice: String
    var bScreen: String
    var offsetMM: Double        // 沿边方向上，乙屏边的起点相对甲屏边的起点错开多少毫米

    var bEdge: Direction { aEdge.opposite }

    /// 换成 me 这台的视角；规则不涉及 me 时返回 nil
    func view(from me: String) -> RuleView? {
        if aDevice == me {
            return RuleView(ruleID: id, localScreen: aScreen, localEdge: aEdge, remoteScreen: bScreen, offsetMM: offsetMM)
        }
        if bDevice == me {
            return RuleView(ruleID: id, localScreen: bScreen, localEdge: bEdge, remoteScreen: aScreen, offsetMM: -offsetMM)
        }
        return nil
    }

    /// 从本机视角造（或改）一条规则：甲固定是本机
    static func make(id: String, me: String, peer: String, view v: RuleView) -> AdjacencyRule {
        AdjacencyRule(id: id, aDevice: me, aScreen: v.localScreen, aEdge: v.localEdge,
                      bDevice: peer, bScreen: v.remoteScreen, offsetMM: v.offsetMM)
    }

    /// 两台各自修改同一条规则时，统一写回成「甲 = 原来的甲」，避免同一条规则来回翻转
    func updated(with v: RuleView, me: String) -> AdjacencyRule {
        var r = self
        if aDevice == me {
            r.aScreen = v.localScreen; r.aEdge = v.localEdge; r.bScreen = v.remoteScreen; r.offsetMM = v.offsetMM
        } else {
            r.bScreen = v.localScreen; r.aEdge = v.localEdge.opposite; r.aScreen = v.remoteScreen; r.offsetMM = -v.offsetMM
        }
        return r
    }
}

/// 本机视角的一条规则：本机屏 localScreen 的 localEdge 挨着对方屏 remoteScreen 的对边；
/// 沿边方向上，对方屏边的起点比本机屏边的起点错开 offsetMM 毫米
struct RuleView: Equatable {
    var ruleID: String
    var localScreen: String
    var localEdge: Direction
    var remoteScreen: String
    var offsetMM: Double

    var remoteEdge: Direction { localEdge.opposite }

    /// 两条边实际挨着的一段（本机屏这条边上的毫米区间）；不挨着时 hi <= lo
    func touch(_ local: ScreenInfo, _ remote: ScreenInfo) -> (lo: Double, hi: Double) {
        let lo = max(0, offsetMM)
        let hi = min(local.edgeLengthMM(localEdge), offsetMM + remote.edgeLengthMM(remoteEdge))
        return (lo, hi)
    }

    /// 本机边上的毫米位置 → 对方边上的毫米位置
    func remoteMM(fromLocal mm: Double) -> Double { mm - offsetMM }
}

// MARK: - 跨屏判定

/// 一次跨屏：从本机哪块屏、哪条规则出去，落到对方哪块屏哪条边的哪个毫米位置
struct CrossingHit: Equatable {
    var ruleID: String
    var localScreen: String
    var localEdge: Direction
    var crossPoint: CGPoint         // 连线和边的交点（点坐标，已夹回本机屏内）
    var localMM: Double
    var remoteScreen: String
    var remoteEdge: Direction
    var remoteMM: Double
}

/// 一组生效的规则（本机视角）+ 两台的屏幕信息。跨屏判定和落点都从这里算。
struct CrossingMap {
    var views: [RuleView]
    var local: [String: ScreenInfo]
    var remote: [String: ScreenInfo]

    init(views: [RuleView], localScreens: [ScreenInfo], remoteScreens: [ScreenInfo]) {
        self.views = views
        local = Dictionary(localScreens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        remote = Dictionary(remoteScreens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// 两块屏都在、并且挨着的长度够的规则才生效
    var activeViews: [RuleView] {
        views.filter { v in
            guard let l = local[v.localScreen], let r = remote[v.remoteScreen] else { return false }
            let t = v.touch(l, r)
            return t.hi - t.lo >= kMinTouchMM - 0.001
        }
    }

    /// 光标从 p0 移到 p1（p1 是没被系统夹住的位置：上一个位置 + 这一下的位移）。
    /// p0 在某块本机屏内、连线从里往外穿过这块屏某条规则边的段落，就算跨屏；有几条时取最先穿过的那条。
    /// 触发线是这块屏最靠边的那一行/列像素（下边、右边是 maxY−1 / maxX−1，上边、左边是 minY / minX），程序坞在这条边上也一样，
    /// 推过程序坞到屏幕边才切，程序坞照常能用。光标一碰到这一行就切；已经停在这一行上、这一下没有位移的事件
    /// （慢推时位移是亚像素）也算往外推。沿边的毫米换算按整块屏。
    /// 跨出点和落点放在可用区域里（扣掉程序坞条），回来时不落进程序坞。
    func hit(from p0: CGPoint, to p1: CGPoint) -> CrossingHit? {
        var best: (t: Double, hit: CrossingHit)?
        let still = p1 == p0
        for v in activeViews {
            guard let s = local[v.localScreen], let r = remote[v.remoteScreen] else { continue }
            let f = s.frame, u = s.usableFrame
            guard p0.x >= f.minX - 0.5, p0.x <= f.maxX, p0.y >= f.minY - 0.5, p0.y <= f.maxY else { continue }
            let e = v.localEdge
            let line: Double
            let crossed: Bool
            switch e {
            case .right: line = f.maxX - 1; crossed = (p1.x >= line && (p0.x < line || p1.x > p0.x)) || (still && line - p0.x < 1)
            case .left: line = f.minX; crossed = (p1.x <= line && (p0.x > line || p1.x < p0.x)) || (still && p0.x - line < 1)
            case .down: line = f.maxY - 1; crossed = (p1.y >= line && (p0.y < line || p1.y > p0.y)) || (still && line - p0.y < 1)
            case .up: line = f.minY; crossed = (p1.y <= line && (p0.y > line || p1.y < p0.y)) || (still && p0.y - line < 1)
            }
            guard crossed else { continue }
            var t: Double
            let along: Double
            if e.isVertical {
                t = p1.y == p0.y ? 1 : (line - p0.y) / (p1.y - p0.y)
                t = min(max(t, 0), 1)
                along = p0.x + t * (p1.x - p0.x)
            } else {
                t = p1.x == p0.x ? 1 : (line - p0.x) / (p1.x - p0.x)
                t = min(max(t, 0), 1)
                along = p0.y + t * (p1.y - p0.y)
            }
            let touch = v.touch(s, r)
            let lo = s.mmToPt(touch.lo, e), hi = s.mmToPt(touch.hi, e)
            guard along >= lo - 0.5, along <= hi + 0.5 else { continue }
            let mm = min(max(s.ptToMM(along, e), touch.lo), touch.hi)
            // 跨出点（回本机时没给落点就回到这里、离开波纹也出在这里）放在可用区域里
            let cp: CGPoint
            if e.isVertical {
                cp = CGPoint(x: min(max(along, u.minX), u.maxX - 1), y: e == .down ? u.maxY - 1 : u.minY)
            } else {
                cp = CGPoint(x: e == .right ? u.maxX - 1 : u.minX, y: min(max(along, u.minY), u.maxY - 1))
            }
            let hit = CrossingHit(ruleID: v.ruleID, localScreen: s.id, localEdge: e, crossPoint: cp, localMM: mm,
                                  remoteScreen: r.id, remoteEdge: v.remoteEdge,
                                  remoteMM: min(max(v.remoteMM(fromLocal: mm), 0), r.edgeLengthMM(v.remoteEdge)))
            if best == nil || t < best!.t { best = (t, hit) }
        }
        return best?.hit
    }

    /// 对方从规则跨过来时，本机屏 screen 的 edge 边上 mm 处的落点（往屏内收 1~2 点，防止立刻弹回）。
    /// 沿边位置按整块屏的毫米换算；落在可用区域的边上（程序坞在这条边上时落在程序坞上沿，不落进程序坞）
    static func landing(on s: ScreenInfo, edge e: Direction, mm: Double) -> CGPoint {
        let f = s.usableFrame
        let len = s.edgeLengthMM(e)
        let along = s.mmToPt(min(max(mm, 0), len), e)
        if e.isVertical {
            let x = min(max(along, f.minX), f.maxX - 1)
            return CGPoint(x: x, y: e == .down ? f.maxY - 2 : f.minY + 1)
        }
        let y = min(max(along, f.minY), f.maxY - 1)
        return CGPoint(x: e == .right ? f.maxX - 2 : f.minX + 1, y: y)
    }

    /// 点是否在本机某块屏内
    func isInsideAnyLocal(_ p: CGPoint) -> Bool {
        local.values.contains { $0.frame.contains(p) }
    }
}

// MARK: - 约束校验

enum RuleProblem: Equatable {
    case duplicatePair                      // 已有这两块屏的规则
    case tooShort(Double)                   // 挨着的长度不足 10 毫米（实际多少）
    case overlap(String)                    // 和哪条规则在同一条边上重叠（规则 ID）
    case missingScreen                      // 有一块屏现在不在（拔掉了）
}

enum RuleWarning: Equatable {
    case coversOwnShared(String)            // 盖住了自家相通的一段（被盖住的是哪块屏的 ID）
}

enum RuleCheck {
    /// 某块屏某条边被一条规则占用的毫米区间（以这块屏为准）
    static func segment(of rule: AdjacencyRule, screen: String, device: String,
                        screens: [String: ScreenInfo]) -> (edge: Direction, lo: Double, hi: Double)? {
        guard let v = rule.view(from: device), v.localScreen == screen,
              let l = screens[v.localScreen], let r = screens[v.remoteScreen] else { return nil }
        let t = v.touch(l, r)
        return (v.localEdge, t.lo, t.hi)
    }

    /// 校验一条规则（新加的或拖动中的）。others 是除它以外的规则；screens 是两台全部屏幕（ID 不会重复）。
    static func problems(_ rule: AdjacencyRule, others: [AdjacencyRule],
                         screens: [String: ScreenInfo]) -> [RuleProblem] {
        var out: [RuleProblem] = []
        if others.contains(where: { o in
            Set([o.aScreen, o.bScreen]) == Set([rule.aScreen, rule.bScreen])
        }) {
            out.append(.duplicatePair)
        }
        guard let a = screens[rule.aScreen], let b = screens[rule.bScreen] else {
            out.append(.missingScreen)
            return out
        }
        guard let va = rule.view(from: rule.aDevice) else { return out }
        let t = va.touch(a, b)
        if t.hi - t.lo < kMinTouchMM - 0.001 { out.append(.tooShort(max(0, t.hi - t.lo))) }
        // 两块屏各自那条边上，和别的规则的段落不能重叠（首尾相接可以）
        for (dev, scr) in [(rule.aDevice, rule.aScreen), (rule.bDevice, rule.bScreen)] {
            guard let mine = segment(of: rule, screen: scr, device: dev, screens: screens) else { continue }
            for o in others {
                guard let theirs = segment(of: o, screen: scr, device: dev, screens: screens),
                      theirs.edge == mine.edge else { continue }
                if min(mine.hi, theirs.hi) - max(mine.lo, theirs.lo) > 0.01, !out.contains(.overlap(o.id)) {
                    out.append(.overlap(o.id))
                }
            }
        }
        return out
    }

    /// 规则段落盖住了自家两块屏原本相通的一段：只提醒，不阻止
    static func warnings(_ rule: AdjacencyRule, screensByDevice: [String: [ScreenInfo]]) -> [RuleWarning] {
        var out: [RuleWarning] = []
        let all = Dictionary(screensByDevice.values.flatMap { $0 }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for dev in [rule.aDevice, rule.bDevice] {
            guard let v = rule.view(from: dev), let s = all[v.localScreen], let r = all[v.remoteScreen] else { continue }
            let t = v.touch(s, r)
            guard t.hi > t.lo else { continue }
            let lo = s.mmToPt(t.lo, v.localEdge), hi = s.mmToPt(t.hi, v.localEdge)
            for (slo, shi) in ownShared(s, v.localEdge, among: screensByDevice[dev] ?? []) where min(hi, shi) - max(lo, slo) > 0.5 {
                out.append(.coversOwnShared(s.id))
                break
            }
        }
        return out
    }

    /// 本机屏 s 的 e 边上，和自家别的屏挨着（光标原本能走过去）的点区间
    static func ownShared(_ s: ScreenInfo, _ e: Direction, among screens: [ScreenInfo]) -> [(Double, Double)] {
        let f = s.frame
        var out: [(Double, Double)] = []
        for o in screens where o.id != s.id {
            let g = o.frame
            let touching: Bool
            switch e {
            case .right: touching = abs(g.minX - f.maxX) < 1
            case .left: touching = abs(g.maxX - f.minX) < 1
            case .down: touching = abs(g.minY - f.maxY) < 1
            case .up: touching = abs(g.maxY - f.minY) < 1
            }
            guard touching else { continue }
            let lo = e.isVertical ? max(f.minX, g.minX) : max(f.minY, g.minY)
            let hi = e.isVertical ? min(f.maxX, g.maxX) : min(f.maxY, g.maxY)
            if hi > lo { out.append((lo, hi)) }
        }
        return out
    }
}

// MARK: - 默认规则

enum DefaultRule {
    /// 某台最右（right）/ 最左（left）的屏：边缘最靠外的；并列时取主屏，主屏不在其中就取最上面那块
    static func outermost(_ screens: [ScreenInfo], _ side: Direction) -> ScreenInfo? {
        guard !screens.isEmpty else { return nil }
        func edge(_ s: ScreenInfo) -> Double {
            switch side {
            case .right: return s.x + s.w
            case .left: return -s.x
            case .down: return s.y + s.h
            case .up: return -s.y
            }
        }
        let best = screens.map(edge).max()!
        let tied = screens.filter { abs(edge($0) - best) < 1 }
        if let m = tied.first(where: { $0.isMain }) { return m }
        return tied.min(by: { $0.y < $1.y })
    }

    /// 主控最右侧屏的右边 ↔ 被控最左侧屏的左边，中点对齐
    static func make(controller: String, controllerScreens: [ScreenInfo],
                     controlled: String, controlledScreens: [ScreenInfo], id: String) -> AdjacencyRule? {
        guard let a = outermost(controllerScreens, .right), let b = outermost(controlledScreens, .left) else { return nil }
        let offset = (a.edgeLengthMM(.right) - b.edgeLengthMM(.left)) / 2
        return AdjacencyRule(id: id, aDevice: controller, aScreen: a.id, aEdge: .right,
                             bDevice: controlled, bScreen: b.id, offsetMM: offset)
    }
}

// MARK: - 新规则的初始位置

enum NewRulePlacement {
    /// 优先用对方那台已有规则所在方向的边，不能用就按右、左、下、上找第一条能用的边；两边中点对齐。
    static func make(id: String, me: String, peer: String, local: ScreenInfo, remote: ScreenInfo,
                     existing: [AdjacencyRule], screens: [String: ScreenInfo]) -> AdjacencyRule? {
        var order: [Direction] = []
        for r in existing {
            if let v = r.view(from: me), !order.contains(v.localEdge) { order.append(v.localEdge) }
        }
        for d in [Direction.right, .left, .down, .up] where !order.contains(d) { order.append(d) }
        for e in order {
            let offset = (local.edgeLengthMM(e) - remote.edgeLengthMM(e.opposite)) / 2
            let r = AdjacencyRule.make(id: id, me: me, peer: peer,
                                       view: RuleView(ruleID: id, localScreen: local.id, localEdge: e,
                                                      remoteScreen: remote.id, offsetMM: offset))
            if RuleCheck.problems(r, others: existing, screens: screens).isEmpty { return r }
        }
        return nil
    }
}

// MARK: - 显示器位置后缀

enum ScreenNaming {
    /// 同一台多块屏时，按系统排列给每块屏一个位置后缀；只有一块屏时都是空字符串。
    /// 横向：x 范围重叠一半以上的算同一列；纵向同理。列数 2 → 左 / 右，3 个以上 → 左 / 中 / 右；行同理（上 / 中 / 下）。
    static func suffixes(_ screens: [ScreenInfo]) -> [String: String] {
        guard screens.count > 1 else { return Dictionary(screens.map { ($0.id, "") }, uniquingKeysWith: { a, _ in a }) }
        let h = rank(screens, vertical: false, labels: ("左", "中", "右"))
        let v = rank(screens, vertical: true, labels: ("上", "中", "下"))
        var out: [String: String] = [:]
        for s in screens { out[s.id] = (h[s.id] ?? "") + (v[s.id] ?? "") }
        return out
    }

    /// 带后缀的完整标签：「DELL U2720QM（左）」
    static func labels(_ screens: [ScreenInfo]) -> [String: String] {
        let suf = suffixes(screens)
        var out: [String: String] = [:]
        for s in screens {
            let x = suf[s.id] ?? ""
            out[s.id] = x.isEmpty ? s.name : "\(s.name)（\(x)）"
        }
        return out
    }

    private static func rank(_ screens: [ScreenInfo], vertical: Bool,
                             labels: (String, String, String)) -> [String: String] {
        func range(_ s: ScreenInfo) -> (Double, Double) { vertical ? (s.y, s.y + s.h) : (s.x, s.x + s.w) }
        // 并查集：范围重叠超过较短一方一半的归为一组
        var parent = Array(screens.indices)
        func find(_ i: Int) -> Int { parent[i] == i ? i : find(parent[i]) }
        for i in screens.indices {
            for j in screens.indices where j > i {
                let (a0, a1) = range(screens[i]), (b0, b1) = range(screens[j])
                let ov = min(a1, b1) - max(a0, b0)
                if ov > 0.5 * min(a1 - a0, b1 - b0) { parent[find(j)] = find(i) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in screens.indices { groups[find(i), default: []].append(i) }
        guard groups.count > 1 else { return [:] }
        let ordered = groups.values.sorted { g1, g2 in
            let c1 = g1.map { (range(screens[$0]).0 + range(screens[$0]).1) / 2 }.reduce(0, +) / Double(g1.count)
            let c2 = g2.map { (range(screens[$0]).0 + range(screens[$0]).1) / 2 }.reduce(0, +) / Double(g2.count)
            return c1 < c2
        }
        var out: [String: String] = [:]
        for (k, g) in ordered.enumerated() {
            let label = k == 0 ? labels.0 : (k == ordered.count - 1 ? labels.2 : labels.1)
            for i in g { out[screens[i].id] = label }
        }
        return out
    }
}

// MARK: - 跨屏消息负载

/// enter / leave 消息的内容：落到收方哪块屏、哪条边、沿边第几毫米
struct CrossPayload: Codable, Equatable {
    var screen: String
    var edge: Direction
    var mm: Double
}

// MARK: - 预览里拖动对方屏幕（纯逻辑）

enum RuleDrag {
    /// 规则在预览里的摆法：本机屏放在 (0, 0)，对方屏左上角的毫米坐标
    static func remoteOrigin(_ v: RuleView, local l: ScreenInfo, remote r: ScreenInfo) -> CGPoint {
        switch v.localEdge {
        case .right: return CGPoint(x: l.mmW, y: v.offsetMM)
        case .left: return CGPoint(x: -r.mmW, y: v.offsetMM)
        case .down: return CGPoint(x: v.offsetMM, y: l.mmH)
        case .up: return CGPoint(x: v.offsetMM, y: -r.mmH)
        }
    }

    /// 拖动中对方屏左上角到了 p（毫米），吸附到最近的一条边上；沿边位置靠近「中点对齐 / 两端对齐」6 毫米以内时吸过去
    static func snap(_ p: CGPoint, local l: ScreenInfo, remote r: ScreenInfo, base v: RuleView) -> RuleView {
        var best: (d: Double, view: RuleView)?
        for e in [Direction.right, .left, .down, .up] {
            let cross: Double
            var along: Double
            switch e {
            case .right: cross = abs(p.x - l.mmW); along = p.y
            case .left: cross = abs(p.x + r.mmW); along = p.y
            case .down: cross = abs(p.y - l.mmH); along = p.x
            case .up: cross = abs(p.y + r.mmH); along = p.x
            }
            // 离开本机屏太远（沿边完全不挨着）的边也算距离，让光标拖到哪边就吸到哪边
            let lenL = l.edgeLengthMM(e), lenR = r.edgeLengthMM(e.opposite)
            let outside = max(0, -(along + lenR), along - lenL)
            let d = cross + outside
            for target in [(lenL - lenR) / 2, 0, lenL - lenR] where abs(along - target) <= 6 {
                along = target
                break
            }
            let view = RuleView(ruleID: v.ruleID, localScreen: v.localScreen, localEdge: e,
                                remoteScreen: v.remoteScreen, offsetMM: (along * 10).rounded() / 10)
            if best == nil || d < best!.d { best = (d, view) }
        }
        return best!.view
    }
}

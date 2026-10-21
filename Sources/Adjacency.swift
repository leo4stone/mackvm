// 屏幕相邻规则的纯逻辑（不碰系统接口，自测里直接断言）：
//   - 屏幕信息 ScreenInfo（稳定 ID、名字、是否主屏、点坐标框、物理毫米尺寸、尺寸是否估算）；
//   - 相邻规则 AdjacencyRule = 甲屏的某条边 ↔ 乙屏的对边 + 沿边错开的毫米数。两台存同一份，各自换算成本机视角 RuleView。
//     规则由「设备连接」页上摆放的布局推导出来（见 Layout.swift），用户看不到规则本身；
//   - 毫米 ↔ 点换算（点 = 毫米 / 边的物理长度 × 边的点长度），两条边实际挨着的那一段（重叠段）；
//   - 跨屏判定：前后两点连线穿过规则段落就跨过去（快速甩过短段也不漏），落点按毫米对应到对方屏那条边；
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

// MARK: - 显示器位置后缀

/// 同一台多块屏时每块屏在本台里的位置：横向第几列、纵向第几行（first = 左 / 上，last = 右 / 下）。
/// 只算位置，不出文字；拼成「（左）」「 (Left)」这类后缀在界面层的文案表里做（Sources/UI/Strings.swift）。
struct ScreenPosition: Equatable {
    enum Slot: Int { case first = 0, middle = 1, last = 2 }
    var column: Slot?       // nil = 横向只有一列（不需要区分左右）
    var row: Slot?          // nil = 纵向只有一行
}

enum ScreenNaming {
    /// 同一台多块屏时，按系统排列给每块屏一个位置；只有一块屏时没有位置（不加后缀）。
    /// 横向：x 范围重叠一半以上的算同一列；纵向同理。列数 2 → 左 / 右，3 个以上 → 左 / 中 / 右；行同理（上 / 中 / 下）。
    static func positions(_ screens: [ScreenInfo]) -> [String: ScreenPosition] {
        guard screens.count > 1 else { return [:] }
        let h = rank(screens, vertical: false)
        let v = rank(screens, vertical: true)
        var out: [String: ScreenPosition] = [:]
        for s in screens { out[s.id] = ScreenPosition(column: h[s.id], row: v[s.id]) }
        return out
    }

    private static func rank(_ screens: [ScreenInfo], vertical: Bool) -> [String: ScreenPosition.Slot] {
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
        var out: [String: ScreenPosition.Slot] = [:]
        for (k, g) in ordered.enumerated() {
            let slot: ScreenPosition.Slot = k == 0 ? .first : (k == ordered.count - 1 ? .last : .middle)
            for i in g { out[screens[i].id] = slot }
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

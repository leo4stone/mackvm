// 屏幕布局的纯逻辑（不碰系统接口，自测里直接断言）。布局就是「设备连接」页上用户摆放的样子：
//   - 两台的每块屏在一张公共平面上的位置，记左上角的毫米坐标（x 向右、y 向下），存在共享设置里两台同步；
//   - 从布局推导相邻规则：本机一块屏和对方一块屏沿某条边挨着、挨着的长度至少 kMinTouchMM，就是一条 AdjacencyRule。
//     运行时跨屏判定只认规则（CrossingMap），布局只是规则的来源；
//   - 拖动摆放：靠近别的屏的边就吸附，两块屏不能叠在一起；
//   - 默认布局（配对完成时生成一次）：主控的屏按 macOS 排列，被控的屏整体放在主控最右侧屏的右边、两块屏中点对齐；
//   - 旧数据迁移：共享设置里只有规则、没有布局时，按规则把屏摆出来。
// 这里的布局和 macOS 自己的显示器排列无关：同一台 Mac 的几块屏在这里怎么摆都行，不影响光标在自家几块屏之间怎么走。

import CoreGraphics
import Foundation

/// 拖动时离别的屏的边（或对齐线）这么近就吸附上去（毫米）
let kSnapMM = 20.0
/// 两条边相距不超过这么多毫米就算挨着（吸附后本来就正好挨着，这里只兜住小数误差）
let kTouchToleranceMM = 0.5
/// 布局里还没摆过的屏放到最右边时，和已有的屏隔开这么多毫米（隔开才不会凭空多出一条能跨屏的边）
let kNewScreenGapMM = 40.0

/// 共享设置里存的一块屏的位置：哪台的哪块屏，左上角在布局里的毫米坐标
struct ScreenSpot: Codable, Equatable {
    var device: String
    var screen: String
    var x: Double
    var y: Double
}

/// 布局里的一块屏：位置加上屏幕信息（名字、物理尺寸）；present = 现在接着（对方的屏按上次收到的清单算）
struct PlacedScreen: Equatable {
    var device: String
    var info: ScreenInfo
    var x: Double
    var y: Double
    var present: Bool

    var rect: CGRect { CGRect(x: x, y: y, width: info.mmW, height: info.mmH) }
    var spot: ScreenSpot { ScreenSpot(device: device, screen: info.id, x: x, y: y) }
    /// 界面里区分每块屏用的键（不同的两台可能有 ID 相同的屏，所以带上设备 ID）
    var key: String { device + "/" + info.id }

    func isSame(_ device: String, _ screen: String) -> Bool { self.device == device && info.id == screen }
}

/// 两块屏沿某条边挨着的情况，以甲屏为准：甲屏的哪条边；乙屏那条边的起点比甲屏这条边的起点沿边错开多少毫米
/// （和 RuleView.offsetMM 同一个意思）；挨着的那一段有多长
struct EdgeContact: Equatable {
    var edge: Direction
    var offset: Double
    var length: Double
}

enum ScreenLayout {
    // MARK: 几何

    /// 甲、乙两块屏（布局里的毫米框）是不是沿某条边挨着；挨着的长度不大于 0（只碰到角）算不挨着
    static func contact(_ a: CGRect, _ b: CGRect) -> EdgeContact? {
        let t = kTouchToleranceMM
        let alongY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let alongX = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        var best: EdgeContact?
        func take(_ c: EdgeContact) {
            if c.length > 0, c.length > (best?.length ?? 0) { best = c }
        }
        if abs(b.minX - a.maxX) <= t { take(EdgeContact(edge: .right, offset: b.minY - a.minY, length: alongY)) }
        if abs(b.maxX - a.minX) <= t { take(EdgeContact(edge: .left, offset: b.minY - a.minY, length: alongY)) }
        if abs(b.minY - a.maxY) <= t { take(EdgeContact(edge: .down, offset: b.minX - a.minX, length: alongX)) }
        if abs(b.maxY - a.minY) <= t { take(EdgeContact(edge: .up, offset: b.minX - a.minX, length: alongX)) }
        return best
    }

    /// 挨着、并且挨着的长度够 kMinTouchMM（光标能从这一段跨过去）
    static func crossable(_ a: CGRect, _ b: CGRect) -> EdgeContact? {
        guard let c = contact(a, b), c.length >= kMinTouchMM - 0.001 else { return nil }
        return c
    }

    /// 两块屏叠在一起（只是边挨着不算）
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0.01 && min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.01
    }

    /// 把一块 size 大小的屏贴到 r 的 edge 边外侧，沿边比 r 这条边的起点错开 offset 毫米，返回它左上角的位置
    static func origin(_ size: CGSize, against r: CGRect, edge: Direction, offset: Double) -> CGPoint {
        switch edge {
        case .right: return CGPoint(x: r.maxX, y: r.minY + offset)
        case .left: return CGPoint(x: r.minX - size.width, y: r.minY + offset)
        case .down: return CGPoint(x: r.minX + offset, y: r.maxY)
        case .up: return CGPoint(x: r.minX + offset, y: r.minY - size.height)
        }
    }

    /// 放到已有这些屏的最右边：和最靠右的那块顶部对齐，中间隔开 kNewScreenGapMM
    static func originRight(of rects: [CGRect]) -> CGPoint {
        guard let r = rects.max(by: { $0.maxX < $1.maxX }) else { return .zero }
        return CGPoint(x: r.maxX + kNewScreenGapMM, y: r.minY)
    }

    // MARK: 拖动吸附

    /// 拖动中的屏（毫米框 m）吸附后的左上角位置。横、竖两个方向各自找离得最近、又在 kSnapMM 以内的目标：
    ///   - 贴边：m 的左边贴别的屏的右边、右边贴左边（两块屏上下范围有交集时）；上下同理；
    ///   - 沿边对齐：两块屏上下挨着（或快挨着）时左对左、右对右、中对中；左右挨着时上对上、下对下、中对中。
    /// 吸附后可能和别的屏叠在一起，由调用方判断能不能放下。
    static func snapped(_ m: CGRect, among others: [CGRect]) -> CGPoint {
        var bestX: (d: Double, v: Double)?
        var bestY: (d: Double, v: Double)?
        func consider(_ best: inout (d: Double, v: Double)?, target: Double, now: Double) {
            let d = abs(target - now)
            if d <= kSnapMM, best == nil || d < best!.d { best = (d, target) }
        }
        for o in others {
            let ySpan = m.minY < o.maxY + kSnapMM && m.maxY > o.minY - kSnapMM
            let xSpan = m.minX < o.maxX + kSnapMM && m.maxX > o.minX - kSnapMM
            if ySpan {
                consider(&bestX, target: o.maxX, now: m.minX)
                consider(&bestX, target: o.minX - m.width, now: m.minX)
            }
            if xSpan {
                consider(&bestY, target: o.maxY, now: m.minY)
                consider(&bestY, target: o.minY - m.height, now: m.minY)
            }
            let stacked = xSpan && (abs(m.minY - o.maxY) <= kSnapMM || abs(m.maxY - o.minY) <= kSnapMM)
            if stacked {
                consider(&bestX, target: o.minX, now: m.minX)
                consider(&bestX, target: o.maxX - m.width, now: m.minX)
                consider(&bestX, target: o.midX - m.width / 2, now: m.minX)
            }
            let sideBySide = ySpan && (abs(m.minX - o.maxX) <= kSnapMM || abs(m.maxX - o.minX) <= kSnapMM)
            if sideBySide {
                consider(&bestY, target: o.minY, now: m.minY)
                consider(&bestY, target: o.maxY - m.height, now: m.minY)
                consider(&bestY, target: o.midY - m.height / 2, now: m.minY)
            }
        }
        return CGPoint(x: bestX?.v ?? m.minX, y: bestY?.v ?? m.minY)
    }

    // MARK: 布局 → 规则

    /// 从布局推导相邻规则（按本机 me 的视角算，结果两台通用）：本机每块屏和对方每块屏，沿某条边挨着够 kMinTouchMM 就是一条。
    /// 同一对屏已有规则时沿用它的 ID 和甲乙方向，新挨上的一对才用 newID 生成 ID。
    /// 布局里没有、或者不知道尺寸的屏（placed 里没有它）上的规则原样留着，等知道了再说。
    static func rules(from placed: [PlacedScreen], me: String, peer: String, existing: [AdjacencyRule],
                      newID: () -> String) -> [AdjacencyRule] {
        func isPlaced(_ d: String, _ s: String) -> Bool { placed.contains { $0.isSame(d, s) } }
        var out = existing.filter { !isPlaced($0.aDevice, $0.aScreen) || !isPlaced($0.bDevice, $0.bScreen) }
        for l in placed where l.device == me {
            for r in placed where r.device == peer {
                guard let c = crossable(l.rect, r.rect) else { continue }
                let old = existing.first { x in
                    (x.aDevice == me && x.aScreen == l.info.id && x.bDevice == peer && x.bScreen == r.info.id)
                        || (x.aDevice == peer && x.aScreen == r.info.id && x.bDevice == me && x.bScreen == l.info.id)
                }
                let id = old?.id ?? newID()
                let v = RuleView(ruleID: id, localScreen: l.info.id, localEdge: c.edge, remoteScreen: r.info.id, offsetMM: c.offset)
                out.append(old.map { $0.updated(with: v, me: me) } ?? AdjacencyRule.make(id: id, me: me, peer: peer, view: v))
            }
        }
        return out
    }

    // MARK: 补全

    /// 界面上实际摆出来的布局：spots 里知道尺寸的屏照原位摆；现在接着、布局里还没有的屏（新插的显示器）
    /// 依次放到最右边。补上的位置只用来显示，用户拖动任何一块屏时整份布局（含补上的）才写进共享设置。
    /// info(设备, 屏幕) 查屏幕信息（现在接着的优先，其次是见过的）；present 是现在接着的屏（本机的和对方上次发来的）。
    static func placed(spots: [ScreenSpot], present: [(device: String, info: ScreenInfo)],
                       info: (String, String) -> ScreenInfo?) -> [PlacedScreen] {
        func isPresent(_ d: String, _ s: String) -> Bool { present.contains { $0.device == d && $0.info.id == s } }
        var out: [PlacedScreen] = []
        for s in spots where !out.contains(where: { $0.isSame(s.device, s.screen) }) {
            guard let i = info(s.device, s.screen) else { continue }
            out.append(PlacedScreen(device: s.device, info: i, x: s.x, y: s.y, present: isPresent(s.device, s.screen)))
        }
        for p in present where !out.contains(where: { $0.isSame(p.device, p.info.id) }) {
            let o = originRight(of: out.map(\.rect))
            out.append(PlacedScreen(device: p.device, info: p.info, x: o.x, y: o.y, present: true))
        }
        return out
    }

    // MARK: macOS 排列 → 毫米

    /// 一台 Mac 的屏按 macOS 的显示器排列换算成毫米：主屏放在 (0, 0)，其余的屏挨着已摆好的哪块屏就贴着它摆，
    /// 沿边的错开按那块已摆好的屏的「点 → 毫米」比例换算。各屏的点密度不同，换算后偶尔会叠在一起，叠上的那块改放到最右边。
    /// 返回屏幕 ID → 左上角的毫米坐标
    static func arranged(_ screens: [ScreenInfo]) -> [String: CGPoint] {
        guard let first = screens.first(where: { $0.isMain }) ?? screens.first else { return [:] }
        var rects: [String: CGRect] = [first.id: CGRect(x: 0, y: 0, width: first.mmW, height: first.mmH)]
        var rest = screens.filter { $0.id != first.id }
        while !rest.isEmpty {
            // 先找一块挨着已摆好的屏（按点坐标判断）的；找不到就拿剩下的第一块放到最右边
            var pick: (index: Int, origin: CGPoint)?
            search: for (i, s) in rest.enumerated() {
                for p in screens {
                    guard let pr = rects[p.id], let c = contact(p.frame, s.frame) else { continue }
                    let mm = c.offset / p.edgeLengthPt(c.edge) * p.edgeLengthMM(c.edge)
                    pick = (i, origin(CGSize(width: s.mmW, height: s.mmH), against: pr, edge: c.edge, offset: mm))
                    break search
                }
            }
            let i = pick?.index ?? 0
            let s = rest.remove(at: i)
            var o = pick?.origin ?? originRight(of: Array(rects.values))
            let size = CGSize(width: s.mmW, height: s.mmH)
            if rects.values.contains(where: { overlaps($0, CGRect(origin: o, size: size)) }) {
                o = originRight(of: Array(rects.values))
            }
            rects[s.id] = CGRect(origin: o, size: size)
        }
        return rects.mapValues(\.origin)
    }

    // MARK: 默认布局

    /// 某台最右（right）/ 最左（left）的屏（按 macOS 排列）：边缘最靠外的；并列时取主屏，主屏不在其中就取最上面那块
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

    /// 配对完成时的默认布局：两台各自的屏按 macOS 排列摆好；被控那组整体平移，
    /// 让被控最左侧屏的左边贴住主控最右侧屏的右边、两块屏中点对齐（推导出的规则就是「右边 ↔ 左边、中点对齐」）
    static func defaultLayout(controller: String, controllerScreens: [ScreenInfo],
                              controlled: String, controlledScreens: [ScreenInfo]) -> [ScreenSpot] {
        guard let a = outermost(controllerScreens, .right), let b = outermost(controlledScreens, .left) else { return [] }
        let ca = arranged(controllerScreens), cb = arranged(controlledScreens)
        guard let pa = ca[a.id], let pb = cb[b.id] else { return [] }
        var dx = pa.x + a.mmW - pb.x
        let dy = pa.y + (a.mmH - b.mmH) / 2 - pb.y
        func rect(_ s: ScreenInfo, _ o: CGPoint) -> CGRect { CGRect(x: o.x, y: o.y, width: s.mmW, height: s.mmH) }
        let fixed = controllerScreens.compactMap { s in ca[s.id].map { rect(s, $0) } }
        // 换算成毫米后，主控最右侧屏的右边偶尔还有别的主控屏：被控那组再往右挪，挪到不叠为止
        for _ in 0...controlledScreens.count * controllerScreens.count {
            let moved = controlledScreens.compactMap { s in cb[s.id].map { rect(s, CGPoint(x: $0.x + dx, y: $0.y + dy)) } }
            var push = 0.0
            for m in moved {
                for f in fixed where overlaps(f, m) { push = max(push, f.maxX - m.minX) }
            }
            if push == 0 { break }
            dx += push
        }
        return controllerScreens.compactMap { s in ca[s.id].map { ScreenSpot(device: controller, screen: s.id, x: $0.x, y: $0.y) } }
            + controlledScreens.compactMap { s in
                cb[s.id].map { ScreenSpot(device: controlled, screen: s.id, x: $0.x + dx, y: $0.y + dy) }
            }
    }

    // MARK: 旧数据迁移

    /// 共享设置里只有规则、没有布局时摆出布局：
    ///   1. 本机现在接着的屏按 macOS 排列摆好；
    ///   2. 规则提到的、还没摆的屏（对方的屏，或拔掉了的屏），按第一条「另一头已经摆好」的规则贴上去。
    ///      规则是按点排列定的，换成毫米后偶尔会和自家别的屏叠在一起，这时也照规则摆（规则保留），用户在界面上拖开即可；
    ///   3. 对方现在接着、规则没提到的屏，依次放到最右边。
    /// 之后由调用方从布局重新推导规则：几何上挨不上的规则（比如第二条规则想把同一块对方屏摆到另一处）就此去掉。
    /// info(设备, 屏幕) 查屏幕信息，查不到的屏不摆。
    static func migrated(rules: [AdjacencyRule], me: String, localScreens: [ScreenInfo], peer: String,
                         peerScreens: [ScreenInfo], info: (String, String) -> ScreenInfo?) -> [ScreenSpot] {
        var spots: [ScreenSpot] = []
        var rects: [CGRect] = []
        func rect(_ d: String, _ s: String) -> CGRect? {
            guard let i = spots.firstIndex(where: { $0.device == d && $0.screen == s }) else { return nil }
            return rects[i]
        }
        func add(_ d: String, _ s: ScreenInfo, _ o: CGPoint) {
            spots.append(ScreenSpot(device: d, screen: s.id, x: o.x, y: o.y))
            rects.append(CGRect(x: o.x, y: o.y, width: s.mmW, height: s.mmH))
        }
        let local = arranged(localScreens)
        for s in localScreens { if let o = local[s.id] { add(me, s, o) } }
        var progressed = true
        while progressed {
            progressed = false
            for r in rules {
                let aRect = rect(r.aDevice, r.aScreen), bRect = rect(r.bDevice, r.bScreen)
                if let ar = aRect, bRect == nil, let b = info(r.bDevice, r.bScreen) {
                    add(r.bDevice, b, origin(CGSize(width: b.mmW, height: b.mmH), against: ar, edge: r.aEdge, offset: r.offsetMM))
                } else if let br = bRect, aRect == nil, let a = info(r.aDevice, r.aScreen) {
                    add(r.aDevice, a, origin(CGSize(width: a.mmW, height: a.mmH), against: br, edge: r.bEdge, offset: -r.offsetMM))
                } else {
                    continue
                }
                progressed = true
                break
            }
        }
        for s in peerScreens where rect(peer, s.id) == nil {
            add(peer, s, originRight(of: rects))
        }
        return spots
    }
}

// 只在构建验证时用的命令行自测入口（不打进 MacKVM.app）。由 Verify/verify.sh 编译运行。
//   unit                         纯逻辑断言：屏幕布局 → 相邻规则、跨屏判定、配对密码学、共享设置视角换算、波纹参数夹取
//   loopback                     单进程内走一遍：配对（含输错 5 次换码）→ 两个 Link 用配对出的密钥连上、收发、断线重连
//   bonjour                      用测试专用的服务类型试 Bonjour 广播与发现（需要本地网络权限，可能被拒）
//   proc-inviter <输出文件>       两进程测试的被控方：开配对监听，把端口和配对码写进文件，配对后用 Link 回显
//   proc-seeker <端口> <配对码>   两进程测试的主控方：先输错一次，再输对；配对后用 Link 发消息、等回显、发解除配对
// 用到的端口都避开 24810（正在运行的 MacKVM 在用）。

import AppKit
import CryptoKit
import Foundation
import Network

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    checks += 1
    if ok {
        print("  通过  \(what)")
    } else {
        failures += 1
        print("  失败  \(what)（第 \(line) 行）")
    }
}
func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.01) -> Bool { abs(a - b) <= eps }
func near(_ p: CGPoint?, _ q: CGPoint) -> Bool { guard let p else { return false }; return near(p.x, q.x) && near(p.y, q.y) }

/// 跑主队列直到条件成立或超时
func spin(_ timeout: Double, until cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return cond()
}

// MARK: - unit

func unitTests() {
    // 用户的真实屏幕：Mac Studio = U2720QM（主屏）+ P2319H（右边、顶部对齐）；MacBook = 内建屏
    let studio = "dev-studio", book = "dev-book"
    let U = ScreenInfo(id: "U2720QM", name: "DELL U2720QM", isMain: true, isBuiltin: false,
                       x: 0, y: 0, w: 2560, h: 1440, mmW: 599, mmH: 340, estimated: false)
    let P = ScreenInfo(id: "P2319H", name: "DELL P2319H", isMain: false, isBuiltin: false,
                       x: 2560, y: 0, w: 1920, h: 1080, mmW: 507, mmH: 288, estimated: false)
    let B = ScreenInfo(id: "BUILTIN", name: "内建屏幕", isMain: true, isBuiltin: true,
                       x: 0, y: 0, w: 1512, h: 982, mmW: 301, mmH: 195, estimated: false)
    let all: [String: ScreenInfo] = [U.id: U, P.id: P, B.id: B]
    func approx(_ a: Double, _ b: Double, _ eps: Double = 0.01) -> Bool { abs(a - b) <= eps }

    print("== 毫米 ↔ 点")
    check(approx(P.ptToMM(540, .right), 144), "P2319H 右边 y=540 点 → 144 毫米（288 毫米的一半）")
    check(approx(P.mmToPt(144, .right), 540), "144 毫米 → 540 点")
    check(approx(U.ptToMM(2400 - 0, .down), 2400.0 / 2560 * 599), "U2720QM 下边 x=2400 点 → 561.6 毫米")
    check(approx(P.mmToPt(88.9, .down), 2560 + 88.9 / 507 * 1920), "P2319H 下边从它自己的左端（x=2560）起算")
    check(U.inches == 27 && P.inches == 23 && B.inches == 14, "对角线英寸：27 / 23 / 14")

    print("== 默认布局")
    func info(_ d: String, _ id: String) -> ScreenInfo? { all[id] }
    func placedOf(_ spots: [ScreenSpot]) -> [PlacedScreen] { ScreenLayout.placed(spots: spots, present: [], info: info) }
    func spot(_ l: [ScreenSpot], _ d: String, _ id: String) -> ScreenSpot? { l.first { $0.device == d && $0.screen == id } }
    let defLayout = ScreenLayout.defaultLayout(controller: studio, controllerScreens: [U, P], controlled: book, controlledScreens: [B])
    check(spot(defLayout, studio, "U2720QM").map { $0.x == 0 && $0.y == 0 } == true
          && spot(defLayout, studio, "P2319H").map { approx($0.x, 599) && $0.y == 0 } == true,
          "主控的屏按 macOS 排列换算成毫米：U2720QM 在 (0, 0)，P2319H 贴着它的右边、顶部对齐")
    check(spot(defLayout, book, "BUILTIN").map { approx($0.x, 599 + 507) && approx($0.y, (288 - 195) / 2) } == true,
          "被控的内建屏贴着 P2319H 的右边、中点对齐")
    let defRules = ScreenLayout.rules(from: placedOf(defLayout), me: studio, peer: book, existing: [], newID: { "r-def" })
    check(defRules.count == 1, "默认布局推导出 1 条规则（自家两块 DELL 挨着不算）")
    let def = defRules[0]
    check(def.aScreen == "P2319H" && def.aEdge == .right && def.bScreen == "BUILTIN" && def.bEdge == .left,
          "主控最右侧屏 P2319H 的右边 ↔ 被控最左侧屏（内建屏）的左边")
    check(approx(def.offsetMM, (288 - 195) / 2), "中点对齐：错开 46.5 毫米")
    let defFromBook = ScreenLayout.rules(from: placedOf(defLayout), me: book, peer: studio, existing: [], newID: { "r-def" })
    check(defFromBook.count == 1 && defFromBook[0].view(from: studio) == def.view(from: studio)
          && defFromBook[0].view(from: book) == def.view(from: book),
          "两台各自从同一份布局推导：换算成任一台的视角都一样")
    // 并列：两块屏右边缘一样靠右（上下叠放）→ 取主屏；主屏不在其中 → 取最上面
    let S1 = ScreenInfo(id: "S1", name: "上", isMain: false, isBuiltin: false, x: 0, y: -1080, w: 1920, h: 1080, mmW: 500, mmH: 280, estimated: false)
    let S2 = ScreenInfo(id: "S2", name: "下", isMain: true, isBuiltin: false, x: 0, y: 0, w: 1920, h: 1080, mmW: 500, mmH: 280, estimated: false)
    check(ScreenLayout.outermost([S1, S2], .right)?.id == "S2", "右边缘并列时取主屏")
    var S2b = S2; S2b.isMain = false
    let S3 = ScreenInfo(id: "S3", name: "左", isMain: true, isBuiltin: false, x: -1920, y: 0, w: 1920, h: 1080, mmW: 500, mmH: 280, estimated: false)
    check(ScreenLayout.outermost([S1, S2b, S3], .right)?.id == "S1", "右边缘并列、主屏不在其中 → 取最上面那块")
    check(ScreenLayout.outermost([S1, S2b, S3], .left)?.id == "S3", "最左侧屏")
    let stack = ScreenLayout.arranged([S1, S2])
    check(stack["S2"] == .zero && stack["S1"].map { $0.x == 0 && approx($0.y, -280) } == true, "上下叠放的两块屏：上面那块贴着主屏的上边")
    // 点密度不同：第三块屏在点坐标里贴着第二块的右边，换成毫米也贴着第二块（不会和它叠在一起）
    let Q = ScreenInfo(id: "Q", name: "第三块", isMain: false, isBuiltin: false, x: 4480, y: 0, w: 1920, h: 1080,
                       mmW: 527, mmH: 296, estimated: false)
    let three = ScreenLayout.arranged([U, P, Q])
    check(three["Q"].map { approx($0.x, 599 + 507) && $0.y == 0 } == true, "三块一排：第三块贴着 P2319H 的右边（按毫米接上，不按点）")

    print("== 规则视角换算")
    let vS = def.view(from: studio)!, vB = def.view(from: book)!
    check(vS.localScreen == "P2319H" && vS.localEdge == .right && vS.remoteScreen == "BUILTIN" && approx(vS.offsetMM, 46.5),
          "主控视角：本机 P2319H 右边，对方错开 +46.5")
    check(vB.localScreen == "BUILTIN" && vB.localEdge == .left && vB.remoteScreen == "P2319H" && approx(vB.offsetMM, -46.5),
          "被控视角：本机内建屏左边，对方错开 -46.5（两台存同一份，不会存反）")
    check(def.updated(with: vB, me: book) == def && def.updated(with: vS, me: studio) == def, "按任一台视角写回，规则不变")
    let tS = vS.touch(P, B), tB = vB.touch(B, P)
    check(approx(tS.lo, 46.5) && approx(tS.hi, 241.5) && approx(tB.lo, 0) && approx(tB.hi, 195), "两边算出的挨着段长度一致（195 毫米）")

    print("== 跨屏判定（默认规则）")
    let mapS = CrossingMap(views: [vS], localScreens: [U, P], remoteScreens: [B])
    let h1 = mapS.hit(from: CGPoint(x: 4479, y: 540), to: CGPoint(x: 4480, y: 540))
    check(h1 != nil && approx(h1!.localMM, 144) && approx(h1!.remoteMM, 97.5) && h1!.remoteEdge == .left,
          "P2319H 右边中点推出 → 内建屏左边 97.5 毫米（中点）")
    let land = CrossingMap.landing(on: B, edge: .left, mm: h1!.remoteMM)
    check(land.x == 1 && approx(land.y, 491), "落点在内建屏左边内 1 点、y = 491（\(land)）")
    check(mapS.hit(from: CGPoint(x: 4479, y: 100), to: CGPoint(x: 4480, y: 100)) == nil, "P2319H 右边上段（46.5 毫米以内，没挨着）推出：不跨")
    check(mapS.hit(from: CGPoint(x: 4400, y: 540), to: CGPoint(x: 4470, y: 540)) == nil, "没到边：不跨")
    check(mapS.hit(from: CGPoint(x: 2559, y: 540), to: CGPoint(x: 2560, y: 540)) == nil, "U2720QM 右边（通往自家 P2319H、没有规则）：不跨")
    // 反向：内建屏左边推回
    let mapB = CrossingMap(views: [vB], localScreens: [B], remoteScreens: [U, P])
    let h2 = mapB.hit(from: CGPoint(x: 0, y: 491), to: CGPoint(x: -1, y: 491))
    check(h2 != nil && h2!.remoteScreen == "P2319H" && h2!.remoteEdge == .right && approx(h2!.remoteMM, 144, 0.1),
          "内建屏左边 y=491 推回 → P2319H 右边约 144 毫米")
    let back2 = CrossingMap.landing(on: P, edge: .right, mm: h2!.remoteMM)
    check(back2.x == 4478 && abs(back2.y - 540) < 1, "回到 P2319H 右边内 2 点、y≈540（\(back2)），往返对得上")
    check(!crossingEligible(.leftMouseDragged) && !crossingEligible(.rightMouseDragged) && crossingEligible(.mouseMoved),
          "按住鼠标键（拖动）时规则不触发，只有普通移动才判定")

    print("== 快速甩过短段")
    // 12 毫米的短段：B 只露出 12 毫米挨着 P2319H 右边的最下端
    let shortRule = AdjacencyRule(id: "r-short", aDevice: studio, aScreen: "P2319H", aEdge: .right, bDevice: book,
                                  bScreen: "BUILTIN", offsetMM: 288 - 12)
    let mapShort = CrossingMap(views: [shortRule.view(from: studio)!], localScreens: [U, P], remoteScreens: [B])
    let segLo = P.mmToPt(276, .right)   // 1035 点
    check(mapShort.hit(from: CGPoint(x: 4200, y: 1060), to: CGPoint(x: 4520, y: 1050)) != nil,
          "一下甩 320 点，连线在 y≈1051 穿过 12 毫米短段（\(Int(segLo))~1080 点）：跨")
    check(mapShort.hit(from: CGPoint(x: 4200, y: 900), to: CGPoint(x: 4520, y: 960)) == nil, "连线穿过边时在短段之外：不跨")
    check(mapShort.hit(from: CGPoint(x: 4479, y: 1079), to: CGPoint(x: 4479, y: 1180)) == nil, "沿边往下推（没往右）：不跨")

    print("== U2720QM 右边下段 ↔ MacBook 左边（规则盖住部分自家相通段）")
    let rU = AdjacencyRule(id: "r-u", aDevice: studio, aScreen: "U2720QM", aEdge: .right, bDevice: book,
                           bScreen: "BUILTIN", offsetMM: 200)   // B 占 U 右边 200~395 毫米，实际挨着 200~340
    let vU = rU.view(from: studio)!
    let tU = vU.touch(U, B)
    check(approx(tU.lo, 200) && approx(tU.hi, 340), "挨着的一段：U2720QM 右边 200~340 毫米")
    let mapU = CrossingMap(views: [vU], localScreens: [U, P], remoteScreens: [B])
    let yShared = U.mmToPt(236, .right)   // 1000 点：在自家相通段里，也在规则段里
    let hs = mapU.hit(from: CGPoint(x: 2559, y: yShared), to: CGPoint(x: 2561, y: yShared))
    check(hs != nil && approx(hs!.localMM, 236, 0.1), "y=1000（自家相通段内、规则段内）往右推：规则优先，跨到 MacBook")
    check(hs.map { approx($0.remoteMM, 36, 0.1) } == true, "落在内建屏左边 36 毫米处")
    check(mapU.hit(from: CGPoint(x: 2559, y: 1300), to: CGPoint(x: 2560, y: 1300)) != nil, "y=1300（U 独有的下段）：跨")
    check(mapU.hit(from: CGPoint(x: 2559, y: 500), to: CGPoint(x: 2561, y: 500)) == nil, "y=500（规则段之外）：照常进自家 P2319H")
    // 被控方：规则盖住自家相通段时一穿过就离开，外侧边要累计外推 15 像素
    var db = LeaveDebounce()
    let fakeHit = CrossingHit(ruleID: "r", localScreen: "BUILTIN", localEdge: .left, crossPoint: CGPoint(x: 0, y: 400),
                              localMM: 80, remoteScreen: "P2319H", remoteEdge: .right, remoteMM: 100)
    check(!db.feed(hit: fakeHit, beyond: 5, intoOwnScreen: false, sinceEnter: 0.1, outwardOnPending: nil), "进入后 150 毫秒内：不离开")
    check(!db.feed(hit: fakeHit, beyond: 5, intoOwnScreen: false, sinceEnter: 0.3, outwardOnPending: nil), "外侧边外推 5：还不离开")
    check(!db.feed(hit: nil, beyond: 0, intoOwnScreen: false, sinceEnter: 0.35, outwardOnPending: 0), "沿边移动（外推 0）：保留累计")
    check(!db.feed(hit: fakeHit, beyond: 6, intoOwnScreen: false, sinceEnter: 0.4, outwardOnPending: nil), "累计 11：还不离开")
    check(db.feed(hit: fakeHit, beyond: 4, intoOwnScreen: false, sinceEnter: 0.45, outwardOnPending: nil), "累计 15：离开")
    var db2 = LeaveDebounce()
    _ = db2.feed(hit: fakeHit, beyond: 10, intoOwnScreen: false, sinceEnter: 0.3, outwardOnPending: nil)
    _ = db2.feed(hit: nil, beyond: 0, intoOwnScreen: false, sinceEnter: 0.35, outwardOnPending: -3)
    check(!db2.feed(hit: fakeHit, beyond: 10, intoOwnScreen: false, sinceEnter: 0.4, outwardOnPending: nil), "往里退过一下：累计清零")
    var db3 = LeaveDebounce()
    check(db3.feed(hit: fakeHit, beyond: 1, intoOwnScreen: true, sinceEnter: 0.3, outwardOnPending: nil), "规则盖住自家相通段：一穿过就离开")

    print("== 两块 DELL 下边 ↔ MacBook 上边左右两段")
    let r1 = AdjacencyRule(id: "r1", aDevice: studio, aScreen: "U2720QM", aEdge: .down, bDevice: book,
                           bScreen: "BUILTIN", offsetMM: 599 - 150)          // B 上边 0~150 毫米挨着 U 下边 449~599
    let r2 = AdjacencyRule(id: "r2", aDevice: studio, aScreen: "P2319H", aEdge: .down, bDevice: book,
                           bScreen: "BUILTIN", offsetMM: -150)               // B 上边 150~301 毫米挨着 P 下边 0~151
    let mapD = CrossingMap(views: [r1.view(from: studio)!, r2.view(from: studio)!], localScreens: [U, P], remoteScreens: [B])
    let hd = mapD.hit(from: CGPoint(x: 2400, y: 1439), to: CGPoint(x: 2400, y: 1440))
    check(hd?.ruleID == "r1" && hd.map { approx($0.remoteMM, 2400.0 / 2560 * 599 - 449, 0.01) } == true,
          "U2720QM 下边 x=2400 推下 → 内建屏上边约 112.6 毫米")
    let hd2 = mapD.hit(from: CGPoint(x: 2700, y: 1079), to: CGPoint(x: 2700, y: 1080))
    check(hd2?.ruleID == "r2" && hd2?.remoteEdge == .up, "P2319H 下边 x=2700 推下 → 走 r2 到内建屏上边")
    let mapBD = CrossingMap(views: [r1.view(from: book)!, r2.view(from: book)!], localScreens: [B], remoteScreens: [U, P])
    let hu = mapBD.hit(from: CGPoint(x: 1200, y: 0), to: CGPoint(x: 1200, y: -1))
    let bmm = 1200.0 / 1512 * 301
    check(hu?.ruleID == "r2" && hu?.remoteScreen == "P2319H" && hu.map { approx($0.remoteMM, bmm - 150, 0.01) } == true,
          "内建屏上边 x=1200（右段）推上 → P2319H 下边 \(fmt(bmm - 150)) 毫米")
    let pland = CrossingMap.landing(on: P, edge: .down, mm: hu!.remoteMM)
    check(approx(pland.x, 2560 + (bmm - 150) / 507 * 1920, 0.01) && pland.y == 1078, "落点按 P2319H 自己的点坐标算（\(pland)）")

    print("== 可用区域（扣掉程序坞条）定触发线")
    var Pd = P; Pd.ux = 2560; Pd.uy = 0; Pd.uw = 1920; Pd.uh = 1080 - 97     // 程序坞在 P2319H 底部，占 97 点
    let mapDock = CrossingMap(views: [r1.view(from: studio)!, r2.view(from: studio)!], localScreens: [U, Pd], remoteScreens: [B])
    let hk = mapDock.hit(from: CGPoint(x: 2700, y: 1078), to: CGPoint(x: 2700, y: 1079))
    check(hk?.ruleID == "r2" && hk?.crossPoint.y == 982
          && mapDock.hit(from: CGPoint(x: 2700, y: 980), to: CGPoint(x: 2700, y: 985)) == nil,
          "程序坞在 P2319H 下边：触发线仍是屏幕底边 y=1079（推过程序坞才切），跨出点放在程序坞上沿 y=982")
    check(mapD.hit(from: CGPoint(x: 2700, y: 1079), to: CGPoint(x: 2700, y: 1079))?.ruleID == "r2"
          && mapD.hit(from: CGPoint(x: 2700, y: 1070), to: CGPoint(x: 2700, y: 1070)) == nil
          && mapD.hit(from: CGPoint(x: 2700, y: 1079), to: CGPoint(x: 2701, y: 1079)) == nil,
          "慢推：停在 P2319H 最后一行（y=1079）上零位移的事件算往外推；离边 10 点的零位移、沿边横移不算")
    check(mapD.hit(from: CGPoint(x: 2700, y: 1078.4), to: CGPoint(x: 2700, y: 1079.4))?.ruleID == "r2"
          && mapD.hit(from: CGPoint(x: 2700, y: 1077), to: CGPoint(x: 2700, y: 1078)) == nil
          && mapS.hit(from: CGPoint(x: 4478, y: 540), to: CGPoint(x: 4479, y: 540)) != nil
          && mapBD.hit(from: CGPoint(x: 1200, y: 1), to: CGPoint(x: 1200, y: 0)) != nil,
          "触发线是最靠边那一行像素：一碰到就切（下 1079、右 4479、上 0），没碰到不切")
    var Bl = B; Bl.ux = 80; Bl.uy = 0; Bl.uw = 1512 - 80; Bl.uh = 982            // 程序坞在内建屏左侧，占 80 点
    let mapLeftDock = CrossingMap(views: [vB], localScreens: [Bl], remoteScreens: [U, P])
    let hl = mapLeftDock.hit(from: CGPoint(x: 1, y: 491), to: CGPoint(x: 0, y: 491))
    check(hl != nil && hl?.crossPoint.x == 80
          && mapLeftDock.hit(from: CGPoint(x: 82, y: 491), to: CGPoint(x: 79, y: 491)) == nil,
          "程序坞在内建屏左侧：触发线仍是屏幕左边 x=0（推过程序坞才切），跨出点放在程序坞右沿 x=80")
    let hu2 = mapBD.hit(from: CGPoint(x: 300, y: 0), to: CGPoint(x: 300, y: -1))
    check(hu2?.ruleID == "r1" && hu2?.remoteScreen == "U2720QM", "内建屏上边 x=300（左段）推上 → U2720QM")

    print("== 显示器拔出")
    var gone = def; gone.bScreen = "UNPLUGGED"
    let mapGone = CrossingMap(views: [gone.view(from: studio)!], localScreens: [U, P], remoteScreens: [B])
    check(mapGone.activeViews.isEmpty && mapGone.hit(from: CGPoint(x: 4479, y: 540), to: CGPoint(x: 4480, y: 540)) == nil,
          "显示器拔出：规则暂时失效、不跨（规则本身保留）")

    print("== 布局 → 规则 → 挨着的段落，和几何一致")
    // 本机 U2720QM 在 (0, 0)、P2319H 在 (599, 0)；内建屏摆在它们四周各处（含一部分悬空），推导出的规则算出的挨着段落，
    // 要等于两块屏在布局里实际重合的那一段；跨屏判定从这一段中点推出去，落点也要正好是布局里同一个位置
    let localAt: [String: CGPoint] = ["U2720QM": .zero, "P2319H": CGPoint(x: 599, y: 0)]
    func layoutWith(_ b: CGPoint, _ extra: [ScreenSpot] = []) -> [ScreenSpot] {
        [ScreenSpot(device: studio, screen: "U2720QM", x: 0, y: 0), ScreenSpot(device: studio, screen: "P2319H", x: 599, y: 0),
         ScreenSpot(device: book, screen: "BUILTIN", x: b.x, y: b.y)] + extra
    }
    func pushOut(_ s: ScreenInfo, _ e: Direction, _ along: Double) -> (CGPoint, CGPoint) {
        switch e {
        case .right: return (CGPoint(x: s.x + s.w - 3, y: along), CGPoint(x: s.x + s.w + 1, y: along))
        case .left: return (CGPoint(x: s.x + 2, y: along), CGPoint(x: s.x - 2, y: along))
        case .down: return (CGPoint(x: along, y: s.y + s.h - 3), CGPoint(x: along, y: s.y + s.h + 1))
        case .up: return (CGPoint(x: along, y: s.y + 2), CGPoint(x: along, y: s.y - 2))
        }
    }
    let geoCases: [(String, CGPoint, String, Direction, Double, Double)] = [
        // 说明、内建屏左上角、应挨着的本机屏、本机屏的边、重合段在布局里的起止（沿边方向的绝对坐标）
        ("P2319H 右边、中点对齐", CGPoint(x: 1106, y: 46.5), "P2319H", .right, 46.5, 241.5),
        ("P2319H 右边、上半截悬空", CGPoint(x: 1106, y: -100), "P2319H", .right, 0, 95),
        ("P2319H 右边、下半截悬空", CGPoint(x: 1106, y: 200), "P2319H", .right, 200, 288),
        ("P2319H 下边", CGPoint(x: 700, y: 288), "P2319H", .down, 700, 1001),
        ("U2720QM 下边、右端伸到 P2319H 下方之外", CGPoint(x: 300, y: 340), "U2720QM", .down, 300, 599),
        ("P2319H 上边", CGPoint(x: 800, y: -195), "P2319H", .up, 800, 1101),
        ("U2720QM 左边", CGPoint(x: -301, y: 100), "U2720QM", .left, 100, 295),
        ("U2720QM 上边、左半截悬空", CGPoint(x: -100, y: -195), "U2720QM", .up, 0, 201),
    ]
    for (what, bAt, lid, edge, lo, hi) in geoCases {
        let rs = ScreenLayout.rules(from: placedOf(layoutWith(bAt)), me: studio, peer: book, existing: [], newID: { "r-geo" })
        guard rs.count == 1, let v = rs[0].view(from: studio), let vb = rs[0].view(from: book), let l = all[lid] else {
            check(false, "\(what)：应该正好推导出 1 条规则（实际 \(rs.count) 条）")
            continue
        }
        let ls = localAt[lid]!
        let lStart = edge.isVertical ? ls.x : ls.y, bStart = edge.isVertical ? bAt.x : bAt.y
        let t = v.touch(l, B), tb = vb.touch(B, l)
        check(v.localScreen == lid && v.localEdge == edge && approx(t.lo, lo - lStart) && approx(t.hi, hi - lStart)
              && vb.localEdge == edge.opposite && approx(tb.lo, lo - bStart) && approx(tb.hi, hi - bStart),
              "\(what)：本机边上 \(fmt(t.lo))~\(fmt(t.hi)) 毫米、内建屏边上 \(fmt(tb.lo))~\(fmt(tb.hi)) 毫米，和布局里的重合段一致")
        let mid = (lo + hi) / 2
        let (p0, p1) = pushOut(l, edge, l.mmToPt(mid - lStart, edge))
        let h = CrossingMap(views: [v], localScreens: [U, P], remoteScreens: [B]).hit(from: p0, to: p1)
        check(h.map { approx($0.remoteMM, mid - bStart, 0.05) && $0.remoteEdge == edge.opposite } == true,
              "\(what)：从重合段中点推出，落在内建屏边上 \(fmt(mid - bStart)) 毫米（布局里同一个位置）")
    }

    print("== 布局 → 规则：挨上才有、拖开即删、ID 沿用")
    func derive(_ spots: [ScreenSpot], existing: [AdjacencyRule] = []) -> [AdjacencyRule] {
        var n = 0
        return ScreenLayout.rules(from: placedOf(spots), me: studio, peer: book, existing: existing, newID: { n += 1; return "r-new-\(n)" })
    }
    check(derive(layoutWith(CGPoint(x: 1106 + 50, y: 46.5))).isEmpty, "内建屏拖开 50 毫米：没有规则（光标跨不过去）")
    check(derive(layoutWith(CGPoint(x: 1106, y: 288 - 8))).isEmpty, "只挨着 8 毫米：不到 10 毫米，不算")
    check(derive(layoutWith(CGPoint(x: 1106, y: 288 - 10))).count == 1, "挨着正好 10 毫米：算")
    check(derive(layoutWith(CGPoint(x: 1106 + 0.3, y: 46.5))).count == 1, "差 0.3 毫米（小数误差）：算挨着")
    check(derive(layoutWith(CGPoint(x: 1106, y: 288))).isEmpty, "只碰到一个角：不算")
    let kept = derive(layoutWith(CGPoint(x: 1106, y: 0)), existing: [def])
    check(kept.count == 1 && kept[0].id == "r-def" && approx(kept[0].offsetMM, 0), "同一对屏已有规则：沿用它的 ID，错开改成 0")
    var flipped = AdjacencyRule(id: "r-flip", aDevice: book, aScreen: "BUILTIN", aEdge: .left, bDevice: studio, bScreen: "P2319H", offsetMM: -46.5)
    let keptFlip = derive(layoutWith(CGPoint(x: 700, y: 288)), existing: [flipped])
    flipped.aEdge = .up; flipped.offsetMM = -101
    check(keptFlip == [flipped], "已有规则的甲方是对方：沿用 ID 和甲乙方向，只改边和错开（对方视角：内建屏上边，错开 -101）")
    let B2 = ScreenInfo(id: "B2", name: "外接屏", isMain: false, isBuiltin: false, x: 1512, y: 0, w: 1920, h: 1080,
                        mmW: 527, mmH: 296, estimated: false)
    var all2 = all; all2[B2.id] = B2
    let two = ScreenLayout.rules(from: ScreenLayout.placed(spots: layoutWith(CGPoint(x: 1106, y: 46.5),
                                                                              [ScreenSpot(device: book, screen: "B2", x: 300, y: 340)]),
                                                           present: [], info: { all2[$1] }),
                                 me: studio, peer: book, existing: [def], newID: { "r-b2" })
    check(two.count == 2 && two.contains { $0.id == "r-def" && $0.bScreen == "BUILTIN" }
          && two.contains { $0.id == "r-b2" && $0.aScreen == "U2720QM" && $0.aEdge == .down && approx($0.offsetMM, 300) },
          "对方两块屏各挨一块本机屏：两条规则，旧的一对沿用 ID，新挨上的一对用新 ID")
    let ghost = AdjacencyRule(id: "r-ghost", aDevice: studio, aScreen: "OLD", aEdge: .left, bDevice: book, bScreen: "BUILTIN", offsetMM: 0)
    check(derive(layoutWith(CGPoint(x: 1106, y: 46.5)), existing: [def, ghost]).contains(ghost),
          "规则里有布局里没有（不知道尺寸）的屏：原样保留")
    let missing = ScreenLayout.placed(spots: layoutWith(CGPoint(x: 1106, y: 46.5)), present: [(device: studio, info: U), (device: book, info: B2)],
                                      info: { all2[$1] })
    check(missing.first { $0.info.id == "P2319H" }?.present == false && missing.first { $0.info.id == "U2720QM" }?.present == true,
          "布局里有、现在没接着的屏：留在原处，标成没接上")
    check(missing.first { $0.info.id == "B2" }.map { approx($0.x, 1106 + 301 + kNewScreenGapMM) && approx($0.y, 46.5) } == true,
          "现在接着、布局里还没有的屏：放到最右边，隔开 \(Int(kNewScreenGapMM)) 毫米（不凭空多出能跨的边）")

    print("== 拖动：吸附、不能叠放")
    let others = [CGRect(x: 0, y: 0, width: 599, height: 340), CGRect(x: 599, y: 0, width: 507, height: 288)]
    func bRect(_ x: Double, _ y: Double) -> CGRect { CGRect(x: x, y: y, width: 301, height: 195) }
    check(ScreenLayout.snapped(bRect(1106 + 12, 50), among: others) == CGPoint(x: 1106, y: 46.5),
          "拖到 P2319H 右边 12 毫米处：贴上右边，沿边吸到中点对齐")
    check(ScreenLayout.snapped(bRect(1106 + 30, 50), among: others) == CGPoint(x: 1136, y: 50), "离边 30 毫米：不吸附")
    check(ScreenLayout.snapped(bRect(700, 300), among: others) == CGPoint(x: 702, y: 288), "拖到 P2319H 下方：贴上下边，左右吸到中对中")
    check(ScreenLayout.snapped(bRect(1106 + 5, -8), among: others) == CGPoint(x: 1106, y: 0), "靠近右上角：贴上右边、顶部对齐")
    check(!ScreenLayout.overlaps(others[0], others[1]) && ScreenLayout.overlaps(bRect(1000, 100), others[1]),
          "两块屏边挨着不算叠放；伸进别的屏里算叠放（不能放下，弹回原处）")

    print("== 旧数据迁移：只有规则、没有布局")
    let mig1 = ScreenLayout.migrated(rules: [def], me: studio, localScreens: [U, P], peer: book, peerScreens: [B], info: info)
    check(mig1 == defLayout, "只有默认规则：摆出来和默认布局一样")
    check(ScreenLayout.rules(from: placedOf(mig1), me: studio, peer: book, existing: [def], newID: { "x" }) == [def],
          "从迁移出的布局重新推导：还是原来那条规则（ID 不变）")
    let rDown = AdjacencyRule(id: "r-down", aDevice: studio, aScreen: "U2720QM", aEdge: .down, bDevice: book, bScreen: "BUILTIN", offsetMM: 100)
    let mig2 = ScreenLayout.migrated(rules: [def, rDown], me: studio, localScreens: [U, P], peer: book, peerScreens: [B, B2], info: { all2[$1] })
    let mig2Rules = ScreenLayout.rules(from: ScreenLayout.placed(spots: mig2, present: [], info: { all2[$1] }),
                                       me: studio, peer: book, existing: [def, rDown], newID: { "x" })
    check(spot(mig2, book, "BUILTIN").map { approx($0.x, 1106) && approx($0.y, 46.5) } == true && mig2Rules == [def],
          "两条规则都提到内建屏：按第一条摆；第二条（U2720QM 下边）几何上挨不上，就此去掉")
    check(spot(mig2, book, "B2").map { approx($0.x, 1106 + 301 + kNewScreenGapMM) } == true, "规则没提到的对方屏：放到最右边，隔开放")
    let migU = ScreenLayout.migrated(rules: [rU], me: studio, localScreens: [U, P], peer: book, peerScreens: [B], info: info)
    let migURules = ScreenLayout.rules(from: placedOf(migU), me: studio, peer: book, existing: [rU], newID: { "x" })
    check(migURules == [rU], "规则把内建屏摆到 U2720QM 右边下段（换成毫米会和 P2319H 叠上）：照规则摆，规则保留，由用户拖开")
    let migGone = ScreenLayout.migrated(rules: [def], me: book, localScreens: [B], peer: studio, peerScreens: [U],
                                        info: info)
    check(spot(migGone, studio, "P2319H").map { approx($0.x, -507) && approx($0.y, -46.5) } == true
          && spot(migGone, studio, "U2720QM").map { approx($0.x, 301 + kNewScreenGapMM) && $0.y == 0 } == true,
          "从被控一侧迁移、对方 P2319H 拔掉了：拔掉的屏也按规则摆（贴着内建屏左边）；规则没提到的 U2720QM 放到最右边")

    print("== 显示器位置后缀")
    check(ScreenNaming.labels([U, P], .zh) == ["U2720QM": "DELL U2720QM（左）", "P2319H": "DELL P2319H（右）"],
          "两块 DELL 左右并排（顶部对齐、高度不同）：左 / 右")
    check(ScreenNaming.labels([B], .zh) == ["BUILTIN": "内建屏幕"], "只有一块屏：不加后缀")
    check(ScreenNaming.suffixes([S1, S2], .zh) == ["S1": "上", "S2": "下"], "上下叠放：上 / 下")
    let T3 = ScreenInfo(id: "T3", name: "右", isMain: false, isBuiltin: false, x: 1920, y: 0, w: 1920, h: 1080, mmW: 500, mmH: 280, estimated: false)
    check(ScreenNaming.suffixes([S3, S2, T3], .zh) == ["S3": "左", "S2": "中", "T3": "右"], "三块一排：左 / 中 / 右")
    let D1 = ScreenInfo(id: "D1", name: "a", isMain: true, isBuiltin: false, x: 0, y: 0, w: 1000, h: 800, mmW: 300, mmH: 200, estimated: false)
    let D2 = ScreenInfo(id: "D2", name: "b", isMain: false, isBuiltin: false, x: 1000, y: 800, w: 1000, h: 800, mmW: 300, mmH: 200, estimated: false)
    check(ScreenNaming.suffixes([D1, D2], .zh) == ["D1": "左上", "D2": "右下"], "斜着摆：左上 / 右下")

    print("== 显示器位置后缀（英文）")
    check(ScreenNaming.labels([U, P], .en) == ["U2720QM": "DELL U2720QM (Left)", "P2319H": "DELL P2319H (Right)"],
          "英文：「DELL U2720QM (Left)」「DELL P2319H (Right)」，半角括号、前面空一格")
    check(ScreenNaming.labels([B], .en) == ["BUILTIN": "Built-in display"], "英文：内建屏叫 Built-in display，只有一块屏不加后缀")
    check(ScreenNaming.suffixes([S1, S2], .en) == ["S1": "Top", "S2": "Bottom"], "英文：上下叠放 Top / Bottom")
    check(ScreenNaming.suffixes([S3, S2, T3], .en) == ["S3": "Left", "S2": "Center", "T3": "Right"], "英文：三块一排 Left / Center / Right")
    check(ScreenNaming.suffixes([D1, D2], .en) == ["D1": "Top Left", "D2": "Bottom Right"], "英文：斜着摆 Top Left / Bottom Right（纵向在前）")
    check(ScreenNaming.labels([D1, D2], .en)["D1"] == "a (Top Left)", "英文：组合后缀放进半角括号")
    check(L.positionSuffix(ScreenPosition(column: .middle, row: .middle), .en) == "Center"
          && L.positionSuffix(ScreenPosition(column: .first, row: .middle), .en) == "Middle Left"
          && L.positionSuffix(ScreenPosition(column: .middle, row: .middle), .zh) == "中中",
          "英文：两个方向都在中间只写 Center；纵向在中间叫 Middle")
    check(L.screenName(B, .zh) == "内建屏幕" && L.screenName(U, .en) == "DELL U2720QM",
          "显示器名字用系统给的、不翻译；只有本程序起的「内建屏幕」翻译")

    print("== 界面语言：默认跟系统、记住的优先")
    check(Language.systemDefault(["zh-Hans-CN", "en-US"]) == .zh, "系统首选 zh-Hans-CN → 中文")
    check(Language.systemDefault(["en-US", "zh-Hans-CN"]) == .en, "系统首选 en-US（中文排第二）→ 英文")
    check(Language.systemDefault(["zh-Hant-TW"]) == .zh && Language.systemDefault(["zh"]) == .zh, "zh-Hant-TW、zh 也算中文")
    check(Language.systemDefault(["ja-JP"]) == .en && Language.systemDefault([]) == .en, "其他语言、读不到首选语言 → 英文")
    check(Language.resolve(saved: .en, preferred: ["zh-Hans-CN"]) == .en
          && Language.resolve(saved: .zh, preferred: ["en-US"]) == .zh, "记住的语言优先于系统")
    check(Language.resolve(saved: nil, preferred: ["zh-Hans-CN"]) == .zh
          && Language.resolve(saved: nil, preferred: ["en-US"]) == .en, "没记住过就跟系统")
    let langDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACKVM_HOME"] ?? NSTemporaryDirectory())
        .appendingPathComponent("lang-test")
    try? FileManager.default.removeItem(at: langDir)
    let langStore = Store(dir: langDir)
    var st = langStore.load()
    check(st.language == nil, "新状态文件里没有语言（= 跟系统）")
    // 记一个和本机系统默认相反的语言，看启动时是不是按记住的来
    let sys = Language.systemDefault()
    let other: Language = sys == .zh ? .en : .zh
    st.language = other
    langStore.save(st)
    check(langStore.load().language == other, "语言写进本机状态文件、读回来一样")
    let langModel = AppModel(store: langStore)
    check(LanguageSettings.shared.current == other, "启动时按记住的语言（\(other.rawValue)），不跟系统（\(sys.rawValue)）")
    langModel.setLanguage(sys)
    check(LanguageSettings.shared.current == sys && langStore.load().language == sys, "手动切换立即生效并记住")
    let oldStateJSON = #"{"deviceID":"x","ripple":{}}"#.data(using: .utf8)!
    check((try? JSONDecoder().decode(PersistedState.self, from: oldStateJSON)).map { $0.language == nil } == true,
          "旧版状态文件没有语言字段也能读（按跟系统处理）")
    let shared = SharedSettings(revision: 1, editor: "a", controllerID: "a", ripple: .defaults)
    let sharedJSON = String(data: try! JSONEncoder().encode(shared), encoding: .utf8)!
    check(!sharedJSON.contains("language"), "语言不进两台同步的共享设置")

    print("== 界面文案随语言切换")
    LanguageSettings.shared.current = .en
    check(L.tabConnection == "Devices" && L.tabRipple == "Cursor Effects", "英文：标题栏 Devices / Cursor Effects")
    check(L.menuStatus(.connected, peer: "My MacBook Pro") == "● Connected · My MacBook Pro", "英文：菜单状态行")
    check(L.screenSize(mmW: 599, mmH: 340, inches: 27, main: true, estimated: false) == "599 × 340 mm · 27-inch · Main",
          "英文：屏幕尺寸行「599 × 340 mm · 27-inch · Main」")
    check(L.screenRole(local: true, present: true, input: true) == "This Mac · Keyboard and mouse connected"
          && L.screenRole(local: false, present: true, input: false) == "Other Mac · Controlled", "英文：屏幕角色行")
    check(L.codeError(.wrongCode(left: 1)).contains("1 attempt left") && L.codeError(.wrongCode(left: 4)).contains("4 attempts left"),
          "英文：剩余次数单复数")
    check(L.codeError(.wrongCode(left: 4), .zh) == "配对码不正确，请重新输入（还可再试 4 次）", "日志用的中文错误提示不随界面语言变")
    check(L.networkProblem(describeNetworkError(NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))).hasPrefix("No Local Network access"),
          "英文：没有本地网络权限的提示换成英文")
    check(L.secondsValue("0.4") == "0.4 s" && L.rippleFootnote(min: "1", idle: "0.5", max: "5")
          == "Move left to right to preview. Entry ripples run for 1–5 s and stop after 0.5 s idle.", "英文：秒数和 07 页底部说明")
    LanguageSettings.shared.current = .zh
    check(L.tabConnection == "设备连接" && L.menuStatus(.searching, peer: "书房 Mac mini") == "● 正在寻找对方 · 书房 Mac mini",
          "切回中文立即生效")
    check(L.screenSize(mmW: 599, mmH: 340, inches: 27, main: true, estimated: true) == "599 × 340 mm · 27 英寸 · 主屏（尺寸为估算）",
          "中文：屏幕尺寸行")
    check(L.networkProblem("创建监听失败：x") == "创建监听失败：x", "中文界面：网络提示原样显示")

    print("== 共享设置：布局和规则同步、旧数据、默认布局只生成一次")
    let s = SharedSettings(revision: 3, editor: "a", controllerID: "a", rules: [def], rulesInitialized: true, ripple: .defaults)
    var s3 = s; s3.revision = 4
    check(s3.isNewer(than: s) && !s.isNewer(than: s3), "修订号大的更新")
    var s4 = s; s4.editor = "b"
    check(s4.isNewer(than: s) && !s.isNewer(than: s4), "修订号相同按编辑者 ID 定，两边结论一致")
    check(s.isValid(me: studio, peer: book) == false, "规则里的设备 ID 不是这两台：不合法")
    let sv = SharedSettings(revision: 3, editor: studio, controllerID: studio, rules: [def], rulesInitialized: true, ripple: .defaults)
    check(sv.isValid(me: studio, peer: book) && sv.isValid(me: book, peer: studio), "两台各自校验同一份设置：都合法")
    var bad = sv; bad.controllerID = "x"
    check(!bad.isValid(me: studio, peer: book), "出现陌生 ID 的设置不合法")
    let sBack = try! JSONDecoder().decode(SharedSettings.self, from: try! JSONEncoder().encode(sv))
    check(sBack == sv && sBack.rules.first?.view(from: book) == vB, "规则随共享设置编码再解码原样保留，对方解出来的视角正确")
    var sl = sv; sl.layout = defLayout
    let slBack = try! JSONDecoder().decode(SharedSettings.self, from: try! JSONEncoder().encode(sl))
    check(slBack == sl && slBack.layout == defLayout && sl.isValid(me: book, peer: studio), "布局随共享设置编码再解码原样保留")
    var badLayout = sl; badLayout.layout.append(ScreenSpot(device: "x", screen: "S", x: 0, y: 0))
    check(!badLayout.isValid(me: studio, peer: book), "布局里出现陌生设备 ID：不合法")
    var nanLayout = sl; nanLayout.layout[0].x = .nan
    check(!nanLayout.isValid(me: studio, peer: book), "布局里的坐标不是有限数：不合法")
    let noLayoutJSON = #"{"revision":20,"editor":"x","controllerID":"x","rules":[],"rulesInitialized":true,"ripple":{"enabled":true}}"#
    let noLayout = try! JSONDecoder().decode(SharedSettings.self, from: Data(noLayoutJSON.utf8))
    check(noLayout.layout.isEmpty && noLayout.needsLayoutMigration && !noLayout.needsDefaultLayout,
          "上一版数据（有规则、没有布局字段）：布局读成空，等按规则摆出布局")
    check(!sl.needsLayoutMigration, "有布局的数据不用迁移")
    let oldJSON = #"{"revision":15,"editor":"x","controllerID":"x","layoutAnchor":"x","layoutOtherIs":"right","ripple":{"enabled":true}}"#
    let oldS = try! JSONDecoder().decode(SharedSettings.self, from: Data(oldJSON.utf8))
    check(oldS.rules.isEmpty && oldS.layout.isEmpty && !oldS.rulesInitialized && oldS.needsDefaultLayout
          && !oldS.needsLayoutMigration && oldS.revision == 15,
          "更早的数据（只有已废弃的方向字段）：读成「还没有布局、需要生成默认布局」")
    var up = oldS
    up.layout = defLayout; up.rules = [def]; up.rulesInitialized = true
    check(!up.needsDefaultLayout && !up.needsLayoutMigration, "生成后标记已生成")
    up.rules.removeAll()
    check(!up.needsDefaultLayout, "之后屏全拖开、规则没了：不再补")

    print("== 波纹参数")
    var r = RippleConfig.defaults
    r.leaveSize = 1000; r.spawnInterval = 0.123; r.minDuration = 6; r.maxDuration = 2; r.leaveDuration = .nan
    let rs = r.sanitized()
    check(rs.leaveSize == 300, "环的大小上限 300")
    check(abs(rs.spawnInterval - 0.1) < 1e-9, "出环间隔按 0.05 步进取整 → 0.1")
    check(rs.maxDuration >= rs.minDuration, "最长持续不小于至少持续")
    check(rs.leaveDuration == RippleConfig.defaults.leaveDuration, "非数字回到默认值")
    check(RippleConfig.defaults.sanitized() == RippleConfig.defaults, "默认值本身合法")
    let old = try! JSONDecoder().decode(RippleConfig.self, from: Data(#"{"enabled":false,"leaveSize":90}"#.utf8))
    check(!old.enabled && old.leaveSize == 90 && old.arriveSize == 140 && old.leaveInterval == 0.1 && old.leaveTotal == 1,
          "缺字段的旧数据用默认值补齐（含离开多环的新字段）")
    var nr = RippleConfig.defaults; nr.leaveInterval = 0.2; nr.leaveTotal = 1.5
    let ns = SharedSettings(revision: 2, editor: "a", controllerID: "a", ripple: nr)
    let back = try! JSONDecoder().decode(SharedSettings.self, from: try! JSONEncoder().encode(ns))
    check(back == ns && back.ripple.leaveInterval == 0.2 && back.ripple.leaveTotal == 1.5, "共享设置编码再解码：离开多环参数原样保留")
    var bad2 = RippleConfig.defaults; bad2.leaveInterval = 0.001; bad2.leaveTotal = 99
    check(bad2.sanitized().leaveInterval == 0.05 && bad2.sanitized().leaveTotal == 5, "离开多环参数夹到合法范围")

    print("== 出环规则（离开多环 / 进入痕迹）")
    let lr = TrailRule.leave(.defaults)
    // 模拟定时器：第 1 个环在 0 秒出，之后每 0.1 秒问一次（带 ±4ms 抖动）
    func simulate(_ rule: TrailRule, until: Double, moveUntil: Double = 0, presentUntil: Double = .infinity) -> (Int, String) {
        var rings = 1
        var t = rule.interval
        var i = 0
        while t <= until + 1e-9 {
            let jitter = (i % 2 == 0 ? 0.004 : -0.004)
            let now = t + jitter
            let lastMove = min(now, moveUntil)
            switch rule.decide(elapsed: now, sinceMove: now - lastMove, present: now < presentUntil) {
            case .spawn: rings += 1
            case .stop(let why): return (rings, why)
            }
            t += rule.interval
            i += 1
        }
        return (rings, "没停")
    }
    let l1 = simulate(lr, until: 3)
    check(l1 == (10, "到达持续时间"), "离开默认参数：持续 1 秒、间隔 0.1 秒 → 共 10 个环（实际 \(l1)）")
    var c2 = RippleConfig.defaults; c2.leaveInterval = 0.25; c2.leaveTotal = 2
    let l2 = simulate(TrailRule.leave(c2), until: 5)
    check(l2 == (8, "到达持续时间"), "离开：持续 2 秒、间隔 0.25 秒 → 8 个环（实际 \(l2)）")
    let l3 = simulate(lr, until: 3, presentUntil: 0.35)
    check(l3 == (4, "光标回到本机"), "离开：0.35 秒时光标回到本机 → 停止出新环，共 4 个（实际 \(l3)）")
    var c4 = RippleConfig.defaults; c4.leaveTotal = 0
    check(simulate(TrailRule.leave(c4), until: 3) == (1, "到达持续时间"), "离开：持续时间 0 → 只有起点那一个环")
    check(lr.decide(elapsed: 0.5, sinceMove: 0.5, present: true) == .spawn, "离开：不看鼠标停没停")
    let ar = TrailRule.arrive(.defaults)
    let a1 = simulate(ar, until: 10, moveUntil: 0)
    check(a1 == (10, "鼠标停下"), "进入：鼠标一直不动 → 满至少持续 1 秒停（实际 \(a1)）")
    let a2 = simulate(ar, until: 10, moveUntil: 2.0)
    check(a2.1 == "鼠标停下" && a2.0 == 25, "进入：动到 2 秒 → 再过 0.5 秒停，共 25 个环（实际 \(a2)）")
    let a3 = simulate(ar, until: 10, moveUntil: 100)
    check(a3 == (50, "到达上限"), "进入：一直在动 → 满最长 5 秒停（实际 \(a3)）")
    let a4 = simulate(ar, until: 10, moveUntil: 100, presentUntil: 0.55)
    check(a4 == (6, "光标离开本机"), "进入：0.55 秒时光标离开本机 → 停（实际 \(a4)）")

    print("== 被控方光标短暂隐藏")
    check(CursorHider.hideDuration(.defaults) == 1.4, "默认隐藏时长 = 持续 1 秒 + 单环 0.4 秒 = 1.4 秒")
    var hc = RippleConfig.defaults; hc.leaveTotal = 2; hc.leaveDuration = 0.6
    check(abs(CursorHider.hideDuration(hc)! - 2.6) < 1e-9, "持续 2 秒 + 单环 0.6 秒 = 2.6 秒")
    hc.enabled = false
    check(CursorHider.hideDuration(hc) == nil, "光标特效关闭时不隐藏")
    // 用假时钟和假计时器驱动状态机
    var clock = 100.0
    var timers: [(at: Double, f: () -> Void)] = []
    var hides = 0, shows = 0, lines: [String] = []
    let hider = CursorHider(hideCursor: { hides += 1 }, showCursor: { shows += 1 }, now: { clock },
                            schedule: { d, f in timers.append((clock + d, f)) }, report: { lines.append($0) })
    func advance(to t: Double) {
        clock = t
        let due = timers.filter { $0.at <= t }
        timers.removeAll { $0.at <= t }
        due.forEach { $0.f() }
    }
    let t1 = hider.hide(reason: "测试", expected: 1.4)
    check(t1 != nil && hider.hidden && hides == 1, "隐藏一次")
    check(hider.hide(reason: "重复", expected: 1.4) == nil && hides == 1, "已隐藏时再隐藏不重复调用系统接口")
    check(timers.count == 1 && abs(timers[0].at - 102.4) < 1e-9, "兜底计时 = 隐藏时长 + 1 秒（102.4）")
    clock = 101.3
    hider.show(token: t1!, reason: .animationDone)
    check(!hider.hidden && shows == 1, "离开波纹播完 → 显示")
    check(lines.last?.contains("离开波纹播完") == true && lines.last?.contains("1.30") == true, "显示日志带原因和实际时长：\(lines.last ?? "")")
    advance(to: 103)
    check(shows == 1, "兜底计时到点时已经显示过 → 不再重复显示")
    hider.show(reason: .localInput)
    check(shows == 1, "没隐藏时任何显示路径都不调用系统接口")
    // 提前显示：本机有输入；之后过期的动画结束回调不起作用
    clock = 200
    let t2 = hider.hide(reason: "测试", expected: 1.4)!
    clock = 200.3
    hider.show(reason: .localInput)
    check(shows == 2 && !hider.hidden, "隐藏期间本机有输入 → 立即显示")
    let t3 = hider.hide(reason: "测试", expected: 1.4)!
    hider.show(token: t2, reason: .animationDone)
    check(hider.hidden && shows == 2, "上一次隐藏的动画结束回调（过期令牌）不会把这次的隐藏提前显示")
    hider.show(reason: .returned)
    check(shows == 3, "光标回到本机 → 立即显示")
    hider.show(token: t3, reason: .animationDone)
    check(shows == 3, "已显示后动画结束回调不重复显示")
    // 兜底：动画结束回调丢了，到点强制显示
    clock = 300
    _ = hider.hide(reason: "测试", expected: 1.4)
    advance(to: 302.39)
    check(hider.hidden, "兜底计时未到（隐藏后 2.39 秒）仍隐藏")
    advance(to: 302.41)
    check(!hider.hidden && lines.last?.contains("兜底计时到点") == true, "兜底计时到点（隐藏后 2.4 秒）强制显示")
    check(hides == shows, "隐藏与显示次数严格相等（\(hides) 对 \(shows)）")
    // 本机输入的判定
    let me: Int64 = 4242
    check(isLocalUserInput(type: .mouseMoved, userData: 0, sourcePID: 0, myPID: me), "触控板移动（来源进程 0、无标记）算本机输入")
    check(isLocalUserInput(type: .keyDown, userData: 0, sourcePID: 0, myPID: me), "按键算本机输入")
    check(isLocalUserInput(type: .scrollWheel, userData: 0, sourcePID: 0, myPID: me), "滚动算本机输入")
    check(!isLocalUserInput(type: .keyUp, userData: kInjectedMarker, sourcePID: me, myPID: me), "MacKVM 补发的按键抬起不算")
    check(!isLocalUserInput(type: .mouseMoved, userData: kInjectedMarker, sourcePID: 0, myPID: me), "带注入标记的事件不算")
    check(!isLocalUserInput(type: .leftMouseDown, userData: 0, sourcePID: me, myPID: me), "来源进程是本进程的事件不算")
    check(!isLocalUserInput(type: .flagsChanged, userData: 0, sourcePID: 0, myPID: me), "单独的修饰键变化不算")

    print("== 07 卡片预览：越线判定")
    var tk = CardCrossTracker(cardWidth: 416, gap: 4, height: 350)
    check(tk.midX == 418, "分界线在 x = 418")
    check(tk.move(to: CGPoint(x: 300, y: 100)) == nil && tk.current == .left, "在左卡片里移动：不触发")
    check(tk.move(to: CGPoint(x: 417, y: 105)) == nil && tk.current == nil, "进入两卡之间的空隙：不触发")
    let x1 = tk.move(to: CGPoint(x: 430, y: 110))
    check(x1?.from == .left && x1?.to == .right && x1?.at.x == 418, "左 → 右越线：触发（\(String(describing: x1))）")
    check(x1.map { abs($0.at.y - (105 + 5 * (418 - 417) / 13)) < 0.01 } == true, "越线点 y 取连线和分界线的交点")
    check(tk.move(to: CGPoint(x: 500, y: 120)) == nil, "越线后在右卡片里继续移动：不再触发")
    let x2 = tk.move(to: CGPoint(x: 400, y: 120))
    check(x2?.from == .right && x2?.to == .left && x2?.at == CGPoint(x: 418, y: 120), "右 → 左越回：再次触发")
    // 一步跨过分界线（事件稀疏、没落在空隙里）
    let x3 = tk.move(to: CGPoint(x: 600, y: 200))
    check(x3?.from == .left && x3?.to == .right && abs(x3!.at.y - (120 + 80 * 18 / 200)) < 0.01, "一步跳过空隙也算越线，越线点按插值算")
    // 从上边离开左卡片、再从上边进入右卡片：不触发
    var tk2 = CardCrossTracker(cardWidth: 416, gap: 4, height: 350)
    _ = tk2.move(to: CGPoint(x: 300, y: 10))
    check(tk2.move(to: CGPoint(x: 300, y: -3)) == nil && tk2.current == nil, "从左卡片上边出去：不触发")
    check(tk2.move(to: CGPoint(x: 500, y: 5)) == nil && tk2.current == .right, "再从右卡片上边进来：不触发")
    // 从下边、外侧边进出
    var tk3 = CardCrossTracker(cardWidth: 416, gap: 4, height: 350)
    check(tk3.move(to: CGPoint(x: 200, y: 349)) == nil, "从左卡片下边进来：不触发")
    tk3.exit()   // 视图报告鼠标离开了容器（从下边出去）
    check(tk3.move(to: CGPoint(x: 700, y: 349)) == nil, "从右卡片下边进来：不触发")
    check(tk3.move(to: CGPoint(x: 840, y: 200)) == nil && tk3.current == nil, "从右卡片外侧边出去：不触发")
    check(tk3.move(to: CGPoint(x: 10, y: 200)) == nil && tk3.current == .left, "从左卡片外侧边进来：不触发")
    // 从空隙的上方进入、再进右卡片：之前没在任何卡片里，不算越线
    var tk4 = CardCrossTracker(cardWidth: 416, gap: 4, height: 350)
    _ = tk4.move(to: CGPoint(x: 418, y: 0))
    check(tk4.move(to: CGPoint(x: 430, y: 20)) == nil, "从两卡之间的上方钻进来再进右卡片：不触发")

    print("== 波纹颜色")
    let cs = ["#111111", "#222222", "#333333"]
    check((0..<7).map { cycledColor(cs, $0) } == ["#111111", "#222222", "#333333", "#111111", "#222222", "#333333", "#111111"],
          "第 1、2、3 个环依次取色，用完回到第 1 个")
    check(cycledColor(["#ABCDEF"], 5) == "#ABCDEF", "只有一个颜色时每个环都用它")
    check(RippleConfig.defaults.leaveColors == ["#FFFFFF", "#000000"], "离开波纹默认颜色：先白后黑")
    check(RippleConfig.defaults.arriveColors == ["#000000", "#FFFFFF"], "进入波纹默认颜色：先黑后白")
    var rc = RippleConfig.defaults
    rc.leaveColors = []
    rc.arriveColors = ["#ff0000", "zzz", "#00ff00", "#0000FF", "#123456", "#654321", "#ABCDEF"]
    let rcs = rc.sanitized()
    check(rcs.leaveColors == RippleConfig.defaultLeaveColors, "颜色列表空了 → 回到这一组的默认颜色（每组至少一个）")
    var rc2 = RippleConfig.defaults; rc2.arriveColors = ["zzz"]
    check(rc2.sanitized().arriveColors == RippleConfig.defaultArriveColors, "进入波纹的颜色全不合法 → 回到进入波纹的默认颜色")
    check(rcs.arriveColors == ["#FF0000", "#00FF00", "#0000FF", "#123456", "#654321"], "非法色值去掉、统一大写、最多 5 个")
    let oldNoColor = try! JSONDecoder().decode(RippleConfig.self, from: Data(#"{"enabled":true,"leaveSize":120}"#.utf8))
    check(oldNoColor.leaveColors == RippleConfig.defaultLeaveColors && oldNoColor.arriveColors == RippleConfig.defaultArriveColors,
          "旧数据没有颜色字段 → 两组各补自己的默认颜色")
    var withColor = RippleConfig.defaults; withColor.leaveColors = ["#FF8800"]; withColor.arriveColors = ["#00AA00", "#0055FF"]
    let sc = SharedSettings(revision: 9, editor: "a", controllerID: "a", ripple: withColor)
    let scBack = try! JSONDecoder().decode(SharedSettings.self, from: try! JSONEncoder().encode(sc))
    check(scBack.ripple.leaveColors == ["#FF8800"] && scBack.ripple.arriveColors == ["#00AA00", "#0055FF"], "颜色随共享设置编码再解码原样保留")
    check(hexColorString(parseHexColor("#9166d8")!) == "#9166D8", "色值解析和输出互逆")

    print("== 取色器")
    check(normalizedHexInput("#1a2b3c") == "#1A2B3C", "HEX 输入「#1a2b3c」有效，统一成大写")
    check(normalizedHexInput("1A2B3C") == "#1A2B3C", "HEX 输入「1A2B3C」（不带 #）有效")
    check(normalizedHexInput("#12345") == nil, "HEX 输入「#12345」（五位）无效")
    check(normalizedHexInput("#GGGGGG") == nil, "HEX 输入「#GGGGGG」（不是十六进制）无效")
    check(normalizedHexInput("+12345") == nil && normalizedHexInput("#１２３４５６") == nil, "带正号、全角数字的输入无效")
    check(parseHexColor("#12345") == nil && parseHexColor("+12345") == nil, "色值解析同样只认六位十六进制")
    // 色盘坐标 ↔ 饱和度 / 明度：往返一致；左上白、右上纯色相、下方黑
    let fieldSize = CGSize(width: 174, height: 84)
    var svOK = true
    for x in stride(from: 0.0, through: 174.0, by: 14.5) {
        for y in stride(from: 0.0, through: 84.0, by: 7.0) {
            let sv = svValue(at: CGPoint(x: x, y: y), size: fieldSize)
            let back = svPoint(s: sv.s, v: sv.v, size: fieldSize)
            if abs(back.x - x) > 0.0001 || abs(back.y - y) > 0.0001 { svOK = false }
        }
    }
    check(svOK, "色盘上的点 → 饱和度 / 明度 → 点，往返一致")
    check(svValue(at: CGPoint(x: -20, y: 200), size: fieldSize) == (0, 0) && svValue(at: CGPoint(x: 999, y: -5), size: fieldSize) == (1, 1),
          "拖出色盘时夹到边上")
    check(hexFromHSV(HSV(h: 0.5, s: 0, v: 1)) == "#FFFFFF" && hexFromHSV(HSV(h: 0, s: 1, v: 1)) == "#FF0000"
          && hexFromHSV(HSV(h: 0.3, s: 0.7, v: 0)) == "#000000", "色盘左上是白、右上是纯色相、下边是黑")
    var hexOK = true
    var seed: UInt64 = 0x1234_5678
    for _ in 0..<2000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let hex = String(format: "#%06X", Int((seed >> 20) & 0xFFFFFF))
        guard let c = hsvFromHex(hex), hexFromHSV(c) == hex else { hexOK = false; break }
        // 再经过色盘坐标走一遍：颜色 → 坐标 → 颜色
        let p = svPoint(s: c.s, v: c.v, size: fieldSize)
        let sv = svValue(at: p, size: fieldSize)
        if hexFromHSV(HSV(h: c.h, s: sv.s, v: sv.v)) != hex { hexOK = false; break }
    }
    check(hexOK, "2000 个随机颜色：HEX → 色相 / 饱和度 / 明度 → 色盘坐标 → HEX，往返一致")
    let pm = ColorPickerModel()
    var picked: [String] = []
    pm.onPick = { picked.append($0) }
    pm.load("#FF0000")
    pm.setHue(1.0 / 3)
    check(pm.hex == "#00FF00" && pm.hexText == "#00FF00" && picked == ["#00FF00"], "拖色相滑杆：颜色和输入框一起变，并立即应用")
    pm.hexText = "1a2b3c"; pm.typed(pm.hexText)
    check(pm.hex == "#1A2B3C" && pm.hexText == "1a2b3c" && picked.last == "#1A2B3C", "输入有效 HEX：立即应用，正在输的文字不被改写")
    pm.commitText()
    check(pm.hexText == "#1A2B3C", "回车 / 失焦：有效输入统一写成 #RRGGBB")
    pm.hexText = "#12345"; pm.typed(pm.hexText); pm.commitText()
    check(pm.hex == "#1A2B3C" && pm.hexText == "#1A2B3C" && picked.count == 2, "回车 / 失焦：无效输入恢复上次有效值，不应用")
    let hueBefore = pm.hsv.h
    pm.hexText = "#808080"; pm.typed(pm.hexText)
    check(pm.hex == "#808080" && pm.hsv.h == hueBefore, "输入灰色：保留原来的色相，色相滑杆不跳")

    print("== 取色器：删除按钮")
    check(removingColor(["#111111"], at: 0) == nil, "这一组只剩一个颜色：不可删")
    check(removingColor(["#111111", "#222222", "#333333"], at: 1) == ["#111111", "#333333"], "删第 2 个：其余颜色和顺序不变")
    check(removingColor(["#111111", "#222222"], at: 5) == nil, "序号越界：不删")
    let pc = ColorPopoverController()
    var colorsUnderEdit = ["#AA0000", "#00AA00", "#0000AA"]
    let editT = ColorEditTarget(group: \.leaveColors, index: 1)
    var appliedHex: [String] = []
    pc.attach(target: editT, initial: colorsUnderEdit[1], canDelete: colorsUnderEdit.count > 1,
              apply: { appliedHex.append($0) },
              remove: { if let rest = removingColor(colorsUnderEdit, at: 1) { colorsUnderEdit = rest } })
    check(pc.editing == editT && pc.picker.canDelete, "三个颜色时打开：删除按钮可点")
    pc.picker.setHue(0.5)        // 改了色还没到 0.12 秒的合并点，随即删除
    pc.picker.onDelete?()        // 等同点删除按钮
    check(colorsUnderEdit == ["#AA0000", "#0000AA"], "删除正在编辑的颜色：列表里去掉它，其余不动")
    check(pc.editing == nil && appliedHex.isEmpty, "删除后弹出框关闭（没有正在编辑的色样），没应用的改色直接丢掉")
    pc.picker.onDelete?()
    check(colorsUnderEdit == ["#AA0000", "#0000AA"], "弹出框关了再触发删除：什么都不删")
    var single = ["#ABCDEF"]
    pc.attach(target: ColorEditTarget(group: \.arriveColors, index: 0), initial: single[0], canDelete: single.count > 1,
              apply: { _ in }, remove: { if let rest = removingColor(single, at: 0) { single = rest } })
    check(!pc.picker.canDelete, "这一组只剩一个颜色时打开：删除按钮灰掉")
    pc.picker.onDelete?()
    check(single == ["#ABCDEF"] && pc.editing != nil, "灰掉时点删除：不删、弹出框不关")
    pc.close()

    print("== 取色器：再点同一个色样就收起")
    let swA = ColorEditTarget(group: \.leaveColors, index: 0), swB = ColorEditTarget(group: \.leaveColors, index: 1)
    let swC = ColorEditTarget(group: \.arriveColors, index: 0)
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    let byClick = ColorPopoverDismissal(target: swA, at: t0, click: 41)
    check(colorPopoverShouldOpen(after: nil, target: swA, now: t0, click: 41), "没被收起过：点色样就打开")
    check(!colorPopoverShouldOpen(after: byClick, target: swA, now: t0.addingTimeInterval(0.08), click: 41),
          "开着时再点同一个色样：收起它的就是这次点击（事件编号相同）→ 不重开")
    check(!colorPopoverShouldOpen(after: byClick, target: swA, now: t0.addingTimeInterval(0.9), click: 41),
          "按住很久才松开（超过 0.3 秒）：事件编号相同，照样不重开")
    check(colorPopoverShouldOpen(after: byClick, target: swA, now: t0.addingTimeInterval(0.2), click: 42),
          "收起后很快又点了一次同一个色样（新的点击）→ 重新打开")
    check(colorPopoverShouldOpen(after: byClick, target: swB, now: t0.addingTimeInterval(0.08), click: 41),
          "开着时点同组另一个色样 → 从那个色样弹出")
    check(colorPopoverShouldOpen(after: byClick, target: swC, now: t0.addingTimeInterval(0.08), click: 41),
          "开着时点另一组的色样 → 从那个色样弹出")
    let byTime = ColorPopoverDismissal(target: swA, at: t0, click: nil)
    check(!colorPopoverShouldOpen(after: byTime, target: swA, now: t0.addingTimeInterval(0.25), click: 41),
          "拿不到收起时的事件编号：0.3 秒内再点同一个色样 → 不重开")
    check(colorPopoverShouldOpen(after: byTime, target: swA, now: t0.addingTimeInterval(0.35), click: 41),
          "拿不到收起时的事件编号：超过 0.3 秒 → 重新打开")
    check(!colorPopoverShouldOpen(after: byClick, target: swA, now: t0.addingTimeInterval(0.1), click: nil),
          "拿不到这次点击的事件编号：按时间判，0.1 秒 → 不重开")

    print("== 重置键鼠状态")
    check(isResetHotkey(keyCode: 37, flags: [.control, .option, .command]), "被控方热键：⌃⌥⌘L")
    check(isResetHotkey(keyCode: 37, flags: [.control, .option, .command, .shift]), "多按 Shift 也算（和主控的判定一致）")
    check(!isResetHotkey(keyCode: 37, flags: [.control, .command]) && !isResetHotkey(keyCode: 38, flags: [.control, .option, .command]),
          "少一个修饰键、或不是 L 键：不算")
    check(StatusMenu.wantsMenu(type: .rightMouseUp, modifiers: []), "菜单栏图标：右键弹菜单")
    check(StatusMenu.wantsMenu(type: .leftMouseUp, modifiers: [.control]), "菜单栏图标：Control + 左键弹菜单")
    check(!StatusMenu.wantsMenu(type: .leftMouseUp, modifiers: []), "菜单栏图标：左键不弹菜单（打开主窗口）")
    func resetModel(controller: Bool, status: LinkStatus) -> AppModel {
        let me = DeviceIdentity(id: "me", name: "本机", isLaptop: true)
        let m = AppModel(preview: me)
        m.pairing = PairingRecord(peerID: "peer", peerName: "对方", peerIsLaptop: false,
                                  keyBase64: Data(count: 32).base64EncodedString(), lastAddress: nil)
        m.shared = SharedSettings(revision: 1, editor: "me", controllerID: controller ? "me" : "peer", ripple: .defaults)
        m.linkStatus = status
        return m
    }
    check(resetModel(controller: false, status: .connected).canResetInput, "本机是被控、已连接：显示「重置键鼠状态」")
    check(!resetModel(controller: true, status: .connected).canResetInput, "本机是主控：不显示「重置键鼠状态」")
    check(!resetModel(controller: false, status: .offline).canResetInput && !resetModel(controller: false, status: .searching).canResetInput,
          "本机是被控但没连上：不显示")
    check(!AppModel(preview: DeviceIdentity(id: "x", name: "x", isLaptop: true)).canResetInput, "未配对：不显示")
    // 被控方点重置：发空载荷 leave（主控把光标放到它的主屏中心）并退出活动状态。
    // 关掉波纹总开关再跑：退出活动状态时不隐藏光标、不出离开波纹，自测不碰屏幕上的光标
    let savedRipple = rippleConfig
    rippleConfig.enabled = false
    let role = ControlledRole(peer: { nil }, map: { CrossingMap(views: [], localScreens: [], remoteScreens: []) })
    var sentMsgs: [(Msg, Data)] = []
    role.send = { t, d in sentMsgs.append((t, d)) }
    check(!role.resetInputState("自测：本机不在被操作状态") && sentMsgs.isEmpty, "本机不在被操作状态时重置：什么都不发，只记日志")
    role.active = true
    let seqBefore = role.transitionSeq
    check(role.resetInputState("自测：本机正在被操作"), "本机正在被操作时重置：执行")
    check(sentMsgs.count == 1 && sentMsgs[0].0 == .leave && sentMsgs[0].1.isEmpty, "重置时发出的是空载荷的 leave")
    check(!role.active && role.transitionSeq == seqBefore + 1, "重置后退出活动状态")
    check(!role.resetInputState("自测：再点一次") && sentMsgs.count == 1, "已经交还后再点：不再发")
    rippleConfig = savedRipple

    print("== 后备地址")
    if case .ipv6(let a) = NWEndpoint.Host("fe80::1234:5678:9abc:def0%lo0") {
        check("\(a)".hasPrefix("fe80::1234:5678:9abc:def0"), "带网卡后缀的 IPv6 链路本地地址能解析成 IPv6（\(a)）")
    } else {
        check(false, "带网卡后缀的 IPv6 链路本地地址解析失败")
    }

    print("== 配对密码学")
    // X25519 对任意 u 坐标（曲线上或扭曲线上）都要满足交换律
    var commOK = true
    for _ in 0..<64 {
        var u = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        u[31] &= 0x7f
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        guard let ya = try? PairingCrypto.x25519(a, u), let yb = try? PairingCrypto.x25519(b, u),
              let k1 = try? PairingCrypto.x25519(a, yb), let k2 = try? PairingCrypto.x25519(b, ya), k1 == k2 else {
            commOK = false
            break
        }
    }
    check(commOK, "X25519 对 64 个随机基点都满足 a·(b·G) = b·(a·G)")
    check((try? PairingCrypto.x25519(Curve25519.KeyAgreement.PrivateKey(), Data(count: 32))) == nil, "低阶点（全 0）被拒绝")
    let nc = Data((0..<16).map { _ in UInt8.random(in: 0...255) }), ni = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    func run(codeC: String, codeI: String) -> (Bool, Bool, Bool) {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let gc = PairingCrypto.generator(code: codeC, nonceC: nc, nonceI: ni, idC: "c", idI: "i")
        let gi = PairingCrypto.generator(code: codeI, nonceC: nc, nonceI: ni, idC: "c", idI: "i")
        let yi = try! PairingCrypto.x25519(b, gi), yc = try! PairingCrypto.x25519(a, gc)
        let kc = try! PairingCrypto.x25519(a, yi), ki = try! PairingCrypto.x25519(b, yc)
        let hc = PairingCrypto.Hello(id: "c", name: "C", nonce: nc), hi = PairingCrypto.Hello(id: "i", name: "I", nonce: ni)
        let tr = PairingCrypto.transcript(c: hc, i: hi, yI: yi, yC: yc)
        let keysC = PairingCrypto.keys(k: kc, transcript: tr), keysI = PairingCrypto.keys(k: ki, transcript: tr)
        let macC = PairingCrypto.mac(keysC.confirmC, tr)
        let iAccepts = PairingCrypto.verify(macC, keysI.confirmC, tr)
        let ltSame = keysC.longTerm.withUnsafeBytes { Data($0) } == keysI.longTerm.withUnsafeBytes { Data($0) }
        return (kc == ki, iAccepts, ltSame)
    }
    let ok = run(codeC: "58291604", codeI: "58291604")
    check(ok.0 && ok.1 && ok.2, "配对码相同：共享密钥一致、确认码通过、长期密钥一致")
    let bad1 = run(codeC: "58291605", codeI: "58291604")
    check(!bad1.0 && !bad1.1 && !bad1.2, "配对码差一位：共享密钥不同、确认码不通过")
    let codes = (0..<200).map { _ in PairingCrypto.newCode() }
    check(codes.allSatisfy { $0.count == 8 && $0.allSatisfy(\.isNumber) }, "配对码都是 8 位数字")
    check(Set(codes).count > 190, "配对码随机（200 个里几乎不重复）")
    check(PairingCrypto.digits("5829 – 1604") == "58291604", "输入框里的分隔符会被去掉")

    print("== 远端位移：取位移字段，warp 的跳变剔除")
    let ctr = CGPoint(x: 1280, y: 720)
    var m = RemoteDelta()
    m.warped()   // 切到远端那次 warp
    let rd1 = m.next(field: CGPoint(x: -3060, y: 0), loc: CGPoint(x: 1281, y: 720), center: ctr)
    let rd2 = m.next(field: CGPoint(x: 30, y: 0), loc: CGPoint(x: 1311, y: 720), center: ctr)
    check(near(rd1, CGPoint(x: 1, y: 0)) && near(rd2, CGPoint(x: 30, y: 0)), "切过去那次 warp 的跳变被剔除，之后用位移字段")
    m.warped()
    let rd3 = m.next(field: CGPoint(x: 20, y: 5), loc: CGPoint(x: 2400, y: 1300), center: ctr)
    let rd4 = m.next(field: CGPoint(x: -1100, y: -590), loc: CGPoint(x: 1304, y: 821), center: ctr)
    let rd5 = m.next(field: CGPoint(x: -400, y: 0), loc: CGPoint(x: 1304, y: 821), center: ctr)
    check(near(rd3, CGPoint(x: 20, y: 5)) && near(rd4, CGPoint(x: 24, y: 101)) && near(rd5, CGPoint(x: -400, y: 0)),
          "在飞的事件先到（用字段），warp 落地那一下离中心 104 点也算落地、剔除跳变，之后用字段")

    print("== 切回本地的落点")
    check(LocalLanding.forLeave(Data()) == .mainCenter, "空载荷 leave（被控那台重置了键鼠状态）→ 落主屏中心")
    let backPayload = CrossPayload(screen: P.id, edge: .right, mm: 144)
    check(LocalLanding.forLeave(try! JSONEncoder().encode(backPayload)) == .payload(backPayload), "带落点的 leave（光标推回来）→ 按落点")
    check(LocalLanding.forLeave(Data("乱码".utf8)) == .exitPoint, "有内容却解不出的 leave → 落回跨出点")
    let exitPt = CGPoint(x: 4479, y: 540)
    let mainB = CGRect(x: 0, y: 0, width: 2560, height: 1440)   // 主屏 U2720QM 在全局坐标里的范围
    let screensUP: [String: ScreenInfo] = [U.id: U, P.id: P]
    let lc = LocalLanding.mainCenter.resolve(exitPoint: exitPt, mainBounds: mainB, screens: screensUP)
    check(near(lc.point, CGPoint(x: 1280, y: 720)) && lc.how == "落在主屏中心", "重置 → 主屏中心 (1280, 720)，日志写「落在主屏中心」")
    let lc2 = LocalLanding.mainCenter.resolve(exitPoint: exitPt, mainBounds: CGRect(x: 0, y: 0, width: 1512, height: 982), screens: [:])
    check(near(lc2.point, CGPoint(x: 756, y: 491)), "主屏换成内建屏 → 落在它的中心 (756, 491)")
    let le = LocalLanding.exitPoint.resolve(exitPoint: exitPt, mainBounds: mainB, screens: screensUP)
    check(near(le.point, exitPt) && le.how == "回到跨出去时的位置", "安全兜底（角色停止、断线、重连）→ 落回跨出点")
    let lp = LocalLanding.payload(backPayload).resolve(exitPoint: exitPt, mainBounds: mainB, screens: screensUP)
    check(near(lp.point, CrossingMap.landing(on: P, edge: .right, mm: 144)), "带落点的正常推回 → 落在对方给的那块屏那条边上，不变")
    let lgone = LocalLanding.payload(CrossPayload(screen: "拔掉了", edge: .left, mm: 10))
        .resolve(exitPoint: exitPt, mainBounds: mainB, screens: screensUP)
    check(near(lgone.point, exitPt), "落点那块屏已不在本机 → 落回跨出点")
}

// MARK: - loopback：单进程内配对 + Link

let devC = DeviceIdentity(id: "test-a-controller", name: "测试主控", isLaptop: false)
let devI = DeviceIdentity(id: "test-b-controlled", name: "测试被控", isLaptop: true)

func fail(_ r: Result<PairingResult, PairFailure>?) -> PairFailure? {
    if case .failure(let f)? = r { return f }
    return nil
}

func pairOnce(_ port: UInt16, _ code: String) -> Result<PairingResult, PairFailure>? {
    var out: Result<PairingResult, PairFailure>?
    PairingSeeker(me: devC).pair(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                 expectedID: devI.id, code: code) { out = $0 }
    _ = spin(5) { out != nil }
    return out
}

func loopbackTests() {
    print("== 单进程配对握手")
    let inv = PairingInviter(me: devI, advertise: false)
    var port: UInt16 = 0
    var renewedCode: String?
    var paired: PairingResult?
    inv.onReady = { port = $0 }
    inv.onCodeChanged = { c, renewed in if renewed { renewedCode = c } }
    inv.onPaired = { paired = $0 }
    inv.start()
    check(spin(3) { port != 0 }, "被控方配对监听就绪（端口 \(port)）")
    let firstCode = inv.code
    let wrong = firstCode == "00000000" ? "11111111" : "00000000"
    for i in 1...4 {
        let r = pairOnce(port, wrong)
        check(fail(r) == (.wrongCode(left: 5 - i)), "第 \(i) 次输错：提示还剩 \(5 - i) 次（实际 \(String(describing: r))）")
    }
    let r5 = pairOnce(port, wrong)
    check(fail(r5) == (.renewed), "第 5 次输错：对方换码（实际 \(String(describing: r5))）")
    check(renewedCode != nil && renewedCode != firstCode && inv.code == renewedCode, "被控方生成了新配对码")
    let rOld = pairOnce(port, firstCode)
    check(fail(rOld) == (.wrongCode(left: 4)), "旧码作废：用旧码配对失败")
    var seekRes: PairingResult?
    if case .success(let s)? = pairOnce(port, inv.code) { seekRes = s }
    check(seekRes != nil, "用新码配对成功（主控方）")
    check(spin(3) { paired != nil }, "被控方也报告配对成功")
    guard let a = seekRes, let b = paired else { return }
    let ka = a.key.withUnsafeBytes { Data($0) }, kb = b.key.withUnsafeBytes { Data($0) }
    check(ka == kb && ka.count == 32, "两边长期密钥一致（指纹 \(PairingCrypto.fingerprint(a.key))）")
    check(a.peerID == devI.id && b.peerID == devC.id, "两边记下了对方的设备 ID")
    check(a.peerName == "测试被控" && b.peerName == "测试主控" && a.peerIsLaptop && !b.peerIsLaptop, "两边记下了对方的设备名和机型")
    check(a.peerAddress == "127.0.0.1", "主控方记下了对方地址 \(a.peerAddress ?? "nil")")
    check(b.peerAddress == "127.0.0.1", "被控方也记下了对方地址 \(b.peerAddress ?? "nil")")
    inv.stop()

    print("== 单进程 Link：加密帧收发、断线重连")
    let pA: UInt16 = 24921, pB: UInt16 = 24922
    let linkA = Link(me: devC, peerID: devI.id, key: a.key, lastAddress: "127.0.0.1", port: pA, peerPort: pB, useBonjour: false)
    func makeB() -> Link {
        Link(me: devI, peerID: devC.id, key: b.key, lastAddress: nil, port: pB, peerPort: pA, useBonjour: false)
    }
    var linkB = makeB()
    var aUp = 0, bUp = 0, aDown = 0
    var gotB: [(Msg, Data)] = []
    var gotA: [(Msg, Data)] = []
    linkA.onAuthenticated = { _ in aUp += 1 }
    linkA.onDisconnected = { aDown += 1 }
    linkA.onMessage = { _, t, d in gotA.append((t, d)) }
    func wireB(_ l: Link) {
        l.onAuthenticated = { _ in bUp += 1 }
        l.onMessage = { p, t, d in
            gotB.append((t, d))
            if t == .enter { p.send(.leave, d) }  // 回显：收到 enter 回 leave
        }
    }
    wireB(linkB)
    check(linkA.isInitiator && !linkB.isInitiator, "设备 ID 小的一方主动连接")
    linkB.start()
    linkA.start()
    check(spin(6) { aUp == 1 && bUp == 1 }, "两边都通过密钥校验")
    var ratio = Data(); ratio.appendDouble(0.3125)
    linkA.active?.send(.enter, ratio)
    var mv = Data(); mv.appendBE(Int32(-7)); mv.appendBE(Int32(12))
    linkA.active?.send(.move, mv)
    check(spin(3) { gotA.contains { $0.0 == .leave } }, "主控发 enter，被控回 leave")
    check(gotA.first(where: { $0.0 == .leave })?.1.readDouble(0) == 0.3125, "比例原样往返 0.3125")
    check(spin(2) { gotB.contains { $0.0 == .move } }, "被控收到 move")
    if let m = gotB.first(where: { $0.0 == .move })?.1 {
        check(m.readBE(0, Int32.self) == -7 && m.readBE(4, Int32.self) == 12, "move 的位移正确 (-7, 12)")
    }
    // 共享设置（含离开多环的新字段）经加密连接同步
    var syncR = RippleConfig.defaults; syncR.leaveInterval = 0.3; syncR.leaveTotal = 2.5; syncR.leaveDuration = 0.6
    syncR.leaveColors = ["#FF0000"]; syncR.arriveColors = ["#00FF00", "#0000FF"]
    let syncRule = AdjacencyRule(id: "r-sync", aDevice: devC.id, aScreen: "SC", aEdge: .down, bDevice: devI.id,
                                 bScreen: "SI", offsetMM: 12.5)
    let syncS = SharedSettings(revision: 7, editor: devC.id, controllerID: devC.id, rules: [syncRule],
                               rulesInitialized: true, ripple: syncR)
    linkA.active?.send(.settings, try! JSONEncoder().encode(syncS))
    check(spin(2) { gotB.contains { $0.0 == .settings } }, "被控收到共享设置")
    if let d = gotB.first(where: { $0.0 == .settings })?.1, let got = try? JSONDecoder().decode(SharedSettings.self, from: d) {
        check(got == syncS && got.rules.first?.view(from: devI.id)?.localEdge == .up && got.rules.first?.view(from: devI.id)?.offsetMM == -12.5, "共享设置原样到达（离开多环参数、两组颜色、规则；被控视角：本机屏上边、错开 -12.5）")
        check(got.isNewer(than: SharedSettings(revision: 6, editor: devI.id, controllerID: devC.id, ripple: .defaults)),
              "收到的修订号更大 → 被控方会采用")
    } else {
        check(false, "共享设置解码失败")
    }
    // 屏幕清单经加密连接交换
    let scr = [ScreenInfo(id: "SC", name: "DELL U2720QM", isMain: true, isBuiltin: false, x: 0, y: 0, w: 2560, h: 1440,
                          mmW: 599, mmH: 340, estimated: false)]
    linkA.active?.send(.screens, try! JSONEncoder().encode(scr))
    check(spin(2) { gotB.contains { $0.0 == .screens } }, "被控收到屏幕清单")
    if let d = gotB.first(where: { $0.0 == .screens })?.1 {
        check((try? JSONDecoder().decode([ScreenInfo].self, from: d)) == scr, "屏幕清单原样到达（ID、名字、点坐标、毫米尺寸）")
    }
    // 被控方进程重启：A 应该检测到断线并自动重连
    linkB.stop()
    check(spin(5) { aDown == 1 }, "被控方停止后主控方 3 秒内发现断线")
    linkB = makeB()
    wireB(linkB)
    linkB.start()
    check(spin(8) { aUp == 2 }, "被控方重新启动后自动重连")
    // 用错误密钥的冒充者连不上
    let fake = Link(me: DeviceIdentity(id: "test-0-fake", name: "冒充", isLaptop: false), peerID: devI.id,
                    key: SymmetricKey(size: .bits256), lastAddress: "127.0.0.1", port: 24923, peerPort: pB, useBonjour: false)
    var fakeUp = false
    fake.onAuthenticated = { _ in fakeUp = true }
    fake.start()
    _ = spin(4) { fakeUp }
    check(!fakeUp, "用错误密钥的连接通不过校验")
    check(linkA.active != nil, "冒充者没有挤掉正在用的连接")
    fake.stop()
    linkA.stop()
    linkB.stop()
    // 后备地址是 IPv6（Bonjour 经常选链路本地 IPv6）时也能连上，并把它记下来
    let v6A = Link(me: devC, peerID: devI.id, key: a.key, lastAddress: "::1", port: 24924, peerPort: 24925, useBonjour: false)
    let v6B = Link(me: devI, peerID: devC.id, key: b.key, lastAddress: nil, port: 24925, peerPort: 24924, useBonjour: false)
    var v6Up = false
    var learned: String?
    v6A.onAuthenticated = { _ in v6Up = true }
    v6B.onAddressLearned = { learned = $0 }
    v6B.start(); v6A.start()
    check(spin(6) { v6Up }, "按 IPv6 后备地址 ::1 连上")
    check(spin(1) { learned != nil } && learned!.contains(":"), "被连的一方记下了对方的 IPv6 地址 \(learned ?? "nil")")
    v6A.stop(); v6B.stop()
}

// MARK: - 07 卡片预览：用真实的出环调度跑一遍

func previewTests() {
    print("== 卡片预览（真实出环调度，检查出环命令记录）")
    var cfg = RippleConfig.defaults
    cfg.leaveColors = ["#AA0000", "#00AA00"]
    cfg.arriveColors = ["#0000AA"]
    rippleConfig = cfg
    let pv = RipplePreviewModel()
    pv.setLayout(cardWidth: 416, gap: 4, height: 350)
    var drawn: [CardSide: [CGPoint]] = [.left: [], .right: []]
    pv.register(.left) { p, _, _ in drawn[.left]!.append(p) }
    pv.register(.right) { p, _, _ in drawn[.right]!.append(p) }
    pv.pointerMoved(CGPoint(x: 380, y: 170))
    pv.pointerMoved(CGPoint(x: 430, y: 172))       // 左 → 右越线
    _ = spin(0.33) { false }
    pv.pointerMoved(CGPoint(x: 460, y: 180))       // 在右卡片里继续移动
    _ = spin(0.3) { false }
    let leftRings = pv.spawned.filter { $0.side == .left }, rightRings = pv.spawned.filter { $0.side == .right }
    check(!leftRings.isEmpty && leftRings.allSatisfy { $0.kind == .leave && $0.maxRadius == 70 && $0.center.x == 418 },
          "左卡片：离开波纹（大小 70），圆心固定在越线点")
    check(Array(leftRings.prefix(3).map(\.color)) == ["#AA0000", "#00AA00", "#AA0000"], "左卡片离开环按离开颜色循环取色")
    check(!rightRings.isEmpty && rightRings.allSatisfy { $0.kind == .arrive && $0.maxRadius == 140 && $0.color == "#0000AA" },
          "右卡片：进入波纹（大小 140、进入颜色）")
    check(rightRings.contains { $0.center.x == 460 }, "右卡片的进入环跟着鼠标走")
    check(drawn[.left]!.first.map { $0.x == 418 && abs($0.y - 171.52) < 0.001 } == true, "左卡片收到的画环位置换算成卡片坐标 \(drawn[.left]!.first.map { "\($0)" } ?? "无")")
    check(drawn[.right]!.first.map { $0.x == -2 && abs($0.y - 171.52) < 0.001 } == true, "右卡片收到的画环位置减去左卡宽和空隙（越线点在它左边界外 2 点）")
    check(drawn[.left]!.count == leftRings.count && drawn[.right]!.count == rightRings.count, "每条出环命令都交给了对应卡片的图层")
    // 越回左卡片：右卡片的进入波纹停、左卡片的离开波纹停；右卡片开始播离开、左卡片开始播进入
    pv.pointerMoved(CGPoint(x: 400, y: 180))
    _ = spin(0.05) { false }
    let mark = pv.spawned.count
    _ = spin(0.35) { false }
    let newRings = Array(pv.spawned.suffix(from: min(mark, pv.spawned.count)))
    check(newRings.contains { $0.side == .right && $0.kind == .leave }, "越回后：右卡片在越线点播离开波纹")
    check(newRings.contains { $0.side == .left && $0.kind == .arrive }, "越回后：左卡片播进入波纹")
    check(!newRings.contains { $0.side == .left && $0.kind == .leave }, "越回后：左卡片原来的离开波纹不再出新环")
    check(!newRings.contains { $0.side == .right && $0.kind == .arrive }, "越回后：右卡片原来的进入波纹不再出新环")
    // 从上边出去再从右卡片上边进来：不触发
    pv.pointerExited()
    _ = spin(1.6) { false }
    let before = pv.spawned.count
    pv.pointerMoved(CGPoint(x: 600, y: 2))
    pv.pointerMoved(CGPoint(x: 620, y: 40))
    _ = spin(0.3) { false }
    check(pv.spawned.count == before, "从卡片上边进出：不出环")
    // 总开关关闭：越线不播放
    rippleConfig.enabled = false
    pv.pointerMoved(CGPoint(x: 400, y: 100))
    _ = spin(0.3) { false }
    check(pv.spawned.count == before, "总开关关闭时越线不播放")
    rippleConfig = .defaults
}

// MARK: - bonjour

func bonjourTest() {
    print("== Bonjour 广播与发现（测试服务类型 _mackvmtest._tcp）")
    let inv = PairingInviter(me: devI, advertise: true, serviceType: "_mackvmtest._tcp")
    var problem: String?
    inv.onProblem = { if let p = $0 { problem = p } }
    inv.start()
    let b = BonjourBrowser(type: "_mackvmtest._tcp", label: "测试查找")
    var found: [DiscoveredDevice] = []
    b.onChange = { found = $0 }
    b.onProblem = { if let p = $0 { problem = p } }
    b.start()
    let ok = spin(8) { found.contains { $0.id == devI.id } }
    check(ok, "在局域网里发现了正在邀请的设备\(problem.map { "（问题：\($0)）" } ?? "")")
    if let d = found.first(where: { $0.id == devI.id }) {
        check(d.name == "测试被控", "TXT 里的设备名正确")
        var paired = false
        inv.onPaired = { _ in paired = true }
        var res: Result<PairingResult, PairFailure>?
        PairingSeeker(me: devC).pair(endpoint: d.endpoint, expectedID: d.id, code: inv.code) { res = $0 }
        _ = spin(6) { res != nil && paired }
        if case .success? = res { check(paired, "经 Bonjour 端点完成配对") } else { check(false, "经 Bonjour 端点配对：\(String(describing: res))") }
    }
    inv.stop()
    _ = spin(1.5) { false }
    // 停止广播后应从列表里消失
    let gone = spin(8) { !found.contains { $0.id == devI.id } }
    check(gone, "取消邀请后设备从列表里消失")
    b.stop()
}

// MARK: - 两进程

func procInviter(_ outFile: String) -> Int32 {
    let inv = PairingInviter(me: devI, advertise: false)
    var paired: PairingResult?
    inv.onReady = { p in
        try? "PORT \(p) CODE \(inv.code)\n".write(toFile: outFile, atomically: true, encoding: .utf8)
    }
    inv.onPaired = { paired = $0 }
    inv.start()
    guard spin(30, until: { paired != nil }), let r = paired else { print("被控进程：30 秒内没配对成功"); return 1 }
    print("被控进程：配对成功，对方「\(r.peerName)」，密钥指纹 \(PairingCrypto.fingerprint(r.key))")
    _ = spin(0.5) { false }
    inv.stop()
    let link = Link(me: devI, peerID: r.peerID, key: r.key, lastAddress: nil, port: 24932, peerPort: 24931, useBonjour: false)
    var unpaired = false
    link.onAuthenticated = { _ in print("被控进程：加密连接已通过校验") }
    link.onMessage = { p, t, d in
        switch t {
        case .enter:
            print("被控进程：收到 enter，比例 \(d.readDouble(0) ?? -1)，回 leave")
            p.send(.leave, d)
        case .settings:
            let s = try? JSONDecoder().decode(SharedSettings.self, from: d)
            print("被控进程：收到共享设置，主控 \(s?.controllerID ?? "?")，规则 \(s?.rules.count ?? 0) 条，本机视角：本机屏\(s?.rules.first?.view(from: devI.id)?.localEdge.edgeLabel ?? "?")")
        case .unpair:
            print("被控进程：收到解除配对")
            unpaired = true
        default:
            break
        }
    }
    link.start()
    let ok = spin(20) { unpaired }
    link.stop()
    print(ok ? "被控进程：完成" : "被控进程：20 秒内没收到解除配对")
    return ok ? 0 : 1
}

func procSeeker(_ port: UInt16, _ code: String) -> Int32 {
    let wrong = code == "00000000" ? "11111111" : "00000000"
    let w = pairOnce(port, wrong)
    print("主控进程：先故意输错 → \(String(describing: w))")
    guard fail(w) == (.wrongCode(left: 4)) else { return 1 }
    guard case .success(let r)? = pairOnce(port, code) else { print("主控进程：用正确的码配对失败"); return 1 }
    print("主控进程：配对成功，对方「\(r.peerName)」，密钥指纹 \(PairingCrypto.fingerprint(r.key))")
    let link = Link(me: devC, peerID: r.peerID, key: r.key, lastAddress: r.peerAddress ?? "127.0.0.1",
                    port: 24931, peerPort: 24932, useBonjour: false)
    var up = false
    var echo: Double?
    link.onAuthenticated = { _ in up = true }
    link.onMessage = { _, t, d in if t == .leave { echo = d.readDouble(0) } }
    link.start()
    guard spin(8, until: { up }) else { print("主控进程：加密连接没连上"); return 1 }
    print("主控进程：加密连接已通过校验")
    var d = Data(); d.appendDouble(0.625)
    link.active?.send(.enter, d)
    guard spin(3, until: { echo != nil }), echo == 0.625 else { print("主控进程：没收到回显"); return 1 }
    print("主控进程：收到回显 leave，比例 \(echo!)")
    let s = SharedSettings(revision: 1, editor: devC.id, controllerID: devC.id,
                           rules: [AdjacencyRule(id: "r", aDevice: devC.id, aScreen: "SC", aEdge: .right, bDevice: devI.id,
                                                 bScreen: "SI", offsetMM: 0)],
                           rulesInitialized: true, ripple: .defaults)
    link.active?.send(.settings, try! JSONEncoder().encode(s))
    var sent = false
    link.active?.send(.unpair) { _ in sent = true }
    _ = spin(2) { sent }
    _ = spin(0.5) { false }
    link.stop()
    print("主控进程：完成")
    return 0
}

// MARK: - 入口

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "unit":
    unitTests()
case "loopback":
    loopbackTests()
case "bonjour":
    bonjourTest()
case "preview":
    previewTests()
case "proc-inviter":
    exit(procInviter(args[2]))
case "proc-seeker":
    exit(procSeeker(UInt16(args[2])!, args[3]))
default:
    print("用法：mackvm-test unit | loopback | bonjour | proc-inviter <文件> | proc-seeker <端口> <配对码>")
    exit(2)
}
print("合计 \(checks) 项检查，\(failures) 项失败")
exit(failures == 0 ? 0 : 1)

// 只在构建验证时用的离屏渲染入口（不打进 MacKVM.app）。由 Verify/verify.sh 编译运行。
// 把各个页面和弹窗用 NSHostingView 画到 2x 位图（窗口从不显示到屏幕上，进程激活策略是 prohibited），
// 存成 PNG；有对应设计稿的，再拼一张「左设计稿 / 右实现」的对照图。
// 每张页面都出中文、英文两份（英文的文件名带 -en，语言直接设 LanguageSettings，不经过点击）；
// 另外把菜单栏菜单（01）和 08 的弹窗卡片合集各拼一张，和设计稿对照；07 页再出一张取色器弹出状态（07a），和设计稿对照。
// 06、07 页各出主控视角（底栏没有「重置键鼠状态」按钮）和被控视角（有按钮）两种，按底栏像素检查按钮在不在。
// 用法：mackvm-render <输出目录> <设计稿目录>

import AppKit
import Network
import SwiftUI

let outDir = CommandLine.arguments[1]
let designDir = CommandLine.arguments[2]
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
// 不是 .app，没有 Contents/Resources：程序图标按路径从仓库的 Resources/ 读
AppIcon.resourceDirectory = URL(fileURLWithPath: designDir).deletingLastPathComponent().appendingPathComponent("Resources")

/// 渲染用的示例设备名：中文页沿用原来的示例，英文页用英文设计稿上的名字
struct Names {
    let book: DeviceIdentity        // 我的 MacBook Pro
    let mini: DeviceIdentity        // 书房 Mac mini
    let studioDev: DeviceIdentity   // 06 页：我的 Mac Studio（两块 DELL）
    let bookDev: DeviceIdentity     // 06 页：我的 MacBook Pro（内建屏）
    let pairSelf: DeviceIdentity    // 03 页「本机设备名」
    let pairTarget: DeviceIdentity  // 04 / 05 页查找到的、要配对的那台
    var pairTargetDev: DiscoveredDevice {
        DiscoveredDevice(id: pairTarget.id, name: pairTarget.name,
                         endpoint: .service(name: pairTarget.name, type: kPairServiceType, domain: "local.", interface: nil))
    }

    static func of(_ l: Language) -> Names {
        let en = l == .en
        let book = DeviceIdentity(id: "aaaa-book", name: en ? "My MacBook Pro" : "我的 MacBook Pro", isLaptop: true)
        let mini = DeviceIdentity(id: "bbbb-mini", name: en ? "Study Mac mini" : "书房 Mac mini", isLaptop: false)
        return Names(book: book, mini: mini,
                     studioDev: DeviceIdentity(id: "studio-dev", name: en ? "My Mac Studio" : "我的 Mac Studio", isLaptop: false),
                     bookDev: DeviceIdentity(id: "book-dev", name: en ? "My MacBook Pro" : "我的 MacBook Pro", isLaptop: true),
                     // 英文设计稿 03 / 04 / 05 上的设备都是「My MacBook Pro」；中文页沿用原来的「书房 Mac mini」
                     pairSelf: en ? book : mini,
                     pairTarget: en ? DeviceIdentity(id: "cccc-book", name: "My MacBook Pro", isLaptop: true) : mini)
    }
}

// 作者两台机器的真实屏幕数据（用来渲染界面预览）
let scrU = ScreenInfo(id: "U2720QM", name: "DELL U2720QM", isMain: true, isBuiltin: false,
                      x: 0, y: 0, w: 2560, h: 1440, mmW: 599, mmH: 340, estimated: false)
let scrP = ScreenInfo(id: "P2319H", name: "DELL P2319H", isMain: false, isBuiltin: false,
                      x: 2560, y: 0, w: 1920, h: 1080, mmW: 507, mmH: 288, estimated: false)
let scrB = ScreenInfo(id: "BUILTIN", name: "内建屏幕", isMain: true, isBuiltin: true,
                      x: 0, y: 0, w: 1512, h: 982, mmW: 301, mmH: 195, estimated: false)

func pairedModel(me: DeviceIdentity, peer: DeviceIdentity, controller: Bool, dir: Direction = .right) -> AppModel {
    let m = AppModel(preview: me)
    m.pairing = PairingRecord(peerID: peer.id, peerName: peer.name, peerIsLaptop: peer.isLaptop,
                              keyBase64: Data(count: 32).base64EncodedString(), lastAddress: nil)
    let ctl = controller ? me.id : peer.id
    m.shared = SharedSettings(revision: 1, editor: ctl, controllerID: ctl, ripple: .defaults)
    m.linkStatus = .connected
    return m
}

/// 06 页：本机 Mac Studio（两块 DELL）+ 对方 MacBook。两块 DELL 按 macOS 排列摆，bookAt 是内建屏在布局里的左上角（毫米），
/// 默认是设计稿的摆法：内建屏在 P2319H 下方、中对中。规则从布局推导（和真实拖动放下时一样）
let designBookAt = CGPoint(x: 599 + (507 - 301) / 2, y: 288)
func layoutModel(_ n: Names, asStudio: Bool = true, bookAt: CGPoint = designBookAt) -> AppModel {
    let me = asStudio ? n.studioDev : n.bookDev, peer = asStudio ? n.bookDev : n.studioDev
    let m = pairedModel(me: me, peer: peer, controller: asStudio)
    m.localScreens = asStudio ? [scrU, scrP] : [scrB]
    m.peerScreens = asStudio ? [scrB] : [scrU, scrP]
    for s in [scrU, scrP, scrB] { m.knownScreens[s.id] = s }
    m.shared?.layout = [ScreenSpot(device: n.studioDev.id, screen: "U2720QM", x: 0, y: 0),
                        ScreenSpot(device: n.studioDev.id, screen: "P2319H", x: 599, y: 0),
                        ScreenSpot(device: n.bookDev.id, screen: "BUILTIN", x: bookAt.x, y: bookAt.y)]
    var k = 0
    m.shared?.rules = ScreenLayout.rules(from: m.placedScreens, me: me.id, peer: peer.id, existing: [],
                                         newID: { k += 1; return "rule-\(k)" })
    m.shared?.rulesInitialized = true
    m.peerScreensFresh = true
    return m
}

/// 一张整页渲染。每张都出中文、英文两份（英文的文件名带 -en）；有设计稿的再拼对照图
struct Shot {
    let name: String
    let design: String?         // 中文设计稿节点 ID
    let designEN: String?       // 对应的英文设计稿节点 ID
    let make: (Names) -> AppModel
}

let shots: [Shot] = [
    Shot(name: "02-home", design: "FEbEM", designEN: "p8zNE") { n in AppModel(preview: n.book) },
    Shot(name: "03-invite", design: "iHaq3", designEN: "nqZqO") { n in
        let m = AppModel(preview: n.pairSelf)
        m.inviteCode = "58291604"
        m.dialog = .invite
        return m
    },
    Shot(name: "04-seek", design: "W6X6h", designEN: "sd7Pu") { n in
        let m = AppModel(preview: n.book)
        m.seekDevices = [n.pairTargetDev]
        m.dialog = .seek
        return m
    },
    Shot(name: "05-code", design: "SUPLf", designEN: "dPYOA") { n in
        let m = AppModel(preview: n.book)
        m.codeInput = "58291604"
        m.dialog = .enterCode(n.pairTargetDev)
        return m
    },
    Shot(name: "06-layout", design: "R9pul", designEN: "M2QCS") { n in layoutModel(n) },
    Shot(name: "06-default-layout", design: nil, designEN: nil) { n in layoutModel(n, bookAt: CGPoint(x: 1106, y: 46.5)) },
    // 被控视角（设计稿 06b）：本机是 MacBook，对方两块 DELL 是输入设备，底栏右侧有「重置键鼠状态」
    Shot(name: "06-controlled-view", design: "b4iwvq", designEN: "n04MZ") { n in layoutModel(n, asStudio: false) },
    Shot(name: "06-two-seams", design: nil, designEN: nil) { n in layoutModel(n, bookAt: CGPoint(x: 599, y: 288)) },
    Shot(name: "06-no-crossing", design: nil, designEN: nil) { n in layoutModel(n, bookAt: CGPoint(x: 1106 + 60, y: 46.5)) },
    Shot(name: "06-unplugged", design: nil, designEN: nil) { n in
        let m = layoutModel(n)
        m.localScreens = [scrU]           // P2319H 拔掉了
        return m
    },
    Shot(name: "06-offline", design: nil, designEN: nil) { n in
        let m = layoutModel(n)
        m.linkStatus = .offline
        return m
    },
    Shot(name: "06-new-screen", design: nil, designEN: nil) { n in
        let m = layoutModel(n, bookAt: CGPoint(x: 1106, y: 46.5))
        m.peerScreens.append(ScreenInfo(id: "B2", name: "LG HDR 4K", isMain: false, isBuiltin: false, x: 1512, y: 0,
                                        w: 2560, h: 1440, mmW: 600, mmH: 340, estimated: false))
        return m
    },
    Shot(name: "06-drag-overlap", design: nil, designEN: nil) { n in
        let m = layoutModel(n)
        m.previewDragOverride = ScreenSpot(device: n.bookDev.id, screen: "BUILTIN", x: 900, y: 200)
        return m
    },
    Shot(name: "06-drag-snapped", design: nil, designEN: nil) { n in
        let m = layoutModel(n)
        m.previewDragOverride = ScreenSpot(device: n.bookDev.id, screen: "BUILTIN", x: 1106, y: 46.5)
        return m
    },
    Shot(name: "07-ripple", design: "G2wLHj", designEN: "x9opB") { n in
        let m = pairedModel(me: n.book, peer: n.mini, controller: true)
        m.tab = .ripple
        return m
    },
    // 被控视角的 07 页：设计稿 07（G2wLHj / x9opB）底栏画着「重置键鼠状态」按钮，和这张的底栏一致，也拼一张对照
    Shot(name: "07-ripple-controlled", design: "G2wLHj", designEN: "x9opB") { n in
        let m = pairedModel(me: n.mini, peer: n.book, controller: false)
        m.tab = .ripple
        return m
    },
    // 以下没有一一对应的整页设计稿（08 的弹窗卡片另拼成一张和设计稿对照，见后面），用来人工检查
    Shot(name: "07-ripple-off", design: nil, designEN: nil) { n in
        let m = pairedModel(me: n.book, peer: n.mini, controller: true)
        m.shared?.ripple.enabled = false
        m.tab = .ripple
        return m
    },
    Shot(name: "04-seek-empty", design: nil, designEN: nil) { n in
        let m = AppModel(preview: n.book)
        m.dialog = .seek
        return m
    },
    Shot(name: "05-code-error", design: nil, designEN: nil) { n in
        let m = AppModel(preview: n.book)
        m.codeError = .wrongCode(left: 4)
        m.dialog = .enterCode(n.pairTargetDev)
        return m
    },
    Shot(name: "08-searching", design: nil, designEN: nil) { n in
        let m = pairedModel(me: n.book, peer: n.mini, controller: true)
        m.linkStatus = .searching
        m.dialog = .linkInfo
        return m
    },
    Shot(name: "08-offline", design: nil, designEN: nil) { n in
        let m = pairedModel(me: n.book, peer: n.mini, controller: true)
        m.linkStatus = .offline
        m.dialog = .linkInfo
        return m
    },
    Shot(name: "08-connected", design: nil, designEN: nil) { n in
        let m = pairedModel(me: n.book, peer: n.mini, controller: true)
        m.dialog = .linkInfo
        return m
    },
    Shot(name: "08-no-devices", design: nil, designEN: nil) { n in
        let m = AppModel(preview: n.book)
        m.dialog = .noDevices
        return m
    },
    Shot(name: "08-code-renewed", design: nil, designEN: nil) { n in
        let m = AppModel(preview: n.mini)
        m.inviteCode = "71482056"
        m.inviteRenewed = true
        m.dialog = .codeRenewed
        return m
    },
    Shot(name: "03-invite-renewed", design: nil, designEN: nil) { n in
        let m = AppModel(preview: n.mini)
        m.inviteCode = "71482056"
        m.inviteRenewed = true
        m.dialog = .invite
        return m
    },
    Shot(name: "08-pair-success", design: nil, designEN: nil) { n in
        let m = pairedModel(me: n.mini, peer: n.book, controller: false)
        m.dialog = .pairSuccess
        return m
    },
    Shot(name: "08-unpair-confirm", design: nil, designEN: nil) { n in
        let m = pairedModel(me: n.book, peer: n.mini, controller: true)
        m.dialog = .confirmUnpair
        return m
    },
    Shot(name: "08-swap-confirm", design: nil, designEN: nil) { n in
        let m = pairedModel(me: n.book, peer: n.mini, controller: true)
        m.dialog = .confirmSwap
        return m
    },
    Shot(name: "08-swap-confirm-controlled", design: nil, designEN: nil) { n in
        let m = pairedModel(me: n.mini, peer: n.book, controller: false)
        m.dialog = .confirmSwap
        return m
    },
]

// 离屏自查的计数：设计稿读到没有、对照图出了没有、标题栏按钮点得到没有
var renderChecks = 0
var renderFailures = 0
func check(_ ok: Bool, _ what: String) {
    renderChecks += 1
    if ok { print("  通过  \(what)") } else { renderFailures += 1; print("  失败  \(what)") }
}

/// 设计稿图：优先 v7 的 2 倍图，其次 v7 的 1 倍图，再往前找旧版本
func designImage(_ d: String) -> NSImage? {
    for path in ["v7/2x", "v7", "v6/2x", "v6", "v5/2x", "v4/2x", "v3/2x"] {
        if let img = NSImage(contentsOfFile: "\(designDir)/\(path)/\(d).png") { return img }
    }
    return nil
}

func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

func bitmap(of view: NSView) -> NSBitmapImageRep {
    let size = view.bounds.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// 左设计稿、右实现，拼成一张（设计稿按实现的尺寸缩放）
func sideBySide(_ design: NSImage, _ mine: NSBitmapImageRep, _ path: String) {
    let w = mine.pixelsWide, h = mine.pixelsHigh
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * 2 + 40, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w * 2 + 40, height: h).fill()
    design.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    mine.draw(in: NSRect(x: w + 40, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    save(rep, path)
}

/// 有设计稿的就拼对照图（「-对照.png」）
func compare(_ name: String, _ design: String?, _ rep: NSBitmapImageRep, _ line: inout String) {
    guard let d = design else { return }
    guard let img = designImage(d) else {
        check(false, "\(name)：读到设计稿 \(d)")
        return
    }
    let cmp = "\(outDir)/\(name)-对照.png"
    sideBySide(img, rep, cmp)
    line += "，对照图 \(cmp)"
    check(FileManager.default.fileExists(atPath: cmp), "\(name)：和设计稿 \(d) 拼出对照图")
}

/// 视图里某一点被谁接住（从命中的视图往上数几层）
func hitChain(_ root: NSView, _ p: NSPoint) -> [String] {
    var chain: [String] = []
    var v = root.hitTest(p)
    while let x = v, chain.count < 6 { chain.append(String(describing: type(of: x))); v = x.superview }
    return chain
}

/// 底栏右侧「重置键鼠状态」按钮里的一点（按钮右边离窗口右边 24 点、在 47.5 点高的底栏里垂直居中）是不是按钮的浅蓝底
func footerHasResetButton(_ rep: NSBitmapImageRep) -> Bool {
    let x = Int((kWindowSize.width - 24 - 6) * 2), y = Int((kWindowSize.height - 47.5 / 2) * 2)
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
    // 按钮底色 #DFEAFE；窗口底色 #F7F8FA
    return c.blueComponent - c.redComponent > 0.05
}

/// 视图树里按名字找色样背后的锚点（ColorAnchorView）
func findAnchor(_ v: NSView, _ name: String) -> ColorAnchorView? {
    if let a = v as? ColorAnchorView, a.name == name { return a }
    for sub in v.subviews { if let a = findAnchor(sub, name) { return a } }
    return nil
}

for lang in Language.allCases {
    LanguageSettings.shared.current = lang       // 离屏渲染直接设语言，不经过点击
    let names = Names.of(lang)
    for shot in shots {
        let model = shot.make(names)
        // 真实主窗口（含系统标题栏和红绿灯），只做离屏渲染，从不 orderFront
        let wc = MainWindowController(model: model)
        let frameView = wc.window.contentView!.superview!
        wc.window.layoutIfNeeded()
        pump(0.4)
        frameView.layoutSubtreeIfNeeded()
        pump(0.2)
        let rep = bitmap(of: frameView)
        let name = shot.name + (lang == .en ? "-en" : "")
        let path = "\(outDir)/\(name).png"
        save(rep, path)
        var line = "\(name): \(Int(frameView.bounds.width))×\(Int(frameView.bounds.height)) → \(path)"
        compare(name, lang == .en ? shot.designEN : shot.design, rep, &line)
        print(line)
        if ["06-layout", "06-controlled-view", "07-ripple", "07-ripple-controlled"].contains(shot.name) {
            let want = model.isPaired && !model.isController
            check(footerHasResetButton(rep) == want,
                  "\(name)：本机是\(want ? "被控" : "主控")，底栏\(want ? "有" : "没有")「\(L.resetInput)」按钮")
        }
        if shot.name == "06-layout" {
            // 标题栏右侧的切换按钮、语言开关能不能点到：看那一点被谁接住（不能是系统标题栏 / 工具栏）
            let tabChain = hitChain(frameView, NSPoint(x: lang == .en ? 700 : 750, y: kWindowSize.height - 27))
            print("标题栏切换按钮处的命中视图链：\(tabChain.joined(separator: " ← "))")
            check(tabChain.contains { $0.contains("Hosting") }, "\(name)：标题栏「\(L.tabRipple)」按钮由界面接住")
            let langChain = hitChain(frameView, NSPoint(x: 862, y: kWindowSize.height - 27))
            print("标题栏语言开关处的命中视图链：\(langChain.joined(separator: " ← "))")
            check(langChain.contains { $0.contains("Hosting") }, "\(name)：标题栏语言开关由界面接住")
        }
        wc.window.close()
    }
}

// MARK: - 01 菜单栏菜单

/// 把菜单栏菜单的内容画成一张图：真实的 StatusMenuContent（同一份菜单项、同一个「语言」行视图），
/// 按设计稿 01 的位置画在一块浅色底上。NSMenu 本身不能离屏画，这里按菜单项逐行画文字，只用来核对文案和语言开关
final class MenuSnapshotView: NSView {
    let content: StatusMenuContent
    let panel: NSRect
    init(content: StatusMenuContent, size: NSSize, panelOrigin: NSPoint, panelWidth: CGFloat) {
        self.content = content
        var h: CGFloat = 12
        for i in content.menu.items where !i.isHidden { h += Self.rowHeight(i) }
        panel = NSRect(x: panelOrigin.x, y: panelOrigin.y, width: panelWidth, height: h + 10)
        super.init(frame: NSRect(origin: .zero, size: size))
        appearance = NSAppearance(named: .aqua)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static func rowHeight(_ i: NSMenuItem) -> CGFloat {
        if i.isSeparatorItem { return 13 }
        if let v = i.view { return v.frame.height }
        return 28
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 237 / 255.0, green: 241 / 255.0, blue: 247 / 255.0, alpha: 1).setFill()
        bounds.fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10).fill()
        NSColor(white: 0, alpha: 0.08).setStroke()
        NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
        var y = panel.minY + 12
        let x = panel.minX + 18
        for i in content.menu.items where !i.isHidden {
            let h = Self.rowHeight(i)
            if i.isSeparatorItem {
                NSColor(white: 0, alpha: 0.1).setFill()
                NSRect(x: x, y: y + 6, width: panel.width - 36, height: 1).fill()
            } else if let v = i.view {
                // 「语言」一行是真实的视图（菜单里用的同一个）：按菜单宽度让它自己画一张，再贴到这一行
                v.setFrameSize(NSSize(width: panel.width - 8, height: v.frame.height))
                // 菜单项视图不是这张图的子视图，不继承浅色外观：系统是深色模式时 labelColor 会画成白字，这里固定浅色（菜单设计稿是浅色）
                v.appearance = NSAppearance(named: .aqua)
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    rep.draw(in: NSRect(x: panel.minX + 4, y: y, width: v.bounds.width, height: v.bounds.height), from: .zero,
                             operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            } else {
                let t: NSAttributedString = i.attributedTitle ?? NSAttributedString(string: i.title, attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: i.isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                ])
                t.draw(at: NSPoint(x: x, y: y + (h - t.size().height) / 2))
                if !i.keyEquivalent.isEmpty {
                    let m = i.keyEquivalentModifierMask
                    let keys = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
                        + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + i.keyEquivalent.uppercased()
                    let k = NSAttributedString(string: keys, attributes: [
                        .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
                    ])
                    k.draw(at: NSPoint(x: panel.maxX - 18 - k.size().width, y: y + (h - k.size().height) / 2))
                }
            }
            y += h
        }
    }
}

for lang in Language.allCases {
    LanguageSettings.shared.current = lang
    let n = Names.of(lang)
    // 设计稿 01：已连接、本机是主控（没有「重置键鼠状态」一行）；被控视角没有单独的稿，另出一张人工检查
    for controller in [true, false] {
        let model = controller ? pairedModel(me: n.mini, peer: n.book, controller: true)
                               : pairedModel(me: n.book, peer: n.mini, controller: false)
        let content = StatusMenuContent(model: model)
        let v = MenuSnapshotView(content: content, size: kWindowSize, panelOrigin: NSPoint(x: 551, y: 41), panelWidth: 328)
        v.layoutSubtreeIfNeeded()
        let rep = bitmap(of: v)
        let name = "01-menu" + (controller ? "" : "-controlled") + (lang == .en ? "-en" : "")
        let path = "\(outDir)/\(name).png"
        save(rep, path)
        let visible = content.menu.items.filter { !$0.isHidden }
        let titles = visible.map { i -> String in
            if let r = i.view as? ResetMenuRow { return "[\(r.title) \(L.resetHotkey)]" }
            return i.view != nil ? "[语言行]" : (i.isSeparatorItem ? "——" : i.title)
        }
        var line = "\(name): 菜单项 \(titles.joined(separator: " / ")) → \(path)"
        if controller { compare(name, lang == .en ? "baDOw" : "rtbYh", rep, &line) }
        print(line)
        let hasReset = visible.contains { $0.view is ResetMenuRow }
        check(hasReset == !controller, "\(name)：本机是\(controller ? "主控" : "被控")，菜单里\(controller ? "没有" : "有")「\(L.resetInput)」一行")
        check(visible.contains { $0.title == L.menuOpen }, "\(name)：菜单里有「\(L.menuOpen)」")
    }
}

// MARK: - 08 状态弹窗合集

/// 设计稿 08 是一张合集：标题、说明，下面两列共 7 张弹窗卡片 + 1 张「页内状态」说明卡。
/// 这里用真实的弹窗视图（每张一个独立的 AppModel）按同样的位置拼出来；标题、说明和最后那张说明卡是设计稿自己的注释，不是界面
struct DialogSheet: View {
    let lang: Language
    let cells: [(AppModel, Dialog)]

    var body: some View {
        let en = lang == .en
        VStack(alignment: .leading, spacing: 0) {
            // 和设计稿一样的位置：标题顶在 28，卡片从 109（英文）/ 117（中文）开始
            Text(en ? "Status details and confirmations" : "状态说明与操作确认")
                .font(.ui(22, .semibold)).foregroundStyle(Theme.text)
                .frame(height: 30, alignment: .leading)
                .padding(.top, 28)
            Text(en ? "Connection details open only when clicked. Turning effects off updates the page without a dialog."
                    : "连接状态仅点击标签后显示说明，不自动弹出；关闭光标特效仅更新页内状态，不弹窗。")
                .font(.ui(11)).foregroundStyle(Theme.sub)
                .frame(height: 16, alignment: .leading)
                .padding(.top, en ? 17 : 21)
            Spacer().frame(height: en ? 18 : 22)
            Grid(horizontalSpacing: 16, verticalSpacing: 18) {
                ForEach(0..<4, id: \.self) { r in
                    GridRow {
                        ForEach(0..<2, id: \.self) { c in
                            let k = r * 2 + c
                            if k < cells.count {
                                dialog(cells[k].1).environmentObject(cells[k].0)
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(en ? "Inline state: effects are off" : "页内状态：光标特效关闭")
                                        .font(.ui(15, .medium)).foregroundStyle(Theme.text)
                                    Text(en ? "Design note, not part of the interface. See the 07-ripple-off render."
                                            : "设计稿的说明卡，不是界面。实际效果见 07-ripple-off 渲染图。")
                                        .font(.ui(12)).foregroundStyle(Theme.sub)
                                }
                                .padding(18)
                                .frame(width: 414, height: 246, alignment: .topLeading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xE9EDF5)))
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(width: 900, height: en ? 1174 : 1182, alignment: .topLeading)
        .background(Color(hex: 0xF0F2F6))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func dialog(_ d: Dialog) -> some View {
        switch d {
        case .linkInfo: LinkInfoDialog()
        case .noDevices: NoDevicesDialog()
        case .codeRenewed: CodeRenewedDialog()
        case .pairSuccess: PairSuccessDialog()
        case .confirmUnpair: UnpairConfirmDialog()
        case .confirmSwap: SwapConfirmDialog()
        default: EmptyView()
        }
    }
}

for lang in Language.allCases {
    LanguageSettings.shared.current = lang
    let n = Names.of(lang)
    func paired(_ status: LinkStatus) -> AppModel {
        let m = pairedModel(me: n.book, peer: n.mini, controller: true)
        m.linkStatus = status
        return m
    }
    let renewed = AppModel(preview: n.mini)
    renewed.inviteCode = "71482056"
    let cells: [(AppModel, Dialog)] = [
        (paired(.searching), .linkInfo),
        (paired(.offline), .linkInfo),
        (AppModel(preview: n.book), .noDevices),
        (renewed, .codeRenewed),
        (pairedModel(me: n.mini, peer: n.book, controller: false), .pairSuccess),
        (paired(.connected), .confirmUnpair),
        (paired(.connected), .confirmSwap),
    ]
    let host = NSHostingView(rootView: DialogSheet(lang: lang, cells: cells))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: lang == .en ? 1174 : 1182)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    win.contentView = host
    host.layoutSubtreeIfNeeded()
    pump(0.4)
    let rep = bitmap(of: host)
    let name = "08-dialogs" + (lang == .en ? "-en" : "")
    let path = "\(outDir)/\(name).png"
    save(rep, path)
    var line = "\(name): \(Int(host.bounds.width))×\(Int(host.bounds.height)) → \(path)"
    compare(name, lang == .en ? "x60dhN" : "tBejx", rep, &line)
    print(line)
    win.close()
}
LanguageSettings.shared.current = .zh

// 07 卡片预览（中文）：用代码驱动鼠标从左卡片越线到右卡片，再在右卡片里移动。
// 离屏渲染画不出 Core Animation 的中间帧，所以让卡片图层把环直接定格在 40% 进度（不加动画），检查裁剪和圆心位置。
do {
    let n = Names.of(.zh)
    let model = pairedModel(me: n.book, peer: n.mini, controller: true)
    model.tab = .ripple
    rippleConfig = model.ripple
    let wc = MainWindowController(model: model)
    let frameView = wc.window.contentView!.superview!
    wc.window.layoutIfNeeded()
    pump(0.5)
    let pv = model.ripplePreview
    RingHostView.frozenProgress = 0.4
    print("预览布局：卡片宽 \(pv.tracker.cardWidth)，空隙 \(pv.tracker.gap)，高 \(pv.tracker.height)，分界线 x = \(pv.tracker.midX)")
    pv.pointerMoved(CGPoint(x: 380, y: 170))
    pv.pointerMoved(CGPoint(x: 432, y: 172))     // 越线
    pump(0.25)
    pv.pointerMoved(CGPoint(x: 560, y: 260))     // 进入后在右卡片里移动
    pump(0.35)
    frameView.layoutSubtreeIfNeeded()
    let rep = bitmap(of: frameView)
    save(rep, "\(outDir)/07-preview-frozen.png")
    print("07-preview-frozen：出环命令 \(pv.spawned.count) 条（左 \(pv.spawned.filter { $0.side == .left }.count)、右 \(pv.spawned.filter { $0.side == .right }.count)） → \(outDir)/07-preview-frozen.png")
    RingHostView.frozenProgress = nil
    wc.window.close()
}

// MARK: - 07a 取色器弹出状态

// 07 页（中文、默认颜色）上，把「离开波纹」第一个色样标成正在编辑，再把取色器内容（真实的 ColorPickerView）单独画出来，
// 按 NSPopover 的样子（白底、浅灰描边、阴影、尖角指向色样，水平居中于色样、不超出窗口）拼到这张页面上，和设计稿 zkCeP 对照。
// NSPopover 本身是独立窗口、离屏画不出来，所以浮窗外框是这里照着画的；里面的内容是真实视图。
do {
    LanguageSettings.shared.current = .zh
    let n = Names.of(.zh)
    let model = pairedModel(me: n.book, peer: n.mini, controller: true)
    model.tab = .ripple
    let target = ColorEditTarget(group: \.leaveColors, index: 0)
    let hex = model.ripple.leaveColors[0]
    ColorPopoverController.shared.previewEditing(target, hex: hex, canDelete: model.ripple.leaveColors.count > 1)
    let wc = MainWindowController(model: model)
    let frameView = wc.window.contentView!.superview!
    wc.window.layoutIfNeeded()
    pump(0.4)
    frameView.layoutSubtreeIfNeeded()
    pump(0.2)
    let page = bitmap(of: frameView)
    let anchor = findAnchor(frameView, "leave-0")
    check(anchor != nil, "07a：找到「离开波纹」第一个色样的锚点")
    let a = anchor.map { $0.convert($0.bounds, to: frameView) } ?? NSRect(x: 183, y: 180, width: 18, height: 20)

    // 取色器内容单独画一张
    let size = ColorPopoverController.contentSize
    let host = NSHostingView(rootView: ColorPickerView(model: ColorPopoverController.shared.picker))
    host.frame = NSRect(origin: .zero, size: size)
    let pwin = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    pwin.contentView = host
    host.layoutSubtreeIfNeeded()
    pump(0.3)
    let content = bitmap(of: host)
    save(content, "\(outDir)/07a-picker-content.png")
    check(Int(content.size.width) == 190 && Int(content.size.height) == 159, "07a：取色器主体 190 × 159 点")

    // 拼图：浮窗在色样上方，尖角朝下指向色样中点；水平居中于色样，左右各留 8 点不超出窗口
    let arrowH: CGFloat = 8, arrowW: CGFloat = 16
    let bodyX = min(max(a.midX - size.width / 2, 8), kWindowSize.width - 8 - size.width)
    let body = NSRect(x: bodyX, y: a.maxY + 1 + arrowH, width: size.width, height: size.height)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: page.pixelsWide, pixelsHigh: page.pixelsHigh,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = page.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    page.draw(in: NSRect(origin: .zero, size: page.size))
    let shape = NSBezierPath(roundedRect: body, xRadius: 10, yRadius: 10)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: a.midX - arrowW / 2, y: body.minY + 0.5))
    arrow.line(to: NSPoint(x: a.midX, y: body.minY - arrowH))
    arrow.line(to: NSPoint(x: a.midX + arrowW / 2, y: body.minY + 0.5))
    arrow.close()
    shape.append(arrow)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.12)
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    shadow.set()
    NSColor.white.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0xD4 / 255.0, green: 0xDC / 255.0, blue: 0xE6 / 255.0, alpha: 1).setStroke()
    shape.lineWidth = 1
    shape.stroke()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).addClip()
    content.draw(in: body)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    let path = "\(outDir)/07a-color-picker.png"
    save(out, path)
    var line = "07a-color-picker: 色样 (\(Int(a.minX)), \(Int(kWindowSize.height - a.maxY))) \(Int(a.width))×\(Int(a.height))，浮窗左上 (\(Int(body.minX)), \(Int(kWindowSize.height - body.maxY))) → \(path)"
    compare("07a-color-picker", "zkCeP", out, &line)
    print(line)
    check(body.minX >= 0 && body.maxX <= kWindowSize.width && body.maxY <= kWindowSize.height - 54, "07a：浮窗在窗口内容区里，不超出窗口")
    check(ColorPopoverController.shared.picker.hexText == hex && hex == "#FFFFFF", "07a：取色器的 HEX 显示正在编辑的颜色 #FFFFFF")
    check(ColorPopoverController.shared.picker.canDelete, "07a：离开波纹有两个颜色，HEX 右边的删除按钮可点（红色图标）")
    ColorPopoverController.shared.editing = nil
    pwin.close()
    wc.window.close()
}

// 程序图标：读到的是矢量还是位图；再把菜单栏用的 24 点图标按模板图分别画在浅色、深色底上（2x），检查透明和反白
if let icon = AppIcon.image(points: 24) {
    print("程序图标：\(icon.representations.map { String(describing: type(of: $0)) }.joined(separator: "、"))，模板图 \(icon.isTemplate)")
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4 * 24 * 2, pixelsHigh: 2 * 24 * 2, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 4 * 24, height: 2 * 24)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (i, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.15, alpha: 1), NSColor.white)].enumerated() {
        let cell = NSRect(x: Double(i) * 48, y: 0, width: 48, height: 48)
        bg.setFill()
        cell.fill()
        // 模板图按「只用透明度」着色：先画图标当遮罩，再用前景色填
        let tinted = NSImage(size: icon.size, flipped: false) { r in
            icon.draw(in: r)
            fg.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: cell.minX + 12, y: 12, width: 24, height: 24))
    }
    NSGraphicsContext.restoreGraphicsState()
    save(rep, "\(outDir)/icon-menubar.png")
    print("菜单栏图标（浅色、深色菜单栏）→ \(outDir)/icon-menubar.png")
} else {
    print("程序图标：没读到（\(AppIcon.resourceDirectory?.path ?? "没有资源目录")）")
}

print("合计 \(renderChecks) 项检查，\(renderFailures) 项失败")
print("完成")
exit(renderFailures == 0 ? 0 : 1)

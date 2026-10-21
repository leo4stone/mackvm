// 只在构建验证时用的离屏渲染入口（不打进 MacKVM.app）。由 Verify/verify.sh 编译运行。
// 把各个页面和弹窗用 NSHostingView 画到 2x 位图（窗口从不显示到屏幕上，进程激活策略是 prohibited），
// 存成 PNG；有对应设计稿的，再拼一张「左设计稿 / 右实现」的对照图。
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

let book = DeviceIdentity(id: "aaaa-book", name: "我的 MacBook Pro", isLaptop: true)
let mini = DeviceIdentity(id: "bbbb-mini", name: "书房 Mac mini", isLaptop: false)
let miniDev = DiscoveredDevice(id: mini.id, name: mini.name,
                               endpoint: .service(name: mini.name, type: kPairServiceType, domain: "local.", interface: nil))

// 作者两台机器的真实屏幕数据（用来渲染界面预览）
let studioDev = DeviceIdentity(id: "studio-dev", name: "我的 Mac Studio", isLaptop: false)
let bookDev = DeviceIdentity(id: "book-dev", name: "我的 MacBook Pro", isLaptop: true)
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
func layoutModel(asStudio: Bool = true, bookAt: CGPoint = designBookAt) -> AppModel {
    let me = asStudio ? studioDev : bookDev, peer = asStudio ? bookDev : studioDev
    let m = pairedModel(me: me, peer: peer, controller: asStudio)
    m.localScreens = asStudio ? [scrU, scrP] : [scrB]
    m.peerScreens = asStudio ? [scrB] : [scrU, scrP]
    for s in [scrU, scrP, scrB] { m.knownScreens[s.id] = s }
    m.shared?.layout = [ScreenSpot(device: studioDev.id, screen: "U2720QM", x: 0, y: 0),
                        ScreenSpot(device: studioDev.id, screen: "P2319H", x: 599, y: 0),
                        ScreenSpot(device: bookDev.id, screen: "BUILTIN", x: bookAt.x, y: bookAt.y)]
    var n = 0
    m.shared?.rules = ScreenLayout.rules(from: m.placedScreens, me: me.id, peer: peer.id, existing: [],
                                         newID: { n += 1; return "rule-\(n)" })
    m.shared?.rulesInitialized = true
    m.peerScreensFresh = true
    return m
}

struct Shot {
    let name: String
    let design: String?
    let make: () -> AppModel
}

let shots: [Shot] = [
    Shot(name: "02-home", design: "FEbEM") { AppModel(preview: book) },
    Shot(name: "03-invite", design: "iHaq3") {
        let m = AppModel(preview: mini)
        m.inviteCode = "58291604"
        m.dialog = .invite
        return m
    },
    Shot(name: "04-seek", design: "W6X6h") {
        let m = AppModel(preview: book)
        m.seekDevices = [miniDev]
        m.dialog = .seek
        return m
    },
    Shot(name: "05-code", design: "SUPLf") {
        let m = AppModel(preview: book)
        m.codeInput = "58291604"
        m.dialog = .enterCode(miniDev)
        return m
    },
    Shot(name: "06-layout", design: "R9pul") { layoutModel() },
    Shot(name: "06-default-layout", design: nil) { layoutModel(bookAt: CGPoint(x: 1106, y: 46.5)) },
    Shot(name: "06-controlled-view", design: nil) { layoutModel(asStudio: false) },
    Shot(name: "06-two-seams", design: nil) { layoutModel(bookAt: CGPoint(x: 599, y: 288)) },
    Shot(name: "06-no-crossing", design: nil) { layoutModel(bookAt: CGPoint(x: 1106 + 60, y: 46.5)) },
    Shot(name: "06-unplugged", design: nil) {
        let m = layoutModel()
        m.localScreens = [scrU]           // P2319H 拔掉了
        return m
    },
    Shot(name: "06-offline", design: nil) {
        let m = layoutModel()
        m.linkStatus = .offline
        return m
    },
    Shot(name: "06-new-screen", design: nil) {
        let m = layoutModel(bookAt: CGPoint(x: 1106, y: 46.5))
        m.peerScreens.append(ScreenInfo(id: "B2", name: "LG HDR 4K", isMain: false, isBuiltin: false, x: 1512, y: 0,
                                        w: 2560, h: 1440, mmW: 600, mmH: 340, estimated: false))
        return m
    },
    Shot(name: "06-drag-overlap", design: nil) {
        let m = layoutModel()
        m.previewDragOverride = ScreenSpot(device: bookDev.id, screen: "BUILTIN", x: 900, y: 200)
        return m
    },
    Shot(name: "06-drag-snapped", design: nil) {
        let m = layoutModel()
        m.previewDragOverride = ScreenSpot(device: bookDev.id, screen: "BUILTIN", x: 1106, y: 46.5)
        return m
    },
    Shot(name: "07-ripple", design: "G2wLHj") {
        let m = pairedModel(me: book, peer: mini, controller: true)
        m.tab = .ripple
        return m
    },
    // 以下没有一一对应的整页设计稿（08 只画了弹窗卡片），用来人工检查
    Shot(name: "07-ripple-off", design: nil) {
        let m = pairedModel(me: book, peer: mini, controller: true)
        m.shared?.ripple.enabled = false
        m.tab = .ripple
        return m
    },
    Shot(name: "04-seek-empty", design: nil) {
        let m = AppModel(preview: book)
        m.dialog = .seek
        return m
    },
    Shot(name: "05-code-error", design: nil) {
        let m = AppModel(preview: book)
        m.codeError = "配对码不正确，请重新输入（还可再试 4 次）"
        m.dialog = .enterCode(miniDev)
        return m
    },
    Shot(name: "08-searching", design: nil) {
        let m = pairedModel(me: book, peer: mini, controller: true)
        m.linkStatus = .searching
        m.dialog = .linkInfo
        return m
    },
    Shot(name: "08-offline", design: nil) {
        let m = pairedModel(me: book, peer: mini, controller: true)
        m.linkStatus = .offline
        m.dialog = .linkInfo
        return m
    },
    Shot(name: "08-connected", design: nil) {
        let m = pairedModel(me: book, peer: mini, controller: true)
        m.dialog = .linkInfo
        return m
    },
    Shot(name: "08-no-devices", design: nil) {
        let m = AppModel(preview: book)
        m.dialog = .noDevices
        return m
    },
    Shot(name: "08-code-renewed", design: nil) {
        let m = AppModel(preview: mini)
        m.inviteCode = "71482056"
        m.inviteRenewed = true
        m.dialog = .codeRenewed
        return m
    },
    Shot(name: "03-invite-renewed", design: nil) {
        let m = AppModel(preview: mini)
        m.inviteCode = "71482056"
        m.inviteRenewed = true
        m.dialog = .invite
        return m
    },
    Shot(name: "08-pair-success", design: nil) {
        let m = pairedModel(me: mini, peer: book, controller: false)
        m.dialog = .pairSuccess
        return m
    },
    Shot(name: "08-unpair-confirm", design: nil) {
        let m = pairedModel(me: book, peer: mini, controller: true)
        m.dialog = .confirmUnpair
        return m
    },
    Shot(name: "08-swap-confirm", design: nil) {
        let m = pairedModel(me: book, peer: mini, controller: true)
        m.dialog = .confirmSwap
        return m
    },
    Shot(name: "08-swap-confirm-controlled", design: nil) {
        let m = pairedModel(me: mini, peer: book, controller: false)
        m.dialog = .confirmSwap
        return m
    },
]

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

/// 左设计稿、右实现，拼成一张
func sideBySide(_ design: NSImage, _ mine: NSBitmapImageRep, _ path: String) {
    let w = Int(kWindowSize.width * 2), h = Int(kWindowSize.height * 2)
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

for shot in shots {
    let model = shot.make()
    // 真实主窗口（含系统标题栏和红绿灯），只做离屏渲染，从不 orderFront
    let wc = MainWindowController(model: model)
    let frameView = wc.window.contentView!.superview!
    wc.window.layoutIfNeeded()
    pump(0.4)
    frameView.layoutSubtreeIfNeeded()
    pump(0.2)
    let rep = bitmap(of: frameView)
    let path = "\(outDir)/\(shot.name).png"
    save(rep, path)
    var line = "\(shot.name): \(Int(frameView.bounds.width))×\(Int(frameView.bounds.height)) → \(path)"
    if let d = shot.design, let img = NSImage(contentsOfFile: "\(designDir)/v6/2x/\(d).png")
        ?? NSImage(contentsOfFile: "\(designDir)/v5/2x/\(d).png")
        ?? NSImage(contentsOfFile: "\(designDir)/v4/2x/\(d).png")
        ?? NSImage(contentsOfFile: "\(designDir)/v3/2x/\(d).png") {
        let cmp = "\(outDir)/\(shot.name)-对照.png"
        sideBySide(img, rep, cmp)
        line += "，对照图 \(cmp)"
    }
    print(line)
    if shot.name == "06-layout" {
        // 标题栏右侧的切换按钮能不能点到：看「光标特效」那一点被谁接住（不能是系统标题栏 / 工具栏）
        let hit = frameView.hitTest(NSPoint(x: 836, y: kWindowSize.height - 27))
        var chain: [String] = []
        var v = hit
        while let x = v, chain.count < 6 { chain.append(String(describing: type(of: x))); v = x.superview }
        print("标题栏切换按钮处的命中视图链：\(chain.joined(separator: " ← "))")
    }
    wc.window.close()
}
// 07 卡片预览：用代码驱动鼠标从左卡片越线到右卡片，再在右卡片里移动。
// 离屏渲染画不出 Core Animation 的中间帧，所以让卡片图层把环直接定格在 40% 进度（不加动画），检查裁剪和圆心位置。
do {
    let model = pairedModel(me: book, peer: mini, controller: true)
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

print("完成")
exit(0)

// 菜单栏图标和它的下拉菜单（设计稿 01）：
//   MacKVM / 连接状态 · 对方名 / 本机角色 / —— / 打开 MacKVM… / 收回光标 ⌃⌥⌘L / 语言 [中文 | EN] / 退出 MacKVM
// 菜单项只建一次，每次菜单要弹出时、界面语言变化时按 AppModel 的当前状态就地更新文字和显隐。
// 「收回光标」只在主控方可用，被控方和未配对时灰掉。「语言」一行是自绘视图，点「中文 / EN」立即切换，菜单不收起。
// 菜单内容（StatusMenuContent）和菜单栏图标（StatusMenu）分开：离屏渲染只建菜单内容，不往菜单栏里放图标。

import AppKit
import Combine

final class StatusMenu: NSObject {
    let item: NSStatusItem
    let content: StatusMenuContent

    init(model: AppModel) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        content = StatusMenuContent(model: model)
        super.init()
        if let b = item.button {
            // 程序图标 24×24 点、模板图（深色菜单栏自动反白）；资源缺失时退回系统的键盘符号，菜单栏不至于空着
            let img = AppIcon.image(points: 24) ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MacKVM")
            img?.isTemplate = true
            b.image = img
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = "MacKVM"
        }
        item.menu = content.menu
    }
}

final class StatusMenuContent: NSObject, NSMenuDelegate {
    let model: AppModel
    let menu = NSMenu()
    private let header = NSMenuItem()
    private let status = NSMenuItem()
    private let role = NSMenuItem()
    private let open = NSMenuItem()
    private let release = NSMenuItem()
    private let language = NSMenuItem()
    private let languageRow = LanguageMenuRow(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
    private let quit = NSMenuItem()
    private var languageSub: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        for i in [header, status, role] { i.isEnabled = false }

        open.action = #selector(openWindow)
        open.target = self
        release.action = #selector(releaseCursor)
        release.keyEquivalent = "l"
        release.keyEquivalentModifierMask = [.control, .option, .command]
        release.target = self
        languageRow.autoresizingMask = [.width]
        languageRow.onSelect = { [weak self] l in
            self?.model.setLanguage(l)
            self?.update()
        }
        language.view = languageRow
        quit.action = #selector(quitApp)
        quit.target = self

        for i in [header, status, role, .separator(), open, release, language, quit] { menu.addItem(i) }
        update()
        // 从主窗口标题栏切语言时（菜单可能正开着）跟着更新；@Published 在赋值前发出，等这一轮走完再读新语言
        languageSub = LanguageSettings.shared.$current.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { update() }

    private func styled(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
    }

    private func setInfo(_ i: NSMenuItem, _ a: NSAttributedString) {
        i.title = a.string
        i.attributedTitle = a
    }

    /// 按当前状态和语言更新全部菜单项
    func update() {
        setInfo(header, styled("MacKVM", size: 14, weight: .semibold, color: .labelColor))
        if model.isPaired {
            let color: NSColor
            switch model.linkStatus {
            case .connected: color = NSColor(srgbRed: 0x24 / 255.0, green: 0x84 / 255.0, blue: 0x51 / 255.0, alpha: 1)
            case .searching: color = NSColor(srgbRed: 0x9B / 255.0, green: 0x69 / 255.0, blue: 0x17 / 255.0, alpha: 1)
            case .offline: color = .secondaryLabelColor
            }
            setInfo(status, styled(L.menuStatus(model.linkStatus, peer: model.peerName), size: 13, color: color))
            setInfo(role, styled(L.roleLine(controller: model.isController), size: 12, color: .secondaryLabelColor))
            role.isHidden = false
        } else {
            setInfo(status, styled(L.menuUnpaired, size: 13, color: .secondaryLabelColor))
            role.isHidden = true
        }
        open.title = L.menuOpen
        release.title = L.menuRelease
        release.isEnabled = model.isPaired && model.isController
        languageRow.title = L.menuLanguage
        languageRow.current = L.lang
        quit.title = L.menuQuit
    }

    @objc private func openWindow() { model.showWindowHandler?() }
    @objc private func releaseCursor() { model.releaseCursor() }
    @objc private func quitApp() { model.quit() }
}

/// 菜单里「语言」一行：左边是文字，右边是和标题栏同款的「中文 / EN」开关（灰底胶囊，当前语言那段白底加粗）。
/// 菜单里放 SwiftUI 按钮不可靠，这里用 AppKit 自己画、自己处理点按
final class LanguageMenuRow: NSView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var current: Language = .zh { didSet { if current != oldValue { needsDisplay = true } } }
    var onSelect: ((Language) -> Void)?

    private static let inset: CGFloat = 14         // 文字和开关离菜单左右边的距离（和普通菜单项的文字对齐）
    private static let pillSize = NSSize(width: 72, height: 26)
    private static let zhWidth: CGFloat = 37       // 「中文」那段的宽度，剩下的给「EN」

    override var isFlipped: Bool { true }

    private var pillRect: NSRect {
        let s = Self.pillSize
        return NSRect(x: bounds.maxX - Self.inset - s.width, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    private func segmentRect(_ l: Language) -> NSRect {
        let p = pillRect.insetBy(dx: 3, dy: 3)
        return l == .zh ? NSRect(x: p.minX, y: p.minY, width: Self.zhWidth, height: p.height)
                        : NSRect(x: p.minX + Self.zhWidth, y: p.minY, width: p.width - Self.zhWidth, height: p.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let label = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor,
        ])
        let ls = label.size()
        label.draw(at: NSPoint(x: Self.inset, y: (bounds.height - ls.height) / 2))

        NSColor(srgbRed: 0xE5 / 255.0, green: 0xE9 / 255.0, blue: 0xF0 / 255.0, alpha: 1).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 7, yRadius: 7).fill()
        for (l, text) in [(Language.zh, L.languageZh), (.en, L.languageEn)] {
            let r = segmentRect(l)
            let on = l == current
            if on {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            let color = on ? NSColor(srgbRed: 0x20 / 255.0, green: 0x26 / 255.0, blue: 0x32 / 255.0, alpha: 1)
                           : NSColor(srgbRed: 0x6B / 255.0, green: 0x74 / 255.0, blue: 0x82 / 255.0, alpha: 1)
            let t = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: on ? .semibold : .regular),
                .foregroundColor: color,
            ])
            let ts = t.size()
            t.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for l in Language.allCases where segmentRect(l).insetBy(dx: -2, dy: -3).contains(p) {
            if l != current { onSelect?(l) }
            return
        }
    }
}

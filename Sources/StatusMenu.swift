// 菜单栏图标和它的菜单（设计稿 01）：
//   左键点图标 = 打开主窗口（已开着就拉到最前并激活本应用），不弹菜单；右键或 Control + 左键 = 弹出菜单。
//   菜单：MacKVM / 连接状态 · 对方名 / 本机角色 / —— / 打开 MacKVM 主界面 / [重置键鼠状态 ⌃⌥⌘L] / 语言 [中文 | EN] / 退出 MacKVM
// 菜单项只建一次，每次菜单要弹出时、界面语言变化时按 AppModel 的当前状态就地更新文字和显隐。
// 「重置键鼠状态」一行只在本机是被控且已连接时显示（主控那台用不上，隐藏）；它和「语言」一行都是自绘视图：
// 「重置键鼠状态」是蓝框按钮，点了执行并收起菜单；点「中文 / EN」立即切换，菜单不收起。
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
            // 不设 item.menu：左右键都走这里，按事件决定开窗口还是弹菜单
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        content.onClose = { [weak self] in self?.item.button?.highlight(false) }
    }

    /// 右键、或按住 Control 的左键：弹菜单；其余左键：打开主窗口
    static func wantsMenu(type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseUp || type == .rightMouseDown || modifiers.contains(.control)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if Self.wantsMenu(type: e?.type, modifiers: e?.modifierFlags ?? []) {
            popUpMenu()
        } else {
            content.model.showWindowHandler?()
        }
    }

    /// 在图标正下方弹出菜单，菜单开着时图标保持按下的高亮。popUp 会一直等到菜单收起才返回
    private func popUpMenu() {
        guard let b = item.button else { return }
        content.update()
        b.highlight(true)
        let p = NSPoint(x: 0, y: b.isFlipped ? b.bounds.maxY + 5 : -5)
        content.menu.popUp(positioning: nil, at: p, in: b)
        b.highlight(false)
    }
}

final class StatusMenuContent: NSObject, NSMenuDelegate {
    let model: AppModel
    let menu = NSMenu()
    /// 菜单收起时调用（菜单栏图标据此取消高亮）
    var onClose: (() -> Void)?
    private let header = NSMenuItem()
    private let status = NSMenuItem()
    private let role = NSMenuItem()
    private let open = NSMenuItem()
    private let reset = NSMenuItem()
    private let resetRow = ResetMenuRow(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
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
        resetRow.autoresizingMask = [.width]
        resetRow.onClick = { [weak self] in self?.model.resetInputState(from: "菜单栏菜单") }
        reset.view = resetRow
        languageRow.autoresizingMask = [.width]
        languageRow.onSelect = { [weak self] l in
            self?.model.setLanguage(l)
            self?.update()
        }
        language.view = languageRow
        quit.action = #selector(quitApp)
        quit.target = self

        for i in [header, status, role, .separator(), open, reset, language, quit] { menu.addItem(i) }
        update()
        // 从主窗口标题栏切语言时（菜单可能正开着）跟着更新；@Published 在赋值前发出，等这一轮走完再读新语言
        languageSub = LanguageSettings.shared.$current.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { update() }
    func menuDidClose(_ menu: NSMenu) { onClose?() }

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
        resetRow.title = L.resetInput
        // 菜单宽度取各项里最宽的：这一行至少要放得下按钮文字和热键（英文比中文长）
        resetRow.setFrameSize(NSSize(width: max(240, resetRow.minimumWidth), height: resetRow.frame.height))
        resetRow.toolTip = L.resetInputHelp
        reset.isHidden = !model.canResetInput
        languageRow.title = L.menuLanguage
        languageRow.current = L.lang
        quit.title = L.menuQuit
    }

    @objc private func openWindow() { model.showWindowHandler?() }
    @objc private func quitApp() { model.quit() }
}

/// 菜单里「重置键鼠状态」一行：和主窗口底栏同款的蓝框按钮（浅蓝底、蓝描边、蓝字，右侧是热键提示），
/// 左右和普通菜单项的文字对齐。点了先收起菜单再执行；鼠标移上去底色加深一点
final class ResetMenuRow: NSView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    private static let inset: CGFloat = 14
    private static let boxHeight: CGFloat = 32

    override var isFlipped: Bool { true }

    private var titleText: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Self.blue])
    }
    private var hotkeyText: NSAttributedString {
        NSAttributedString(string: L.resetHotkey, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Self.blue])
    }
    private static let blue = NSColor(srgbRed: 0x28 / 255.0, green: 0x69 / 255.0, blue: 0xE8 / 255.0, alpha: 1)

    /// 放得下文字和热键的最小行宽：左右缩进、框内左右各 10、文字和热键之间至少 16
    var minimumWidth: CGFloat {
        (Self.inset * 2 + 10 + titleText.size().width + 16 + hotkeyText.size().width + 10).rounded(.up)
    }

    var boxRect: NSRect {
        NSRect(x: Self.inset, y: (bounds.height - Self.boxHeight) / 2,
               width: bounds.width - Self.inset * 2, height: Self.boxHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let box = boxRect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        (hovered ? NSColor(srgbRed: 0xD0 / 255.0, green: 0xDF / 255.0, blue: 0xFD / 255.0, alpha: 1)
                 : NSColor(srgbRed: 0xDF / 255.0, green: 0xEA / 255.0, blue: 0xFE / 255.0, alpha: 1)).setFill()
        path.fill()
        NSColor(srgbRed: 0x72 / 255.0, green: 0x9B / 255.0, blue: 0xE6 / 255.0, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
        let t = titleText
        let ts = t.size()
        t.draw(at: NSPoint(x: boxRect.minX + 10, y: boxRect.midY - ts.height / 2))
        let k = hotkeyText
        let ks = k.size()
        k.draw(at: NSPoint(x: boxRect.maxX - 10 - ks.width, y: boxRect.midY - ks.height / 2))
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard boxRect.contains(p) else { return }
        hovered = false
        enclosingMenuItem?.menu?.cancelTracking()
        onClick?()
    }
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

// 菜单栏图标和它的下拉菜单（设计稿 01）：
//   MacKVM / 连接状态 · 对方名 / 本机角色 / —— / 打开 MacKVM… / 收回光标 ⌃⌥⌘L / 退出 MacKVM
// 每次菜单要弹出时按 AppModel 的当前状态重建。「收回光标」只在主控方可用，被控方和未配对时灰掉。

import AppKit

final class StatusMenu: NSObject, NSMenuDelegate {
    let model: AppModel
    let item: NSStatusItem
    let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let b = item.button {
            // 程序图标 24×24 点、模板图（深色菜单栏自动反白）；资源缺失时退回系统的键盘符号，菜单栏不至于空着
            let img = AppIcon.image(points: 24) ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MacKVM")
            img?.isTemplate = true
            b.image = img
            b.imageScaling = .scaleProportionallyDown
            b.toolTip = "MacKVM"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func styled(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
    }

    private func info(_ a: NSAttributedString) -> NSMenuItem {
        let i = NSMenuItem(title: a.string, action: nil, keyEquivalent: "")
        i.attributedTitle = a
        i.isEnabled = false
        return i
    }

    private func rebuild() {
        menu.removeAllItems()
        menu.addItem(info(styled("MacKVM", size: 14, weight: .semibold, color: .labelColor)))

        if model.isPaired {
            let (text, color): (String, NSColor)
            switch model.linkStatus {
            case .connected: (text, color) = ("● 已连接", NSColor(srgbRed: 0x24 / 255.0, green: 0x84 / 255.0, blue: 0x51 / 255.0, alpha: 1))
            case .searching: (text, color) = ("● 正在寻找对方", NSColor(srgbRed: 0x9B / 255.0, green: 0x69 / 255.0, blue: 0x17 / 255.0, alpha: 1))
            case .offline: (text, color) = ("● 对方不在线", .secondaryLabelColor)
            }
            menu.addItem(info(styled("\(text) · \(model.peerName)", size: 13, color: color)))
            menu.addItem(info(styled(model.isController ? "本机操作对方" : "本机被对方操作", size: 12, color: .secondaryLabelColor)))
        } else {
            menu.addItem(info(styled("尚未配对", size: 13, color: .secondaryLabelColor)))
        }
        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开 MacKVM…", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let release = NSMenuItem(title: "收回光标", action: #selector(releaseCursor), keyEquivalent: "l")
        release.keyEquivalentModifierMask = [.control, .option, .command]
        release.target = self
        release.isEnabled = model.isPaired && model.isController
        menu.addItem(release)

        let quit = NSMenuItem(title: "退出 MacKVM", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func openWindow() { model.showWindowHandler?() }
    @objc private func releaseCursor() { model.releaseCursor() }
    @objc private func quit() { model.quit() }
}

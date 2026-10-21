// 波纹颜色的取色：点色点或「+」时弹出系统取色器（NSColorPanel）。
// 进程是 .accessory，弹出前先激活本应用并把取色器放到最前面；主窗口关闭时一并收起。
// 拖动色轮时颜色变化很密，这里合并成每 0.12 秒最多应用一次（每次应用都会保存并同步到另一台）。

import AppKit

final class ColorPanelController: NSObject {
    static let shared = ColorPanelController()

    private var apply: ((String) -> Void)?
    private var pending: String?
    private var flushScheduled = false

    /// 打开取色器编辑一个颜色；之后每次选色都会调用 apply（参数是 #RRGGBB）
    func edit(initial hex: String, apply: @escaping (String) -> Void) {
        flush()
        let p = NSColorPanel.shared
        p.setTarget(nil)
        p.setAction(nil)
        p.showsAlpha = false
        p.isContinuous = true
        p.color = nsColor(hex: hex)
        self.apply = apply
        p.setTarget(self)
        p.setAction(#selector(colorChanged(_:)))
        NSApp.activate()
        p.orderFrontRegardless()
        p.makeKey()
    }

    func close() {
        flush()
        apply = nil
        let p = NSColorPanel.shared
        p.setTarget(nil)
        p.setAction(nil)
        if p.isVisible { p.orderOut(nil) }
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard apply != nil, let c = sender.color.usingColorSpace(.sRGB) else { return }
        pending = hexColorString((Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        if let h = pending, let apply { apply(h) }
        pending = nil
    }
}

func nsColor(hex: String) -> NSColor {
    let (r, g, b) = parseHexColor(hex) ?? (0.157, 0.412, 0.91)
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

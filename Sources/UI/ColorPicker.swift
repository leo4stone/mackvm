// 波纹颜色的取色器（设计稿 07a，节点 zkCeP）：点「离开波纹」「进入波纹」的任一色样，从那个色样弹出一个小浮窗编辑它；
// 点「+」先追加一个颜色，再同样弹出编辑新加的那个。
//   - 浮窗是 NSPopover（behavior = .transient：点浮窗外部自动收起），挂在色样背后的一个透明 NSView 锚点上，
//     尖角指向当前色样；放不下时 AppKit 自己换方向。主体 190 × 159 点。
//   - 内容（SwiftUI）：饱和度 / 明度色盘（横向饱和度、纵向明度：左上白、右上纯色相、下方黑）、色相滑杆（彩虹条）、
//     HEX 输入框和它右边的删除按钮（29 × 29 方块，浅灰底、浅灰描边、红色垃圾桶图标）。
//     没有标题、关闭按钮、确认按钮。标签 13 点、输入文字 12 点、输入框高 29 点。
//   - 即时生效：拖色盘、拖色相、输入有效的六位 HEX 时立即改对应色样和波纹预览，不动其他颜色和顺序。
//     拖动时颜色变化很密，合并成每 0.12 秒最多应用一次（每次应用都会保存并同步到另一台）。
//   - HEX 输入：带不带 # 都认；回车或失焦时校验，无效就恢复上次有效值。
//   - 删除按钮：删掉正在编辑的这个颜色并收起浮窗；这一组只剩一个颜色时灰掉不可点（每组至少留一个）。右键色样删除照旧。
//   - 收起：点外部、主窗口关闭、关掉光标特效总开关、删掉正在编辑的那组里的颜色时收起；已经生效的修改保留。
//   - 再点同一个色样 = 收起、不重开：.transient 的浮窗在鼠标按下那一刻就收起了，色样的点击动作（鼠标抬起时）到达时
//     浮窗已经关了，没法再问「开着的是不是我」。所以在 popoverWillClose（按下那一刻）记下收起时编辑的色样、时刻和
//     这次按下的鼠标事件编号；点击动作到达时交给 colorPopoverShouldOpen 判定（见那里的说明）。
// 颜色换算（HEX ↔ 色相 / 饱和度 / 明度、色盘坐标 ↔ 饱和度 / 明度）是纯函数，自测直接断言。

import AppKit
import SwiftUI

// MARK: - 颜色换算（纯逻辑）

/// 色相 / 饱和度 / 明度，都在 0...1
struct HSV: Equatable {
    var h: Double
    var s: Double
    var v: Double
}

func hsvFromRGB(_ rgb: (Double, Double, Double)) -> HSV {
    let (r, g, b) = rgb
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h = 0.0
    if d > 0 {
        if mx == r {
            h = (g - b) / d
            if h < 0 { h += 6 }
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h /= 6
    }
    return HSV(h: h, s: mx > 0 ? d / mx : 0, v: mx)
}

func rgbFromHSV(_ c: HSV) -> (Double, Double, Double) {
    let h = (c.h - c.h.rounded(.down)) * 6     // 色相 1 和 0 一样都是红
    let s = min(max(c.s, 0), 1), v = min(max(c.v, 0), 1)
    let i = Int(h.rounded(.down)) % 6, f = h - h.rounded(.down)
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

func hsvFromHex(_ hex: String) -> HSV? { parseHexColor(hex).map(hsvFromRGB) }
func hexFromHSV(_ c: HSV) -> String { hexColorString(rgbFromHSV(c)) }

/// 色盘上的位置（左上角为原点、y 向下）：横向是饱和度（左 0 右 1），纵向是明度（上 1 下 0）
func svPoint(s: Double, v: Double, size: CGSize) -> CGPoint {
    CGPoint(x: CGFloat(s) * size.width, y: CGFloat(1 - v) * size.height)
}

/// 色盘上一点对应的饱和度和明度；拖出色盘时夹到边上
func svValue(at p: CGPoint, size: CGSize) -> (s: Double, v: Double) {
    let s = Double(min(max(p.x / max(size.width, 1), 0), 1))
    let v = 1 - Double(min(max(p.y / max(size.height, 1), 0), 1))
    return (s, v)
}

/// 色相滑杆上一点对应的色相（左 0 右 1），拖出两端时夹住
func hueValue(atX x: CGFloat, width: CGFloat) -> Double {
    Double(min(max(x / max(width, 1), 0), 1))
}

// MARK: - 正在编辑哪个色样

/// 哪一组（离开 / 进入波纹）的第几个颜色
struct ColorEditTarget: Equatable {
    let group: WritableKeyPath<RippleConfig, [String]>
    let index: Int
}

/// 删掉一组里的第 index 个颜色；这一组只剩一个（每组至少留一个）或序号越界时返回 nil，表示不删
func removingColor(_ colors: [String], at index: Int) -> [String]? {
    guard colors.count > 1, colors.indices.contains(index) else { return nil }
    var c = colors
    c.remove(at: index)
    return c
}

// MARK: - 再点同一个色样就收起（纯逻辑，自测直接断言）

/// 浮窗被点外部收起的那一刻（popoverWillClose）记下的：当时在编辑哪个色样、什么时候、是哪一次鼠标按下引起的
struct ColorPopoverDismissal: Equatable {
    let target: ColorEditTarget
    let at: Date
    /// 引起收起的那次鼠标按下的事件编号（CGEvent 的 mouseEventNumber，同一次点击的按下和抬起编号相同）；
    /// 不是鼠标按下引起的（比如切到别的应用）就是 nil
    let click: Int64?
}

/// 点击动作到达时（鼠标抬起）间隔多久以内、又点的是刚收起的那个色样，就当作「这一下是来关的」
let kColorReopenGuard: TimeInterval = 0.3

/// 点了某个色样，要不要打开取色器：
///   - 刚才没有被点外部收起过、或收起时编辑的是别的色样 → 打开（点另一个色样 = 从那个色样弹出）
///   - 收起时编辑的就是这个色样：两边都拿得到鼠标事件编号时按编号判——相同说明收起它的就是这一次点击 → 不开；
///     不同说明是之后新的一次点击 → 开。拿不到编号时按时间判：收起后 0.3 秒内 → 不开，超过 → 开
func colorPopoverShouldOpen(after last: ColorPopoverDismissal?, target: ColorEditTarget, now: Date, click: Int64?) -> Bool {
    guard let last, last.target == target else { return true }
    if let c = click, let lc = last.click { return c != lc }
    let dt = now.timeIntervalSince(last.at)
    return !(dt >= 0 && dt < kColorReopenGuard)
}

/// 当前正在处理的鼠标按下 / 抬起事件的编号；别的事件（或没有事件）是 nil
func currentMouseClickNumber() -> Int64? {
    guard let e = NSApp?.currentEvent else { return nil }
    switch e.type {
    case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
        return e.cgEvent?.getIntegerValueField(.mouseEventNumber)
    default:
        return nil
    }
}

// MARK: - 弹出框

final class ColorPopoverController: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = ColorPopoverController()
    /// 浮窗主体的尺寸（设计稿 07a）
    static let contentSize = NSSize(width: 190, height: 159)

    /// 当前正在编辑的色样（色样据此画蓝色选中框）；没打开时是 nil
    @Published var editing: ColorEditTarget?
    let picker = ColorPickerModel()

    private var popover: NSPopover?
    private var apply: ((String) -> Void)?
    private var remove: (() -> Void)?
    private var pending: String?
    private var flushScheduled = false
    /// 浮窗上一次被点外部收起时的记录（popoverWillClose 里记），判定「再点同一个色样就收起」用
    private(set) var lastDismissal: ColorPopoverDismissal?

    override init() {
        super.init()
        picker.onPick = { [weak self] hex in self?.submit(hex) }
        picker.onDelete = { [weak self] in self?.deleteEditing() }
    }

    /// 从 anchor（色样背后的锚点视图）弹出取色器编辑一个颜色；之后每次改色都会调用 apply（参数是 #RRGGBB）。
    /// canDelete：这一组不止一个颜色，删除按钮可点；点删除按钮时调用 remove 删掉这个颜色
    func show(relativeTo anchor: NSView, target: ColorEditTarget, initial hex: String, canDelete: Bool,
              apply: @escaping (String) -> Void, remove: @escaping () -> Void) {
        // 再点同一个色样：按下那一刻浮窗已经被 .transient 收起，这里不再重新打开，相当于点一下开、再点一下关
        let open = colorPopoverShouldOpen(after: lastDismissal, target: target, now: Date(), click: currentMouseClickNumber())
        lastDismissal = nil
        guard open else { return }
        // 浮窗还开着（没被按下收起，比如点击来自键盘）而且点的是同一个色样：同样当作关
        if let p = popover, p.isShown, editing == target {
            close()
            return
        }
        close()
        guard anchor.window != nil else { return }
        attach(target: target, initial: hex, canDelete: canDelete, apply: apply, remove: remove)
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.appearance = NSAppearance(named: .aqua)
        p.contentSize = Self.contentSize
        let host = NSHostingController(rootView: ColorPickerView(model: picker))
        host.sizingOptions = []
        host.view.frame = NSRect(origin: .zero, size: Self.contentSize)
        p.contentViewController = host
        p.delegate = self
        popover = p
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// 记下正在编辑哪个色样、改色和删除时调谁，并把取色器内容设成这个颜色（不弹浮窗；show 和自测都走这里）
    func attach(target: ColorEditTarget, initial hex: String, canDelete: Bool,
                apply: @escaping (String) -> Void, remove: @escaping () -> Void) {
        picker.load(hex)
        picker.canDelete = canDelete
        self.apply = apply
        self.remove = remove
        editing = target
    }

    /// 收起浮窗（已经生效的修改保留，还没来得及应用的最后一下先应用掉）。
    /// 这里主动关时先摘掉代理，不会走 popoverWillClose，所以不记收起记录
    func close() {
        flush()
        if let p = popover {
            popover = nil
            p.delegate = nil
            p.close()
        }
        apply = nil
        remove = nil
        editing = nil
    }

    /// 删除按钮：删掉正在编辑的这个颜色，收起浮窗。还没应用的改色直接丢掉（颜色马上就删了，不用再保存、同步一次）
    func deleteEditing() {
        guard picker.canDelete, let remove else { return }
        pending = nil
        close()
        remove()
    }

    /// .transient 的浮窗被点外部收起：鼠标按下那一刻就到这里（比色样的点击动作早），记下收起的是哪个色样、哪次按下
    func popoverWillClose(_ notification: Notification) {
        guard let p = notification.object as? NSPopover, p === popover, let t = editing else { return }
        lastDismissal = ColorPopoverDismissal(target: t, at: Date(), click: currentMouseClickNumber())
    }

    func popoverDidClose(_ notification: Notification) {
        guard let p = notification.object as? NSPopover, p === popover else { return }
        popover = nil
        close()
    }

    /// 只给离屏渲染用：不弹浮窗，只把某个色样标成正在编辑、把取色器内容设成这个颜色
    func previewEditing(_ target: ColorEditTarget, hex: String, canDelete: Bool = true) {
        attach(target: target, initial: hex, canDelete: canDelete, apply: { _ in }, remove: {})
    }

    private func submit(_ hex: String) {
        guard apply != nil else { return }
        pending = hex
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

// MARK: - 取色器的状态

final class ColorPickerModel: ObservableObject {
    @Published var hsv = HSV(h: 0, s: 0, v: 1)
    /// 输入框里的文字（用户正在输的可能还不是有效值）
    @Published var hexText = "#FFFFFF"
    /// 上一次有效的颜色（#RRGGBB）；输入无效时恢复成它
    @Published private(set) var hex = "#FFFFFF"
    /// 颜色变了（拖动、输入有效值）就调用，参数是 #RRGGBB
    var onPick: ((String) -> Void)?
    /// 删除按钮可不可点：这一组只剩一个颜色时不可点
    @Published var canDelete = true
    /// 点了删除按钮
    var onDelete: (() -> Void)?

    /// 打开时载入要编辑的颜色
    func load(_ h: String) {
        let n = normalizedHexInput(h) ?? "#FFFFFF"
        hex = n
        hexText = n
        hsv = hsvFromHex(n) ?? HSV(h: 0, s: 0, v: 1)
    }

    /// 拖色盘：饱和度、明度跟着变，色相不动
    func setSV(_ s: Double, _ v: Double) {
        hsv.s = s
        hsv.v = v
        picked()
    }

    /// 拖色相滑杆
    func setHue(_ h: Double) {
        hsv.h = h
        picked()
    }

    /// 输入框文字变了：是有效的六位 HEX 就立即应用（不改写正在输的文字）
    func typed(_ text: String) {
        guard let n = normalizedHexInput(text), n != hex else { return }
        var c = hsvFromHex(n) ?? hsv
        // 灰色（饱和度 0）和黑色（明度 0）没有色相：保留现在的色相，色相滑杆不跳回红色
        if c.s == 0 || c.v == 0 { c.h = hsv.h }
        hsv = c
        hex = n
        onPick?(n)
    }

    /// 回车或失焦：有效就统一写成 #RRGGBB，无效就恢复上次有效值
    func commitText() {
        if let n = normalizedHexInput(hexText) {
            typed(n)
            hexText = n
        } else {
            hexText = hex
        }
    }

    /// 拖动改了颜色：输入框跟着显示新值，颜色真变了才应用
    private func picked() {
        let n = hexFromHSV(hsv)
        hexText = n
        guard n != hex else { return }
        hex = n
        onPick?(n)
    }
}

// MARK: - 取色器的界面（浮窗里的内容，190 × 159）

struct ColorPickerView: View {
    @ObservedObject var model: ColorPickerModel
    @FocusState private var focused: Bool

    private static let padding: CGFloat = 8
    private static let fieldHeight: CGFloat = 84    // 色盘高
    private static let hueHeight: CGFloat = 14
    private static let knob: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            svField
            hueBar
            // HEX 标签、输入框（占满剩下的宽度）、删除按钮（29 × 29）
            HStack(spacing: 8) {
                Text(L.colorHex).font(.ui(13)).foregroundStyle(Theme.text).fixedSize()
                TextField("", text: $model.hexText)
                    .textFieldStyle(.plain)
                    .font(.ui(12))
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { model.commitText() }
                    .onChange(of: model.hexText) { _, t in model.typed(t) }
                    .onChange(of: focused) { _, f in if !f { model.commitText() } }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: 29)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                Button { model.onDelete?() } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(model.canDelete ? Theme.red : Theme.sub.opacity(0.5))
                        .frame(width: 29, height: 29)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canDelete)
                .help(L.colorDelete)
            }
            .frame(height: 29)
        }
        .padding(Self.padding)
        .frame(width: ColorPopoverController.contentSize.width, height: ColorPopoverController.contentSize.height,
               alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    /// 饱和度 / 明度色盘：底色是纯色相，横向叠一层白→透明，纵向再叠一层透明→黑
    private var svField: some View {
        GeometryReader { geo in
            let size = geo.size
            // 滑块圆心按颜色算在色盘上的位置，再往里收半个滑块：拖到角上时滑块整个留在色盘里（设计稿 07a 左上角的白色滑块）
            let raw = svPoint(s: model.hsv.s, v: model.hsv.v, size: size)
            let p = CGPoint(x: min(max(raw.x, Self.knob / 2), size.width - Self.knob / 2),
                            y: min(max(raw.y, Self.knob / 2), size.height - Self.knob / 2))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color(hue: model.hsv.h, saturation: 1, brightness: 1))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                Circle()
                    .fill(Color(cgColor: cgColor(hex: model.hex)))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                    .overlay(Circle().strokeBorder(Color(hex: 0x8A93A1), lineWidth: 1).padding(-1))
                    .frame(width: Self.knob, height: Self.knob)
                    .position(p)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let sv = svValue(at: g.location, size: size)
                model.setSV(sv.s, sv.v)
            })
        }
        .frame(height: Self.fieldHeight)
    }

    /// 色相滑杆：彩虹条，滑块是当前色相的纯色圆点
    private var hueBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let stops = (0...6).map { Color(hue: $0 == 6 ? 0.9999 : Double($0) / 6, saturation: 1, brightness: 1) }
            let x = min(max(CGFloat(model.hsv.h) * w, Self.knob / 2), w - Self.knob / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                Circle()
                    .fill(Color(hue: model.hsv.h, saturation: 1, brightness: 1))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: Self.knob, height: Self.knob)
                    .position(x: x, y: geo.size.height / 2)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                model.setHue(hueValue(atX: g.location.x, width: w))
            })
        }
        .frame(height: Self.hueHeight)
    }
}

// MARK: - 色样背后的锚点（浮窗从它弹出、尖角指向它）

final class ColorAnchorBox {
    weak var view: NSView?
}

/// 透明、不接鼠标的 NSView，放在色样背后：NSPopover 要挂在一个 NSView 上
struct ColorAnchor: NSViewRepresentable {
    let box: ColorAnchorBox
    /// 离屏渲染按它找到色样的位置，如「leave-0」
    let name: String

    func makeNSView(context: Context) -> ColorAnchorView {
        let v = ColorAnchorView()
        v.name = name
        box.view = v
        return v
    }

    func updateNSView(_ v: ColorAnchorView, context: Context) {
        v.name = name
        box.view = v
    }
}

final class ColorAnchorView: NSView {
    var name = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

func nsColor(hex: String) -> NSColor {
    let (r, g, b) = parseHexColor(hex) ?? (0.157, 0.412, 0.91)
    return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

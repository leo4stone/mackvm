// 「光标特效」页（设计稿 07）：右上角「恢复默认值」和总开关；左右两张等宽卡片分别是离开 / 进入波纹的参数，
// 左卡片下方还有两组波纹颜色。两张卡片同时是预览区：它们模拟两块并排的显示器，中间的分界线是两屏相接的边，
// 鼠标越过分界线时在卡片里播放波纹（逻辑见 RipplePreview.swift，环画在卡片内容上层、裁剪在卡片圆角内、不拦截鼠标）。
// 每改一下立即生效并同步到另一台（AppModel.updateRipple）。总开关关掉时不弹窗：参数、颜色和「恢复默认值」
// 置灰，越线也不播放；保留当前值，重新开启后恢复。

import SwiftUI

private let kCardGap: CGFloat = 4

struct RipplePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let r = model.ripple
        // 统一页面骨架：标题区 64、主体（346）、底部说明 40，间距 12
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("让光标的去向清晰可见").font(.ui(26, .semibold)).lh(26).foregroundStyle(Theme.text)
                    Text("跨设备时显示波纹 · 修改立即生效，并同步到另一台")
                        .font(.ui(13)).lh(13).foregroundStyle(Theme.sub)
                }
                Spacer()
                Button("恢复默认值") { model.resetRipple() }
                    .buttonStyle(KVMButtonStyle(kind: .secondary, padV: 9, padH: 16))
                    .disabled(!r.enabled)
                Text(r.enabled ? "已开启" : "已关闭").font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
                KVMSwitch(on: r.enabled) { v in
                    if !v { ColorPanelController.shared.close() }
                    model.updateRipple { $0.enabled = v }
                }
            }
            .frame(height: 64)
            PreviewCards(preview: model.ripplePreview)
                .frame(maxHeight: .infinity)
            Text("鼠标越过两张卡片中间的分界线即可体验波纹；进入波纹至少持续 \(seconds(r.minDuration)) 秒，停下 \(seconds(r.idleStop)) 秒后停止出环，最长 \(seconds(r.maxDuration)) 秒。")
                .font(.ui(12)).lh(12).foregroundStyle(Theme.sub).lineLimit(1)
                .frame(height: 40)
        }
    }
}

/// 秒数显示：整数不带小数点，其余最多两位小数
func seconds(_ v: Double) -> String {
    if abs(v - v.rounded()) < 0.0001 { return String(Int(v.rounded())) }
    var s = String(format: "%.2f", v)
    while s.hasSuffix("0") { s.removeLast() }
    return s
}

/// 两张并排的卡片 + 中间的分界线 + 鼠标越线判定
private struct PreviewCards: View {
    let preview: RipplePreviewModel

    var body: some View {
        GeometryReader { geo in
            let w = (geo.size.width - kCardGap) / 2
            HStack(spacing: kCardGap) {
                ParamCard(side: .left, title: "离开波纹", note: "光标离开一块屏幕时，在离开位置向外扩散出环",
                          rows: [("环的大小", \.leaveSize), ("每个环的时长", \.leaveDuration),
                                 ("出环间隔", \.leaveInterval), ("持续时间", \.leaveTotal)],
                          showColors: true, preview: preview)
                    .frame(width: w)
                ParamCard(side: .right, title: "进入波纹", note: "光标进入一块屏幕时，沿移动轨迹连续出环",
                          rows: [("环的大小", \.arriveSize), ("每个环的时长", \.arriveDuration),
                                 ("出环间隔", \.spawnInterval), ("至少持续", \.minDuration),
                                 ("停下判定时间", \.idleStop), ("最长持续", \.maxDuration)],
                          showColors: false, preview: preview)
                    .frame(width: w)
            }
            .overlay(alignment: .topLeading) {
                // 两块「屏幕」相接的边：一条和卡片边框同色的竖线
                Rectangle().fill(Theme.border).frame(width: 1, height: geo.size.height)
                    .offset(x: w + kCardGap / 2 - 0.5)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "rippleCards")
            .onContinuousHover(coordinateSpace: .named("rippleCards")) { phase in
                switch phase {
                case .active(let p): preview.pointerMoved(p)
                case .ended: preview.pointerExited()
                }
            }
            .onAppear { preview.setLayout(cardWidth: w, gap: kCardGap, height: geo.size.height) }
            .onChange(of: geo.size) { _, s in
                preview.setLayout(cardWidth: (s.width - kCardGap) / 2, gap: kCardGap, height: s.height)
            }
        }
    }
}

private struct ParamCard: View {
    @EnvironmentObject var model: AppModel
    let side: CardSide
    let title: String
    let note: String
    let rows: [(String, WritableKeyPath<RippleConfig, Double>)]
    let showColors: Bool
    let preview: RipplePreviewModel

    var body: some View {
        let enabled = model.ripple.enabled
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ui(16, .semibold)).lh(16).foregroundStyle(Theme.text)
            Text(note).font(.ui(11)).lh(11).foregroundStyle(Theme.sub)
            Group {
                ForEach(rows, id: \.0) { label, kp in
                    HStack(spacing: 12) {
                        Text(label).font(.ui(13)).lh(13).foregroundStyle(Theme.text)
                        Spacer()
                        ParamStepper(keyPath: kp)
                    }
                }
                if showColors {
                    Text("波纹颜色").font(.ui(16, .semibold)).foregroundStyle(Theme.text)
                        .frame(height: 29, alignment: .leading)
                    HStack(spacing: 12) {
                        ColorGroup(label: "离开波纹", keyPath: \.leaveColors)
                        ColorGroup(label: "进入波纹", keyPath: \.arriveColors)
                    }
                    .frame(height: 29)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RingHost(preview: preview, side: side).allowsHitTesting(false) }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1).allowsHitTesting(false))
    }
}

/// 一张卡片里的预览环图层：前景覆盖层，圆角 10 裁剪，不拦鼠标、不占布局。
/// 出环由 RipplePreviewModel 直接调用这里注册的闭包，环用和真实效果同一段 CAShapeLayer 动画代码画。
private struct RingHost: NSViewRepresentable {
    let preview: RipplePreviewModel
    let side: CardSide

    func makeNSView(context: Context) -> RingHostView {
        let v = RingHostView()
        preview.register(side) { [weak v] p, params, color in v?.addRing(at: p, params: params, color: color) }
        return v
    }

    func updateNSView(_ nsView: RingHostView, context: Context) {}
}

final class RingHostView: NSView {
    /// 只给离屏自查用：非 nil 时不加动画，环直接定格在这个进度
    static var frozenProgress: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 10
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// p：卡片坐标（左上角为原点、y 向下）；图层坐标原点在左下角，这里翻一下
    func addRing(at p: CGPoint, params: RippleParams, color: String) {
        guard let layer else { return }
        let center = CGPoint(x: p.x, y: bounds.height - p.y)
        addRingLayer(to: layer, center: center, params: params, color: color,
                     scale: window?.backingScaleFactor ?? 2, frozenProgress: RingHostView.frozenProgress)
    }
}

/// 一组波纹颜色：标签 + 色点 + 「+」。点色点改色、点「+」加色（系统取色器），右键色点可删除（至少留一个）
private struct ColorGroup: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let keyPath: WritableKeyPath<RippleConfig, [String]>

    var body: some View {
        let colors = model.ripple[keyPath: keyPath]
        HStack(spacing: 3) {
            Text(label).font(.ui(13)).foregroundStyle(Theme.text).fixedSize()
            Spacer(minLength: 6)
            ForEach(Array(colors.enumerated()), id: \.offset) { i, hex in
                Button {
                    ColorPanelController.shared.edit(initial: hex) { new in
                        model.updateRipple { r in
                            if i < r[keyPath: keyPath].count { r[keyPath: keyPath][i] = new }
                        }
                    }
                } label: {
                    swatchBox(fill: .white) { Circle().fill(Color(cgColor: cgColor(hex: hex))).frame(width: 12, height: 12) }
                }
                .buttonStyle(.plain)
                .help("点按修改颜色；右键可删除")
                .contextMenu {
                    Button("删除这个颜色") {
                        model.updateRipple { r in
                            if r[keyPath: keyPath].count > 1, i < r[keyPath: keyPath].count {
                                r[keyPath: keyPath].remove(at: i)
                            }
                        }
                    }
                    .disabled(colors.count <= 1)
                }
            }
            if colors.count < RippleConfig.maxColors {
                Button {
                    var added: Int?   // 第一次选色时追加，之后继续选色就改这一个
                    ColorPanelController.shared.edit(initial: colors.last ?? RippleConfig.defaultColors[0]) { new in
                        model.updateRipple { r in
                            if let i = added, i < r[keyPath: keyPath].count {
                                r[keyPath: keyPath][i] = new
                            } else if r[keyPath: keyPath].count < RippleConfig.maxColors {
                                r[keyPath: keyPath].append(new)
                                added = r[keyPath: keyPath].count - 1
                            }
                        }
                    }
                } label: {
                    swatchBox(fill: Theme.fieldBG) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.sub)
                    }
                }
                .buttonStyle(.plain)
                .help("添加颜色")
            }
        }
    }

    private func swatchBox<C: View>(fill: Color, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(width: 18, height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// 步进输入框：可以直接输数字（回车或失焦生效），也可以点右侧的 ⌃ / ⌄ 按步进加减
private struct ParamStepper: View {
    @EnvironmentObject var model: AppModel
    let keyPath: WritableKeyPath<RippleConfig, Double>
    @State private var text = ""
    @FocusState private var focused: Bool

    private var spec: RippleConfig.Spec { RippleConfig.specs[keyPath]! }
    private var value: Double { model.ripple[keyPath: keyPath] }

    private func display(_ v: Double) -> String {
        spec.isSeconds ? "\(seconds(v)) 秒" : seconds(v)
    }

    private func commit() {
        let num = text.filter { $0.isNumber || $0 == "." }
        if let v = Double(num) {
            model.updateRipple { $0[keyPath: keyPath] = v }
        }
        text = display(value)
    }

    private func step(_ dir: Double) {
        model.updateRipple { $0[keyPath: keyPath] = value + dir * spec.step }
        text = display(value)
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, f in if !f { commit() } }
            ZStack {
                Text("⌃⌄").font(.ui(10)).foregroundStyle(Theme.sub)
                VStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
                    Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                }
            }
            .frame(width: 18)
        }
        .padding(.horizontal, 10)
        .frame(width: 100, height: 29)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fieldBG))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
        .onAppear { text = display(value) }
        .onChange(of: value) { _, v in if !focused { text = display(v) } }
    }
}

/// 设计稿里的开关：38×22 胶囊、16 点白色滑块
struct KVMSwitch: View {
    let on: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button {
            set(!on)
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Theme.blue : Color(hex: 0xC9CED6))
                Circle().fill(Color.white).frame(width: 16, height: 16).padding(3)
            }
            .frame(width: 38, height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "关闭光标特效" : "开启光标特效")
    }
}

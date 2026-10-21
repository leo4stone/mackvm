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
                    Text(L.rippleTitle).font(.ui(26, .semibold)).lh(26).foregroundStyle(Theme.text)
                    Text(L.rippleSubtitle)
                        .font(.ui(13)).lh(13).foregroundStyle(Theme.sub)
                }
                Spacer()
                Button(L.rippleReset) { model.resetRipple() }
                    .buttonStyle(KVMButtonStyle(kind: .secondary, padV: 9, padH: 16))
                    .disabled(!r.enabled)
                Text(L.rippleSwitchState(r.enabled)).font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
                KVMSwitch(on: r.enabled) { v in
                    if !v { ColorPopoverController.shared.close() }
                    model.updateRipple { $0.enabled = v }
                }
            }
            .frame(height: 64)
            PreviewCards(preview: model.ripplePreview)
                .frame(maxHeight: .infinity)
            Text(L.rippleFootnote(min: seconds(r.minDuration), idle: seconds(r.idleStop), max: seconds(r.maxDuration)))
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
                ParamCard(side: .left, title: L.leaveRipple, note: L.leaveRippleNote,
                          rows: [(L.ringSize, \.leaveSize), (L.ringDuration, \.leaveDuration),
                                 (L.ringInterval, \.leaveInterval), (L.leaveTotal, \.leaveTotal)],
                          showColors: true, preview: preview)
                    .frame(width: w)
                ParamCard(side: .right, title: L.arriveRipple, note: L.arriveRippleNote,
                          rows: [(L.ringSize, \.arriveSize), (L.ringDuration, \.arriveDuration),
                                 (L.ringInterval, \.spawnInterval), (L.minDuration, \.minDuration),
                                 (L.idleStop, \.idleStop), (L.maxDuration, \.maxDuration)],
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
                    Text(L.rippleColors).font(.ui(16, .semibold)).foregroundStyle(Theme.text)
                        .frame(height: 29, alignment: .leading)
                    HStack(spacing: 12) {
                        ColorGroup(label: L.leaveRipple, keyPath: \.leaveColors)
                        ColorGroup(label: L.arriveRipple, keyPath: \.arriveColors)
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

/// 一组波纹颜色：标签 + 色样 + 「+」。点色样从它弹出取色器（ColorPicker.swift）改这个颜色；
/// 点「+」先追加一个颜色、再弹出取色器编辑新加的那个；右键色样、或取色器里的删除按钮可删除（至少留一个）
private struct ColorGroup: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let keyPath: WritableKeyPath<RippleConfig, [String]>
    /// 刚点「+」追加的那个色样的序号：它出现后自动弹出取色器
    @State private var openNew: Int?

    /// 「+」追加的颜色：取一个这组里还没有的常用色，都有了就复制最后一个
    static let addCandidates = ["#2869E8", "#9166D8", "#27A7A0", "#FFFFFF", "#000000"]

    var body: some View {
        let colors = model.ripple[keyPath: keyPath]
        HStack(spacing: 3) {
            Text(label).font(.ui(13)).foregroundStyle(Theme.text).fixedSize()
            Spacer(minLength: 6)
            ForEach(Array(colors.enumerated()), id: \.offset) { i, hex in
                ColorSwatch(keyPath: keyPath, index: i, hex: hex, canDelete: colors.count > 1,
                            autoOpen: openNew == i, autoOpened: { openNew = nil })
            }
            if colors.count < RippleConfig.maxColors {
                Button {
                    let new = Self.addCandidates.first { !colors.contains($0) } ?? colors.last ?? Self.addCandidates[0]
                    var added: Int?
                    model.updateRipple { r in
                        if r[keyPath: keyPath].count < RippleConfig.maxColors {
                            r[keyPath: keyPath].append(new)
                            added = r[keyPath: keyPath].count - 1
                        }
                    }
                    openNew = added
                } label: {
                    swatchBox(fill: Theme.fieldBG) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.sub)
                    }
                }
                .buttonStyle(.plain)
                .help(L.colorAdd)
            }
        }
    }
}

/// 一个色样：白底小方块里一个色点；正在取色器里编辑时外面加一圈蓝框
private struct ColorSwatch: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var picker = ColorPopoverController.shared
    let keyPath: WritableKeyPath<RippleConfig, [String]>
    let index: Int
    let hex: String
    let canDelete: Bool
    let autoOpen: Bool
    let autoOpened: () -> Void
    @State private var anchor = ColorAnchorBox()

    private var target: ColorEditTarget { ColorEditTarget(group: keyPath, index: index) }

    var body: some View {
        Button { open() } label: {
            // 色点带一圈浅灰描边：白色的色点在白底上也看得见（设计稿 07）
            swatchBox(fill: .white) {
                Circle().fill(Color(cgColor: cgColor(hex: hex)))
                    .overlay(Circle().strokeBorder(Color(hex: 0xB4BCC8), lineWidth: 1))
                    .frame(width: 12, height: 12)
            }
                .overlay {
                    if picker.editing == target {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.blue, lineWidth: 2).padding(-1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .background(ColorAnchor(box: anchor, name: (keyPath == \RippleConfig.leaveColors ? "leave-" : "arrive-") + "\(index)"))
        .help(L.colorSwatchHelp)
        .contextMenu {
            Button(L.colorDelete) {
                // 删的是正在编辑的这组里的颜色：先收起取色器，免得它接着改到挪了位置的另一个颜色
                if picker.editing?.group == keyPath { picker.close() }
                let kp = keyPath, i = index
                model.updateRipple { r in
                    if let rest = removingColor(r[keyPath: kp], at: i) { r[keyPath: kp] = rest }
                }
            }
            .disabled(!canDelete)
        }
        .onAppear {
            guard autoOpen else { return }
            autoOpened()
            open(retries: 5)
        }
    }

    /// 从这个色样弹出取色器。刚追加的色样可能还没进窗口，稍等再试几次
    private func open(retries: Int = 0) {
        guard let v = anchor.view, v.window != nil else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { open(retries: retries - 1) }
            }
            return
        }
        let kp = keyPath, i = index, m = model
        picker.show(relativeTo: v, target: target, initial: hex, canDelete: canDelete, apply: { new in
            m.updateRipple { r in
                if i < r[keyPath: kp].count { r[keyPath: kp][i] = new }
            }
        }, remove: {
            m.updateRipple { r in
                if let rest = removingColor(r[keyPath: kp], at: i) { r[keyPath: kp] = rest }
            }
        })
    }
}

private func swatchBox<C: View>(fill: Color, @ViewBuilder _ content: () -> C) -> some View {
    content()
        .frame(width: 18, height: 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
        .contentShape(Rectangle())
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
        spec.isSeconds ? L.secondsValue(seconds(v)) : seconds(v)
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
        .help(L.rippleSwitchHelp(on))
    }
}

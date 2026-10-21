// 已配对的「设备连接」页（设计稿 06「屏幕相邻关系」）：
//   标题区：标题 + 连接状态标签（点了才弹说明，状态变化时不弹）+ 解除配对；固定提示一行；
//   主体：当前规则的双屏预览，按物理尺寸等比例画（放不下整体缩小）；本机屏固定，拖动对方屏换边、沿边调整错开，
//         靠近有效边时吸附；拖到无效位置不能放下，并在拖动处说明原因；蓝色边段 = 光标可双向跨越的那一段；
//         规则失效、没有可用规则、对方离线、尺寸估算等都在预览里标明（不弹窗）；
//   底部规则栏：规则切换（本机显示器标签 + 对方显示器标签）、添加规则、删除规则（删最后一条前确认）。
// 配色：本机浅蓝底蓝边蓝字，对方白底灰边灰字，不随输入角色交换。
// 输入设备（主控）那台的卡片写「键盘鼠标接在这里」，另一台卡片上有「切换为输入设备」（即对调角色，先弹确认）。

import SwiftUI

extension Theme {
    static let localFill = Color(hex: 0xDFEAFE)
    static let localStroke = Color(hex: 0x729BE6)
    static let remoteStroke = Color(hex: 0xB4C1D4)
    static let previewBG = Color(hex: 0xEDF2FA)
    static let previewStroke = Color(hex: 0xE0E6EF)
}

struct ConnectionPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    Text("屏幕相邻关系").font(.ui(26, .semibold)).lh(26).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    Button { model.dialog = .linkInfo } label: { StatusPill(status: model.linkStatus) }
                        .buttonStyle(.plain)
                        .help("查看连接状态说明")
                    Button("解除配对") { model.dialog = .confirmUnpair }
                        .buttonStyle(KVMButtonStyle(kind: .secondary, size: 13, weight: .medium, padV: 9, padH: 16))
                }
                .frame(height: 38)
                Text("拖动屏幕调整相邻关系，光标可从蓝色边段双向跨越。")
                    .font(.ui(13)).lh(13).foregroundStyle(Theme.sub)
            }
            .frame(height: 64)
            RulePreview()
                .frame(maxHeight: .infinity)
            RuleBar()
                .frame(height: 40)
        }
    }
}

// MARK: - 规则名字

extension AppModel {
    /// 两台屏幕的完整标签（带位置后缀）；拔掉的屏用见过的信息
    var screenLabels: [String: String] {
        var out = ScreenNaming.labels(localScreens)
        for (k, v) in ScreenNaming.labels(peerScreens) { out[k] = v }
        for (id, s) in knownScreens where out[id] == nil { out[id] = s.name }
        return out
    }

    /// 一条规则在本机视角下的两块屏标签
    func ruleLabels(_ r: AdjacencyRule) -> (local: String, remote: String) {
        guard let v = r.view(from: me.id) else { return ("?", "?") }
        let l = screenLabels
        return (l[v.localScreen] ?? "未知显示器", l[v.remoteScreen] ?? "未知显示器")
    }

    var selectedRule: AdjacencyRule? {
        rules.first(where: { $0.id == selectedRuleID }) ?? rules.first
    }
}

// MARK: - 双屏预览

private struct RulePreview: View {
    @EnvironmentObject var model: AppModel
    /// 拖动中：拖动开始时的布局（拖动时不重新居中，免得本机屏跟着跑）和吸附后的规则视角
    @State private var dragLayout: PreviewLayout?
    @State private var dragView: RuleView?
    /// 手势进行中为 true；手势被系统取消（窗口失去 key、弹窗盖上来等）时 onEnded 不会被调用，但它一定会复位
    @GestureState private var gestureActive = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.previewBG)
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.previewStroke, lineWidth: 1)
                if let rule = model.selectedRule, let base = rule.view(from: model.me.id),
                   let l = screen(base.localScreen), let r = screen(base.remoteScreen) {
                    let v = dragView ?? model.previewDragOverride ?? base
                    let layout = dragLayout ?? PreviewLayout(local: l, remote: r, view: v, size: geo.size)
                    content(rule: rule, view: v, local: l, remote: r, layout: layout, base: base, size: geo.size)
                } else if model.rules.isEmpty {
                    emptyState
                } else {
                    Text("这条规则用到的显示器信息还没收到，连上对方后会显示。")
                        .font(.ui(13)).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                notices
                    .padding(12)
            }
        }
        .onChange(of: gestureActive) { _, active in
            // 正常结束时 onEnded 已先把 dragView 清掉；这里还有值 = 手势被取消、没收到结束
            if !active, dragView != nil || dragLayout != nil {
                clearDrag()
            }
        }
        .onChange(of: model.interactionResetToken) { _, _ in
            if dragView != nil || dragLayout != nil { clearDrag() }
        }
    }

    private func clearDrag() {
        dragView = nil
        dragLayout = nil
    }

    private func screen(_ id: String) -> ScreenInfo? {
        model.localScreens.first { $0.id == id } ?? model.peerScreens.first { $0.id == id } ?? model.knownScreens[id]
    }

    private func isPresent(_ id: String) -> Bool {
        model.localScreens.contains { $0.id == id } || model.peerScreens.contains { $0.id == id }
    }

    @ViewBuilder
    private func content(rule: AdjacencyRule, view v: RuleView, local l: ScreenInfo, remote r: ScreenInfo,
                         layout: PreviewLayout, base: RuleView, size: CGSize) -> some View {
        let lRect = layout.rect(CGRect(x: 0, y: 0, width: l.mmW, height: l.mmH))
        let ro = RuleDrag.remoteOrigin(v, local: l, remote: r)
        let rRect = layout.rect(CGRect(x: ro.x, y: ro.y, width: r.mmW, height: r.mmH))
        let t = v.touch(l, r)
        let active = isPresent(l.id) && isPresent(r.id) && t.hi - t.lo >= kMinTouchMM - 0.001
        ScreenCard(screen: l, isLocal: true, present: isPresent(l.id), label: model.screenLabels[l.id] ?? l.name)
            .frame(width: lRect.width, height: lRect.height)
            .position(x: lRect.midX, y: lRect.midY)
        ScreenCard(screen: r, isLocal: false, present: isPresent(r.id), label: model.screenLabels[r.id] ?? r.name)
            .frame(width: rRect.width, height: rRect.height)
            .position(x: rRect.midX, y: rRect.midY)
            .gesture(drag(local: l, remote: r, base: base, size: size))
        if t.hi > t.lo {
            let seg = segmentRect(v, local: l, touch: t, layout: layout)
            Rectangle().fill(active ? Theme.blue : Theme.remoteStroke)
                .frame(width: seg.width, height: seg.height)
                .position(x: seg.midX, y: seg.midY)
                .allowsHitTesting(false)
            ZStack {
                Circle().fill(active ? Theme.blue : Theme.remoteStroke)
                Image(systemName: v.localEdge.isVertical ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .position(x: seg.midX, y: seg.midY)
            .allowsHitTesting(false)
        }
        if let msg = dragMessage(rule: rule, view: v) {
            Text(msg.text)
                .font(.ui(12, .medium))
                .foregroundStyle(msg.isError ? Theme.red : Theme.amber)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(msg.isError ? Theme.red : Theme.amber, lineWidth: 1))
                .fixedSize()
                .position(x: min(max(rRect.midX, 190), size.width - 190), y: min(rRect.maxY + 22, size.height - 18))
                .allowsHitTesting(false)
        }
    }

    /// 蓝色可跨越段：4 点宽，骑在两屏相接的线上
    private func segmentRect(_ v: RuleView, local l: ScreenInfo, touch t: (lo: Double, hi: Double),
                             layout: PreviewLayout) -> CGRect {
        let mm: CGRect
        switch v.localEdge {
        case .right: mm = CGRect(x: l.mmW, y: t.lo, width: 0, height: t.hi - t.lo)
        case .left: mm = CGRect(x: 0, y: t.lo, width: 0, height: t.hi - t.lo)
        case .down: mm = CGRect(x: t.lo, y: l.mmH, width: t.hi - t.lo, height: 0)
        case .up: mm = CGRect(x: t.lo, y: 0, width: t.hi - t.lo, height: 0)
        }
        return layout.rect(mm).insetBy(dx: mm.width == 0 ? -2 : 0, dy: mm.height == 0 ? -2 : 0)
    }

    private func drag(local l: ScreenInfo, remote r: ScreenInfo, base: RuleView, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { g in
                let layout = dragLayout ?? PreviewLayout(local: l, remote: r, view: base, size: size)
                if dragLayout == nil { dragLayout = layout }
                let start = RuleDrag.remoteOrigin(base, local: l, remote: r)
                let p = CGPoint(x: start.x + g.translation.width / layout.scale,
                                y: start.y + g.translation.height / layout.scale)
                dragView = RuleDrag.snap(p, local: l, remote: r, base: base)
            }
            .onEnded { _ in
                if let v = dragView, let rule = model.selectedRule {
                    let cand = rule.updated(with: v, me: model.me.id)
                    let others = model.rules.filter { $0.id != rule.id }
                    if RuleCheck.problems(cand, others: others, screens: model.allScreens).isEmpty {
                        model.updateRule(rule.id, view: v)
                    }
                }
                clearDrag()
            }
    }

    /// 拖动中的说明：不能放下的原因（红）或盖住自家相通段的提醒（橙）
    private func dragMessage(rule: AdjacencyRule, view v: RuleView) -> (text: String, isError: Bool)? {
        guard dragView != nil || model.previewDragOverride != nil else { return nil }
        return RulePreview.message(model: model, rule: rule, view: v)
    }

    static func message(model: AppModel, rule: AdjacencyRule, view v: RuleView) -> (text: String, isError: Bool)? {
        let cand = rule.updated(with: v, me: model.me.id)
        let others = model.rules.filter { $0.id != rule.id }
        let problems = RuleCheck.problems(cand, others: others, screens: model.allScreens)
        for p in problems {
            switch p {
            case .overlap(let id):
                if let o = model.rules.first(where: { $0.id == id }) {
                    let n = model.ruleLabels(o)
                    return ("和规则「\(n.local) + \(n.remote)」在这条边上重叠，不能放在这里", true)
                }
                return ("和另一条规则在这条边上重叠，不能放在这里", true)
            case .tooShort(let mm):
                return ("两块屏挨着的长度至少 10 毫米（现在 \(Int(mm.rounded())) 毫米），不能放在这里", true)
            case .duplicatePair:
                return ("已有这两块屏的规则", true)
            case .missingScreen:
                return ("有一块屏现在没有接上，暂时不能调整", true)
            }
        }
        let warn = RuleCheck.warnings(cand, screensByDevice: [model.me.id: model.localScreens,
                                                             model.pairing?.peerID ?? "": model.peerScreens])
        if case .coversOwnShared(let sid)? = warn.first {
            let who = model.localScreens.contains { $0.id == sid } ? "本机" : "对方"
            return ("这一段原本通往\(who)另一块屏；放下后规则优先，光标会跨到另一台", false)
        }
        return nil
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("还没有相邻规则，光标现在跨不到另一台。").font(.ui(15, .semibold)).lh(15).foregroundStyle(Theme.text)
            Text("点下方「＋ 添加规则」选两块显示器；需要时按 Ctrl + Option + Cmd + L 紧急收回光标。")
                .font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 预览左上角的状态说明（规则失效、没有可用规则、对方离线）
    @ViewBuilder
    private var notices: some View {
        let lines = noticeLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .semibold))
                        Text(line).font(.ui(12)).lh(12)
                    }
                    .foregroundStyle(Theme.amber)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.92)))
            .allowsHitTesting(false)
        }
    }

    private var noticeLines: [String] {
        var out: [String] = []
        if model.linkStatus != .connected {
            out.append("对方离线：使用上次连接时的屏幕信息，修改会在重新连接后同步。")
        }
        if let rule = model.selectedRule, let v = rule.view(from: model.me.id) {
            let labels = model.screenLabels
            for id in [v.localScreen, v.remoteScreen] where !isPresent(id) {
                out.append("「\(labels[id] ?? "显示器")」现在没有接上，这条规则暂时失效，插回后自动恢复。")
            }
        }
        if !model.rules.isEmpty, model.crossingMap.activeViews.isEmpty {
            out.append("没有可用的规则：光标现在跨不到另一台，需要时按 Ctrl + Option + Cmd + L 紧急收回光标。")
        }
        return out
    }
}

/// 预览的缩放和摆放：两块屏按毫米等比例，最大每毫米 0.8 点，放不下整体缩小；居中
struct PreviewLayout {
    let scale: CGFloat
    let origin: CGPoint     // 毫米坐标 (0, 0) 在视图里的位置

    init(local l: ScreenInfo, remote r: ScreenInfo, view v: RuleView, size: CGSize) {
        let ro = RuleDrag.remoteOrigin(v, local: l, remote: r)
        let box = CGRect(x: 0, y: 0, width: l.mmW, height: l.mmH)
            .union(CGRect(x: ro.x, y: ro.y, width: r.mmW, height: r.mmH))
        let pad: CGFloat = 36
        let s = min(0.8, (size.width - 2 * pad) / box.width, (size.height - 2 * pad) / box.height)
        scale = max(s, 0.05)
        origin = CGPoint(x: (size.width - box.width * scale) / 2 - box.minX * scale,
                         y: (size.height - box.height * scale) / 2 - box.minY * scale)
    }

    func rect(_ mm: CGRect) -> CGRect {
        CGRect(x: origin.x + mm.minX * scale, y: origin.y + mm.minY * scale,
               width: mm.width * scale, height: mm.height * scale)
    }
}

/// 预览里的一块屏：设备名、屏幕名、物理尺寸、本机 / 对方、键鼠接在哪；非输入设备那台带「切换为输入设备」
private struct ScreenCard: View {
    @EnvironmentObject var model: AppModel
    let screen: ScreenInfo
    let isLocal: Bool
    let present: Bool
    let label: String

    var body: some View {
        let isInput = isLocal == model.isController
        let device = isLocal ? model.me.name : model.peerName
        let size = "\(Int(screen.mmW.rounded())) × \(Int(screen.mmH.rounded())) mm · \(screen.inches) 英寸"
            + (screen.estimated ? "（尺寸为估算）" : "")
        let role = (isLocal ? "本机 · " : "对方 · ") + (isInput ? "键盘鼠标接在这里" : "受控设备")
            + (present ? "" : " · 未接上")
        let roleColor = isLocal ? Theme.blue : Theme.sub
        let swap = Button("切换为输入设备") { model.dialog = .confirmSwap }
            .buttonStyle(KVMButtonStyle(kind: .secondary, size: 12, padV: 8, padH: 14, radius: 7))
            .minimumScaleFactor(1)
            .fixedSize()
        ZStack(alignment: .topTrailing) {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 6) {
                    Text(device).font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
                    Text(label).font(.ui(18, .semibold)).lh(18).foregroundStyle(Theme.text)
                    Text(size).font(.ui(11)).lh(11).foregroundStyle(Theme.sub)
                    Text(role).font(.ui(12)).lh(12).foregroundStyle(roleColor)
                    if !isInput { swap }
                }
                VStack(spacing: 4) {
                    Text(label).font(.ui(15, .semibold)).foregroundStyle(Theme.text)
                    Text(role).font(.ui(11)).foregroundStyle(roleColor)
                    if !isInput { swap }
                }
                VStack(spacing: 2) {
                    Text(label).font(.ui(12, .semibold)).foregroundStyle(Theme.text)
                    Text(isLocal ? "本机" : "对方").font(.ui(10)).foregroundStyle(roleColor)
                }
                Text(label).font(.ui(10, .semibold)).foregroundStyle(Theme.text)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !isLocal {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.sub.opacity(0.7))
                    .padding(8)
                    .help("拖动对方屏幕调整相邻关系")
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(isLocal ? Theme.localFill : Color.white))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(isLocal ? Theme.localStroke : Theme.remoteStroke,
                          style: StrokeStyle(lineWidth: 1, dash: present ? [] : [5, 4])))
        .opacity(present ? 1 : 0.6)
        .contentShape(Rectangle())
    }
}

// MARK: - 底部规则栏

private struct RuleBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showList = false

    var body: some View {
        HStack(spacing: 10) {
            Text("相邻规则").font(.ui(13)).foregroundStyle(Theme.sub)
            Button { showList.toggle() } label: {
                HStack(spacing: 8) {
                    if let r = model.selectedRule {
                        RuleTags(rule: r)
                    } else {
                        Text("还没有规则").font(.ui(12)).foregroundStyle(Theme.sub)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.sub)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.rules.isEmpty)
            .popover(isPresented: $showList, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rules) { r in
                        Button {
                            model.selectedRuleID = r.id
                            showList = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                    .opacity(r.id == model.selectedRule?.id ? 1 : 0)
                                RuleTags(rule: r)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .frame(minWidth: 360)
                .environmentObject(model)
            }
            Button("＋ 添加规则") { model.dialog = .addRule }
                .buttonStyle(KVMButtonStyle(size: 12, padV: 8, padH: 14, radius: 7))
            Button("删除规则") { model.requestDeleteRule() }
                .buttonStyle(KVMButtonStyle(kind: .secondary, size: 12, padV: 8, padH: 14, radius: 7))
                .disabled(model.rules.isEmpty)
        }
        .onChange(of: model.interactionResetToken) { _, _ in
            // 只复位「状态说显示、实际上没有弹出框窗口」这种不一致；真正显示着的不动
            if showList, !NSApp.windows.contains(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
                showList = false
            }
        }
    }
}

/// 规则名：本机显示器标签（蓝）+ 对方显示器标签（白）
struct RuleTags: View {
    @EnvironmentObject var model: AppModel
    let rule: AdjacencyRule

    var body: some View {
        let n = model.ruleLabels(rule)
        HStack(spacing: 6) {
            Text(n.local).font(.ui(12)).foregroundStyle(Theme.blue)
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.localFill))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.localStroke, lineWidth: 1))
            Text("+").font(.ui(12)).foregroundStyle(Theme.sub)
            Text(n.remote).font(.ui(12)).foregroundStyle(Theme.sub)
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
        }
        .lineLimit(1)
    }
}

struct StatusPill: View {
    let status: LinkStatus

    var body: some View {
        let (text, fg, dot, bg): (String, Color, Color, Color) = {
            switch status {
            case .connected: return ("已连接", Theme.greenText, Theme.green, Theme.greenBG)
            case .searching: return ("正在寻找对方", Theme.amber, Theme.amber, Theme.amberBG)
            case .offline: return ("对方不在线", Theme.sub, Theme.sub, Theme.offlineBG)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.ui(12, .medium)).lh(12).foregroundStyle(fg)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(fg)
                .frame(width: 12, height: 12)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(Capsule().fill(bg))
        .contentShape(Capsule())
        .fixedSize()
    }
}

// MARK: - 06A 添加相邻规则

struct AddRuleDialog: View {
    @EnvironmentObject var model: AppModel
    @State private var localPick: String?
    @State private var remotePick: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Text("添加相邻规则").font(.ui(22, .semibold)).lh(22).foregroundStyle(Theme.text)
                Spacer()
                Button { model.dialog = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sub)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.greyButton))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("先选两块显示器，再到预览里拖动设置它们的相邻关系。").font(.ui(12)).lh(12).foregroundStyle(Theme.sub)
            HStack(alignment: .top, spacing: 24) {
                column(device: model.me.name, isLocal: true, screens: model.localScreens, pick: $localPick)
                column(device: model.peerName, isLocal: false, screens: model.peerScreens, pick: $remotePick)
            }
            if let error {
                Text(error).font(.ui(12)).lh(12).foregroundStyle(Theme.red)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { model.dialog = nil }
                    .buttonStyle(KVMButtonStyle(kind: .grey, size: 13, padV: 9, padH: 18, radius: 7))
                Button("添加规则") {
                    guard let l = localPick, let r = remotePick else { return }
                    // 等这次点击处理完再加规则、关弹窗（见 AppModel.dialogAction）
                    model.dialogAction(.addRule) {
                        if let e = model.addRule(localScreen: l, remoteScreen: r) {
                            error = e
                        } else {
                            model.dialog = nil
                        }
                    }
                }
                .buttonStyle(KVMButtonStyle(size: 13, padV: 9, padH: 18, radius: 7))
                .disabled(localPick == nil || remotePick == nil || duplicateMessage != nil)
            }
        }
        .padding(28)
        .frame(width: 700, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .onAppear { pickDefaults() }
        .onChange(of: localPick) { _, _ in error = duplicateMessage }
        .onChange(of: remotePick) { _, _ in error = duplicateMessage }
    }

    private var duplicateMessage: String? {
        guard let l = localPick, let r = remotePick else { return nil }
        return model.rules.contains { Set([$0.aScreen, $0.bScreen]) == Set([l, r]) } ? "已有这条规则" : nil
    }

    /// 默认选一对还没有规则的屏
    private func pickDefaults() {
        for l in model.localScreens {
            for r in model.peerScreens where !model.rules.contains(where: { Set([$0.aScreen, $0.bScreen]) == Set([l.id, r.id]) }) {
                localPick = l.id
                remotePick = r.id
                return
            }
        }
        localPick = model.localScreens.first?.id
        remotePick = model.peerScreens.first?.id
    }

    private func column(device: String, isLocal: Bool, screens: [ScreenInfo], pick: Binding<String?>) -> some View {
        let labels = ScreenNaming.labels(screens)
        let accent = isLocal ? Theme.blue : Theme.sub
        let stroke = isLocal ? Theme.localStroke : Theme.remoteStroke
        let isInput = isLocal == model.isController
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device).font(.ui(14, .medium)).lh(14).foregroundStyle(Theme.text)
                Text((isLocal ? "本机 · " : "对方 · ") + (isInput ? "输入设备" : "受控设备"))
                    .font(.ui(11)).lh(11).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 10) {
                if screens.isEmpty {
                    Text(isLocal ? "读不到本机的显示器" : "还没收到对方的显示器信息（连上对方后才有）")
                        .font(.ui(12)).foregroundStyle(Theme.sub)
                }
                ForEach(Array(screens.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Rectangle().fill(stroke).frame(height: 1) }
                    Button { pick.wrappedValue = s.id } label: {
                        HStack(spacing: 10) {
                            radio(on: pick.wrappedValue == s.id, isLocal: isLocal)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(labels[s.id] ?? s.name).font(.ui(13)).foregroundStyle(accent)
                                Text((s.isMain ? "主屏 · " : "") + "\(s.inches) 英寸 · \(Int(s.mmW.rounded())) × \(Int(s.mmH.rounded())) mm"
                                     + (s.estimated ? "（尺寸为估算）" : ""))
                                    .font(.ui(10)).foregroundStyle(Theme.sub)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(isLocal ? Theme.localFill : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(stroke, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func radio(on: Bool, isLocal: Bool) -> some View {
        ZStack {
            Circle().fill(Color.white)
            Circle().strokeBorder(on ? (isLocal ? Theme.blue : Theme.remoteStroke) : Color(hex: 0xA2ADBD),
                                  lineWidth: on ? 1.5 : 1)
            if on { Circle().fill(isLocal ? Theme.blue : Theme.sub).frame(width: 8, height: 8) }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - 08 弹窗：连接状态说明、解除配对、切换输入设备、删除最后一条规则

/// 点连接状态标签才弹出；内容随当前状态变化
struct LinkInfoDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let close = { model.dialog = nil }
        switch model.linkStatus {
        case .searching:
            StateDialog(title: "正在寻找对方",
                        message: "已配对「\(model.peerName)」\n正在自动重连，无需重新配对。",
                        note: "关闭后继续在后台重连。", onClose: close) {
                Button("返回设备连接", action: close).buttonStyle(DialogButton())
            }
        case .offline:
            StateDialog(title: "对方不在线",
                        message: "无法连接「\(model.peerName)」。\n请确认对方已开机、MacKVM 正在运行，且处于同一局域网。",
                        note: "对方上线后自动连接。", onClose: close) {
                Button("知道了", action: close).buttonStyle(DialogButton())
            }
        case .connected:
            StateDialog(title: "已连接",
                        message: "已与「\(model.peerName)」建立加密连接。\n"
                            + (model.isController ? "本机正在操作对方。" : "本机由对方操作。"),
                        note: "断线后会自动重连，无需重新配对。", onClose: close) {
                Button("知道了", action: close).buttonStyle(DialogButton())
            }
        }
    }
}

struct UnpairConfirmDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StateDialog(title: "解除与「\(model.peerName)」的配对？",
                    message: model.linkStatus == .connected
                        ? "解除后，两台都会回到未配对状态。\n再次使用时需要重新配对。"
                        : "解除后，两台都会回到未配对状态（对方现在不在线，上线后自动同步）。\n再次使用时需要重新配对。",
                    onClose: { model.dialog = nil }) {
            Button("取消") { model.dialog = nil }
                .buttonStyle(KVMButtonStyle(kind: .grey, size: 12, padV: 6, padH: 12, radius: 6))
            Button("解除配对") { model.dialogAction(.confirmUnpair) { model.confirmUnpair() } }
                .buttonStyle(KVMButtonStyle(kind: .danger, size: 12, padV: 6, padH: 12, radius: 6))
        }
    }
}

struct SwapConfirmDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 本机现在是输入设备 → 要把对方设为输入设备；反之把本机设为输入设备
        let peerBecomesInput = model.isController
        StateDialog(title: peerBecomesInput ? "将「\(model.peerName)」设为输入设备？" : "将本机设为输入设备？",
                    message: peerBecomesInput
                        ? "请将键盘和鼠标接到「\(model.peerName)」。\n确认后，本机将由它控制。"
                        : "请将键盘和鼠标接到本机。\n确认后，本机将控制「\(model.peerName)」。",
                    onClose: { model.dialog = nil }) {
            Button("取消") { model.dialog = nil }
                .buttonStyle(KVMButtonStyle(kind: .grey, size: 12, padV: 6, padH: 12, radius: 6))
            Button("确认切换") { model.dialogAction(.confirmSwap) { model.confirmSwap() } }
                .buttonStyle(KVMButtonStyle(size: 12, padV: 6, padH: 12, radius: 6))
        }
    }
}

struct DeleteLastRuleDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StateDialog(title: "删除最后一条相邻规则？",
                    message: "删除后光标跨不到另一台。\n需要时按 Ctrl + Option + Cmd + L 紧急收回光标；之后可以再添加规则。",
                    onClose: { model.dialog = nil }) {
            Button("取消") { model.dialog = nil }
                .buttonStyle(KVMButtonStyle(kind: .grey, size: 12, padV: 6, padH: 12, radius: 6))
            Button("删除规则") {
                model.dialogAction(.confirmDeleteLastRule) {
                    if let id = model.selectedRule?.id { model.deleteRule(id) } else { model.dialog = nil }
                }
            }
                .buttonStyle(KVMButtonStyle(kind: .danger, size: 12, padV: 6, padH: 12, radius: 6))
        }
    }
}

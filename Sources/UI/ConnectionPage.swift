// 已配对的「设备连接」页（设计稿 06「屏幕相邻关系」）：
//   标题区：标题 + 连接状态标签（点了才弹说明，状态变化时不弹）+ 解除配对；固定提示一行；
//   主体：摆放屏幕的预览区。两台的全部显示器按物理尺寸（毫米）等比例画，放不下整体缩小。每块现在接着的屏都能拖：
//         靠近别的屏的边时吸附；落到和别的屏叠在一起的位置就弹回原处；松手后更新布局、从布局推导相邻规则并同步给对方
//         （见 AppModel.moveScreen 和 Layout.swift）。
//         本机屏和对方屏挨上的那一段边画成蓝色，段中间放一个双向箭头圆标，表示光标能从这里双向跨过去；
//         同一台的两块屏挨上只吸附、不高亮。拔掉的屏留在原处、画成灰的、不能拖。
//         「光标现在跨不到另一台」「对方离线」这类提示放在预览区下方，不弹窗。
// 配色：本机浅蓝底蓝边蓝字，对方白底灰边灰字，不随输入角色交换。
// 角色行：本机是主控时本机屏写「键盘鼠标接在这里」、对方屏写「受控设备」；本机是被控时本机屏写「由对方操作」、对方屏写「输入设备」。
// 「切换为输入设备」（即对调角色，先弹确认）总在对方的主屏上（设计稿 06 主控视角、06b 被控视角）。

import SwiftUI

extension Theme {
    static let localFill = Color(hex: 0xDFEAFE)
    static let localStroke = Color(hex: 0x729BE6)
    static let remoteStroke = Color(hex: 0xB4C1D4)
    static let previewBG = Color(hex: 0xEDF2FA)
    static let previewStroke = Color(hex: 0xE0E6EF)
    static let unpluggedFill = Color(hex: 0xEEF0F3)
}

struct ConnectionPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    Text(L.layoutTitle).font(.ui(26, .semibold)).lh(26).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    if model.canAddMoreDevices {
                        Button { model.openSeek() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                                Text(L.addDevice)
                            }
                        }
                        .buttonStyle(KVMButtonStyle(kind: .secondary, size: 13, weight: .medium, padV: 9, padH: 14))
                    }
                    let onlineCount = model.pairings.filter { model.status(for: $0.peerID) == .connected }.count
                    let pillText = model.pairings.count > 1 ? L.multiConnected(online: onlineCount, total: model.pairings.count) : nil
                    Button { model.dialog = .linkInfo } label: { StatusPill(status: model.linkStatus, overrideText: pillText) }
                        .buttonStyle(.plain)
                        .help(L.statusHelp)
                    if model.pairings.count <= 1 {
                        Button(L.unpair) { model.promptUnpair() }
                            .buttonStyle(KVMButtonStyle(kind: .secondary, size: 13, weight: .medium, padV: 9, padH: 16))
                    }
                }
                .frame(height: 38)
                Text(L.layoutSubtitle)
                    .font(.ui(13)).lh(13).foregroundStyle(Theme.sub)
            }
            .frame(height: 64)
            if model.pairings.count > 1 {
                PeerBar()
            }
            LayoutPreview()
                .frame(maxHeight: .infinity)
        }
    }
}

private struct PeerBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.pairings, id: \.peerID) { rec in
                    let st = model.status(for: rec.peerID)
                    let dot: Color = st == .connected ? Theme.green : (st == .searching ? Theme.amber : Theme.sub)
                    HStack(spacing: 6) {
                        Circle().fill(dot).frame(width: 6, height: 6)
                        Text(rec.peerName).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        if rec.isLinux {
                            Text(L.linuxTag)
                                .font(.ui(10, .medium))
                                .foregroundStyle(Theme.sub)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.windowBG))
                        }
                        Button { model.promptUnpair(rec.peerID) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.sub)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L.unpair)
                    }
                    .padding(.vertical, 5)
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                }
            }
        }
        .frame(height: 28)
    }
}

extension AppModel {
    /// 单台设备的屏幕标签映射（按设备各自算位置后缀，避免不同设备屏幕 ID 相同时冲突）
    func screenLabel(device: String, screen: ScreenInfo) -> String {
        let list = screensForDevice(device)
        if !list.isEmpty, let label = ScreenNaming.labels(list, L.lang)[screen.id] {
            return label
        }
        return L.screenName(screen)
    }

    /// 兼容旧调用：汇总全部屏幕标签
    var screenLabels: [String: String] {
        var out = ScreenNaming.labels(localScreens, L.lang)
        for list in peerScreensByDevice.values {
            for (k, v) in ScreenNaming.labels(list, L.lang) { out[k] = v }
        }
        for list in otherScreensByDevice.values {
            for (k, v) in ScreenNaming.labels(list, L.lang) { out[k] = v }
        }
        for (id, s) in knownScreens where out[id] == nil { out[id] = L.screenName(s) }
        return out
    }
}

// MARK: - 摆放屏幕的预览区

/// 预览区的缩放和摆放：全部屏按毫米等比例，最大每毫米 0.8 点，放不下整体缩小；在可用范围里居中
struct PreviewTransform {
    let scale: CGFloat
    let origin: CGPoint     // 布局里毫米坐标 (0, 0) 在视图里的位置

    /// bottomInset：预览区底部留给提示的高度
    init(rects: [CGRect], size: CGSize, bottomInset: CGFloat) {
        let box = rects.reduce(CGRect.null) { $0.union($1) }
        let pad: CGFloat = 34
        let h = size.height - bottomInset
        guard !box.isNull, box.width > 0, box.height > 0 else {
            scale = 0.5
            origin = CGPoint(x: size.width / 2, y: h / 2)
            return
        }
        scale = max(0.05, min(0.8, (size.width - 2 * pad) / box.width, (h - 2 * pad) / box.height))
        origin = CGPoint(x: (size.width - box.width * scale) / 2 - box.minX * scale,
                         y: (h - box.height * scale) / 2 - box.minY * scale)
    }

    func rect(_ mm: CGRect) -> CGRect {
        CGRect(x: origin.x + mm.minX * scale, y: origin.y + mm.minY * scale,
               width: mm.width * scale, height: mm.height * scale)
    }
}

/// 一段可跨越的相接边：本机屏和对方屏挨着的那一段（布局里的毫米坐标，横线或竖线）
private struct Seam: Identifiable {
    let id: String
    let mm: CGRect              // 宽或高为 0 的线段
    let horizontal: Bool        // 横向的边（上下挨着）
    let active: Bool            // 两块屏都接着
}

private struct LayoutPreview: View {
    @EnvironmentObject var model: AppModel
    /// 拖动中：哪块屏、吸附后的左上角（毫米），以及拖动开始时的缩放和摆放（拖动中不重新居中，免得别的屏跟着跑）
    @State private var drag: (key: String, origin: CGPoint, transform: PreviewTransform)?
    /// 手势进行中为 true；手势被系统取消（窗口失去 key、弹窗盖上来等）时 onEnded 不会被调用，但它一定会复位
    @GestureState private var gestureActive = false

    private static let space = "layoutPreview"

    var body: some View {
        GeometryReader { geo in
            let base = model.placedScreens
            let shown = displayed(base)
            let seams = seams(shown)
            let lines = noticeLines(seams: seams)
            let t = drag?.transform
                ?? PreviewTransform(rects: base.map(\.rect), size: geo.size, bottomInset: lines.isEmpty ? 0 : CGFloat(lines.count) * 22 + 6)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.previewBG)
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.previewStroke, lineWidth: 1)
                if base.isEmpty {
                    Text(L.layoutNoScreens)
                        .font(.ui(13)).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(shown, id: \.key) { s in
                    let r = t.rect(s.rect)
                    let dragging = s.key == draggingKey
                    ScreenCard(screen: s, label: model.screenLabel(device: s.device, screen: s.info), size: r.size,
                               blocked: dragging && isBlocked(s, among: shown))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        .zIndex(dragging ? 1 : 0)
                        .gesture(dragGesture(base.first { $0.key == s.key } ?? s, all: base, transform: t),
                                 including: s.present ? .all : .subviews)
                }
                ForEach(seams) { seam in
                    let r = t.rect(seam.mm)
                    let color = seam.active ? Theme.blue : Theme.remoteStroke
                    Rectangle().fill(color)
                        .frame(width: seam.horizontal ? r.width : 4, height: seam.horizontal ? 4 : r.height)
                        .position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                        .zIndex(2)
                    ZStack {
                        Circle().fill(color)
                        Image(systemName: seam.horizontal ? "arrow.up.arrow.down" : "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 26, height: 26)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
                    .zIndex(2)
                }
                notices(lines)
            }
            .coordinateSpace(name: Self.space)
        }
        .onChange(of: gestureActive) { _, active in
            // 正常结束时 onEnded 已先把 drag 清掉；这里还有值 = 手势被取消、没收到结束
            if !active, drag != nil { drag = nil }
        }
        .onChange(of: model.interactionResetToken) { _, _ in
            if drag != nil { drag = nil }
        }
    }

    private var draggingKey: String? {
        if let d = drag { return d.key }
        guard let o = model.previewDragOverride else { return nil }
        return o.device + "/" + o.screen
    }

    /// 正在拖的那块屏换到拖动位置（离屏自查时用 previewDragOverride 指定）
    private func displayed(_ base: [PlacedScreen]) -> [PlacedScreen] {
        var out = base
        if let d = drag, let i = out.firstIndex(where: { $0.key == d.key }) {
            out[i].x = d.origin.x
            out[i].y = d.origin.y
        } else if let o = model.previewDragOverride, let i = out.firstIndex(where: { $0.isSame(o.device, o.screen) }) {
            out[i].x = o.x
            out[i].y = o.y
        }
        return out
    }

    private func isBlocked(_ s: PlacedScreen, among all: [PlacedScreen]) -> Bool {
        all.contains { $0.key != s.key && ScreenLayout.overlaps($0.rect, s.rect) }
    }

    private func dragGesture(_ s: PlacedScreen, all: [PlacedScreen], transform: PreviewTransform) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { g in
                let t = drag?.transform ?? transform
                let raw = CGRect(x: s.x + g.translation.width / t.scale, y: s.y + g.translation.height / t.scale,
                                 width: s.info.mmW, height: s.info.mmH)
                let o = ScreenLayout.snapped(raw, among: all.filter { $0.key != s.key }.map(\.rect))
                drag = (s.key, o, t)
            }
            .onEnded { _ in
                guard let d = drag, d.key == s.key else { return }
                var moved = s
                moved.x = d.origin.x
                moved.y = d.origin.y
                withAnimation(.easeOut(duration: 0.2)) {
                    if !isBlocked(moved, among: all) {
                        model.moveScreen(device: s.device, screen: s.info.id, to: d.origin)
                    }
                    drag = nil
                }
            }
    }

    /// 任意两台不同设备的屏挨着够长的每一段（包括两台被控之间直接相接）
    private func seams(_ shown: [PlacedScreen]) -> [Seam] {
        var out: [Seam] = []
        for i in shown.indices {
            let l = shown[i]
            for j in (i + 1)..<shown.count {
                let r = shown[j]
                guard l.device != r.device, let c = ScreenLayout.crossable(l.rect, r.rect) else { continue }
                let a = l.rect, b = r.rect
                let mm: CGRect
                switch c.edge {
                case .right: mm = CGRect(x: a.maxX, y: max(a.minY, b.minY), width: 0, height: c.length)
                case .left: mm = CGRect(x: a.minX, y: max(a.minY, b.minY), width: 0, height: c.length)
                case .down: mm = CGRect(x: max(a.minX, b.minX), y: a.maxY, width: c.length, height: 0)
                case .up: mm = CGRect(x: max(a.minX, b.minX), y: a.minY, width: c.length, height: 0)
                }
                out.append(Seam(id: l.key + "|" + r.key, mm: mm, horizontal: c.edge.isVertical, active: l.present && r.present))
            }
        }
        return out
    }

    private func noticeLines(seams: [Seam]) -> [String] {
        var out: [String] = []
        if !seams.contains(where: \.active) {
            out.append(L.noticeNoCrossing)
        }
        if model.pairings.count > 1 {
            let offlineNames = model.pairings.filter { model.status(for: $0.peerID) != .connected }.map(\.peerName)
            if !offlineNames.isEmpty {
                out.append(L.noticeSomeOffline(offlineNames))
            }
        } else if model.linkStatus != .connected {
            out.append(L.noticeOffline)
        }
        return out
    }

    /// 预览区底部的提示（不弹窗）
    @ViewBuilder
    private func notices(_ lines: [String]) -> some View {
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
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
            .zIndex(3)
        }
    }
}

/// 预览里的一块屏：设备名、显示器名（带位置后缀）、物理尺寸、本机 / 对方、键鼠接在哪；
/// 对方的主屏带「切换为输入设备」；右上角是拖动把手。卡片放不下全部内容时依次省掉次要的行
private struct ScreenCard: View {
    @EnvironmentObject var model: AppModel
    let screen: PlacedScreen
    let label: String
    let size: CGSize
    let blocked: Bool       // 拖到和别的屏叠在一起的位置（松手会弹回原处）
    @State private var hoveringRemove = false

    private func remotePalette(for deviceID: String) -> (fill: Color, stroke: Color) {
        let remotes = model.pairings.map(\.peerID)
        let idx = remotes.firstIndex(of: deviceID) ?? 0
        switch idx {
        case 0: return (.white, Theme.remoteStroke)
        case 1: return (Color(hex: 0xEAF7F0), Color(hex: 0x78BE98))
        default: return (Color(hex: 0xF2EFFC), Color(hex: 0x9E8FE0))
        }
    }

    var body: some View {
        let s = screen.info
        let isLocal = screen.device == model.me.id
        let present = screen.present
        let canRemove = !present && model.canRemoveUnpluggedScreen(device: screen.device, screen: s.id)
        let isInput = screen.device == model.shared?.controllerID
        let device = model.deviceName(for: screen.device)
        let devScreens = model.screensForDevice(screen.device)
        let sameDevice = devScreens.count
        let sizeLine = L.screenSize(mmW: s.mmW, mmH: s.mmH, inches: s.inches, main: s.isMain && sameDevice > 1,
                                    estimated: s.estimated)
        let who = L.screenOwner(local: isLocal)
        let role = L.screenRole(local: isLocal, present: present, input: isInput)
        let ink = !present ? Theme.sub : (isLocal ? Theme.blue : Theme.sub)
        let palette: (fill: Color, stroke: Color) = isLocal ? (Theme.localFill, Theme.localStroke) : remotePalette(for: screen.device)
        // 「切换为输入设备」仅双 Mac 模式显示，放在对方主屏（设计稿 06 / 06b）
        let swapScreen = (devScreens.first { $0.isMain } ?? devScreens.first)?.id
        let showSwap = model.canSwapController && present && !isLocal && s.id == swapScreen
        let swap = Button(L.swapButton(controller: model.isController)) { model.dialog = .confirmSwap }
            .buttonStyle(SwapButtonStyle())
            .fixedSize()
        ZStack(alignment: .topTrailing) {
            ViewThatFits(in: .vertical) {
                if size.width >= 260 {
                    VStack(spacing: 4) {
                        Text(device).font(.ui(12)).lh(12)
                        Text(label).font(.ui(18, .semibold)).lh(18)
                        Text(sizeLine).font(.ui(11)).lh(11)
                        Text(role).font(.ui(12)).lh(12)
                        if showSwap { swap.padding(.top, 2) }
                    }
                }
                VStack(spacing: 2) {
                    Text(device).font(.ui(12)).lh(12)
                    Text(label).font(.ui(15, .semibold)).lh(15)
                    Text(sizeLine).font(.ui(11)).lh(11)
                    Text(role).font(.ui(11)).lh(11)
                    if showSwap { swap.padding(.top, 2) }
                }
                VStack(spacing: 3) {
                    Text(label).font(.ui(15, .semibold))
                    Text(role).font(.ui(11))
                    if showSwap { swap }
                }
                VStack(spacing: 2) {
                    Text(label).font(.ui(12, .semibold))
                    Text(present ? who : role).font(.ui(10))
                }
                Text(label).font(.ui(10, .semibold))
            }
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if present {
                DragHandle(color: isLocal ? Theme.localStroke : Theme.sub.opacity(0.55))
                    .padding(10)
                    .help(L.dragHandleHelp)
            } else if canRemove {
                Button {
                    model.removeUnpluggedScreen(device: screen.device, screen: s.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hoveringRemove ? Theme.red : Theme.sub)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.9)))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(hoveringRemove ? Theme.red.opacity(0.5) : Theme.border, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringRemove = $0 }
                .padding(6)
                .help(L.removeUnpluggedScreenHelp)
            }
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(!present ? Theme.unpluggedFill : palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(blocked ? Theme.red : (present ? palette.stroke : Theme.remoteStroke),
                          style: StrokeStyle(lineWidth: blocked ? 1.5 : 1, dash: present ? [] : [5, 4])))
        .contentShape(Rectangle())
    }
}

struct StatusPill: View {
    let status: LinkStatus
    var overrideText: String? = nil

    var body: some View {
        let (text, fg, dot, bg): (String, Color, Color, Color) = {
            switch status {
            case .connected: return (overrideText ?? L.linkStatusShort(status), Theme.greenText, Theme.green, Theme.greenBG)
            case .searching: return (overrideText ?? L.linkStatusShort(status), Theme.amber, Theme.amber, Theme.amberBG)
            case .offline: return (overrideText ?? L.linkStatusShort(status), Theme.sub, Theme.sub, Theme.offlineBG)
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

// MARK: - 08 弹窗：连接状态说明、解除配对、切换输入设备

/// 点连接状态标签才弹出；内容随当前状态变化（多设备时展示每台设备状态并支持单独解绑）
struct LinkInfoDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let close = { model.dialog = nil }
        if model.pairings.count > 1 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text(L.multiLinkInfoTitle).font(.ui(15, .semibold)).lh(15).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.sub)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.closeBG))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L.close)
                }
                VStack(spacing: 8) {
                    ForEach(model.pairings, id: \.peerID) { rec in
                        let st = model.status(for: rec.peerID)
                        let dot: Color = st == .connected ? Theme.green : (st == .searching ? Theme.amber : Theme.sub)
                        HStack(spacing: 8) {
                            Circle().fill(dot).frame(width: 7, height: 7)
                            Text(rec.peerName).font(.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            if rec.isLinux {
                                Text(L.linuxTag)
                                    .font(.ui(10, .medium))
                                    .foregroundStyle(Theme.sub)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.closeBG))
                            }
                            Spacer(minLength: 0)
                            Text(L.linkStatusShort(st)).font(.ui(11)).foregroundStyle(Theme.sub)
                            Button(L.unpair) { model.promptUnpair(rec.peerID) }
                                .buttonStyle(KVMButtonStyle(kind: .secondary, size: 11, padV: 4, padH: 9, radius: 5))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.windowBG))
                    }
                }
                Text(L.multiLinkInfoNote).font(.ui(11)).foregroundStyle(Theme.sub)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button(L.gotIt, action: close).buttonStyle(DialogButton())
                }
            }
            .padding(18)
            .frame(width: 440, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        } else {
            switch model.linkStatus {
            case .searching:
                StateDialog(title: L.searchingTitle,
                            message: L.searchingMessage(model.peerName),
                            note: L.searchingNote, onClose: close) {
                    Button(L.backToDevices, action: close).buttonStyle(DialogButton())
                }
            case .offline:
                StateDialog(title: L.offlineTitle,
                            message: L.offlineMessage(model.peerName),
                            note: L.offlineNote, onClose: close) {
                    Button(L.gotIt, action: close).buttonStyle(DialogButton())
                }
            case .connected:
                StateDialog(title: L.connectedTitle,
                            message: L.connectedMessage(model.peerName, controller: model.isController),
                            note: L.connectedNote, onClose: close) {
                    Button(L.gotIt, action: close).buttonStyle(DialogButton())
                }
            }
        }
    }
}

struct UnpairConfirmDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let targetID = model.unpairTargetID ?? model.pairings.first?.peerID ?? ""
        let targetName = model.pairings.first(where: { $0.peerID == targetID })?.peerName ?? model.peerName
        let online = model.status(for: targetID) == .connected
        let msg = model.pairings.count > 1
            ? L.unpairOneMessage(name: targetName, peerOnline: online)
            : L.unpairMessage(peerOnline: online)
        StateDialog(title: L.unpairTitle(targetName),
                    message: msg,
                    onClose: { model.unpairTargetID = nil; model.dialog = nil }) {
            Button(L.cancel) { model.unpairTargetID = nil; model.dialog = nil }
                .buttonStyle(KVMButtonStyle(kind: .grey, size: 12, padV: 6, padH: 12, radius: 6))
            Button(L.unpair) { model.dialogAction(.confirmUnpair) { model.confirmUnpair() } }
                .buttonStyle(KVMButtonStyle(kind: .danger, size: 12, padV: 6, padH: 12, radius: 6))
        }
    }
}

struct SwapConfirmDialog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 本机现在是输入设备 → 要把对方设为输入设备；反之把本机设为输入设备
        let peerBecomesInput = model.isController
        StateDialog(title: L.swapTitle(model.peerName, peerBecomesInput: peerBecomesInput),
                    message: L.swapMessage(model.peerName, peerBecomesInput: peerBecomesInput),
                    onClose: { model.dialog = nil }) {
            Button(L.cancel) { model.dialog = nil }
                .buttonStyle(KVMButtonStyle(kind: .grey, size: 12, padV: 6, padH: 12, radius: 6))
            Button(L.swapConfirm) { model.dialogAction(.confirmSwap) { model.confirmSwap() } }
                .buttonStyle(KVMButtonStyle(size: 12, padV: 6, padH: 12, radius: 6))
        }
    }
}

/// 屏幕卡片右上角的拖动把手：3×3 个小圆点
private struct DragHandle: View {
    let color: Color

    var body: some View {
        Canvas { ctx, _ in
            for i in 0..<3 {
                for j in 0..<3 {
                    ctx.fill(Path(ellipseIn: CGRect(x: Double(i) * 4, y: Double(j) * 4, width: 2, height: 2)), with: .color(color))
                }
            }
        }
        .frame(width: 10, height: 10)
    }
}

/// 屏幕卡片里「切换为输入设备」的按钮：白底灰边灰字，比页面上的次要按钮小一号
private struct SwapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12)).lh(12)
            .foregroundStyle(Theme.sub)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.remoteStroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

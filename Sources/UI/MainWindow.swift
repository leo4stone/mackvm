// 主窗口：900×620 的单窗口，SwiftUI 画全部内容（标题栏底色和右侧的「设备连接 / 光标特效」切换、「中文 / EN」语言开关、
// 各页、底栏、弹窗遮罩）。语言一变整棵视图按新语言重建（RootView 上的 .id），文案见 Strings.swift。
// 进程是 .accessory，打开窗口时临时激活本应用把窗口带到前台；关掉窗口只是隐藏，进程照常运行。
// 关窗口时顺手取消正在进行的配对流程（停止广播 / 停止查找），免得在看不见的地方一直广播。

import AppKit
import SwiftUI

let kWindowSize = NSSize(width: 900, height: 620)

final class MainWindowController: NSObject, NSWindowDelegate {
    let model: AppModel
    let window: NSWindow
    private var activeObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(origin: .zero, size: kWindowSize),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "MacKVM"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // 空工具栏让标题栏变成 52 点高，红绿灯在设计稿的 54 点标题栏里垂直居中
        let tb = NSToolbar(identifier: "MacKVMMain")
        window.toolbar = tb
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(srgbRed: 0xF7 / 255.0, green: 0xF8 / 255.0, blue: 0xFA / 255.0, alpha: 1)
        window.delegate = self
        let host = NSHostingView(rootView: RootView().environmentObject(model))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(kWindowSize)
        window.center()
    }

    /// 真实运行时才装（离屏渲染不装）：本应用重新激活时，复位弹窗以外的临时交互状态（预览里拖动中的屏）
    func startReactivationReset() {
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.resetTransientInteraction()
        }
    }

    /// 主窗口重新成为 key 时同样复位
    func windowDidBecomeKey(_ notification: Notification) { model.resetTransientInteraction() }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        ColorPanelController.shared.close()
        model.ripplePreview.pointerExited()
        switch model.dialog {
        case .invite, .codeRenewed:
            model.cancelInvite()
        case .seek, .noDevices, .enterCode:
            model.cancelSeek()
        case .pairSuccess, .linkInfo, .confirmSwap, .confirmUnpair:
            model.dialog = nil
        case nil:
            break
        }
    }
}

// MARK: - 根视图

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var language = LanguageSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            Group {
                if model.isPaired && model.tab == .ripple {
                    RipplePage()
                } else if model.isPaired {
                    ConnectionPage()
                } else {
                    HomePage()
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Footer()
        }
        .frame(width: kWindowSize.width, height: kWindowSize.height)
        .background(Theme.windowBG)
        .overlay { DialogLayer() }
        // 文案都按 L.lang 现取：换语言时让整棵视图重建，没有输入参数的子视图（如底栏）也会重画
        .id(language.current)
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
    }
}

/// 54 点高的标题栏：居中的图标加应用名，右侧「设备连接 / 光标特效」切换（未配对时只有「设备连接」），
/// 再往右是「中文 / EN」语言开关（未配对时也有）
struct TitleBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            // 内容铺满了标题栏区域，拖动窗口靠这个手势
            Theme.titleBG.gesture(WindowDragGesture())
            HStack(spacing: 8) {
                AppIconView(size: 22).foregroundStyle(Theme.text)
                Text("MacKVM").font(.ui(14, .semibold)).foregroundStyle(Theme.text)
            }
            .allowsHitTesting(false)
            HStack(spacing: 8) {
                Spacer()
                HStack(spacing: 2) {
                    tab(L.tabConnection, .connection)
                    if model.isPaired { tab(L.tabRipple, .ripple) }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.segmentBG))
                LanguageToggle(current: L.lang) { model.setLanguage($0) }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 54)
    }

    private func tab(_ title: String, _ t: MainTab) -> some View {
        let on = model.tab == t || !model.isPaired
        return Button {
            model.tab = t
        } label: {
            Text(title)
                .font(.ui(13, on ? .semibold : .regular)).lh(13)
                .foregroundStyle(on ? Theme.text : Theme.sub)
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.white : Theme.tabOff))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 「中文 / EN」语言开关：灰底胶囊里两段，当前语言那段白底加粗。标题栏和菜单栏菜单（StatusMenu 里用 AppKit 画的同款）各一个
struct LanguageToggle: View {
    let current: Language
    let set: (Language) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(L.languageZh, .zh)
            segment(L.languageEn, .en)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.segmentBG))
        .help(L.languageHelp)
    }

    private func segment(_ title: String, _ l: Language) -> some View {
        let on = current == l
        return Button {
            if !on { set(l) }
        } label: {
            Text(title)
                .font(.ui(12, on ? .semibold : .regular)).lh(12)
                .foregroundStyle(on ? Theme.text : Theme.sub)
                .padding(.vertical, 5)
                .padding(.horizontal, 7)
                .frame(minWidth: 33)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.white : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Footer: View {
    var body: some View {
        HStack {
            Text(L.footerBackground).font(.ui(11)).foregroundStyle(Theme.sub)
            Spacer()
            Text(L.footerHotkey).font(.ui(12, .medium)).foregroundStyle(Theme.sub)
        }
        .padding(.horizontal, 24)
        .frame(height: 47.5)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// 所有弹窗：半透明遮罩 + 居中的卡片
struct DialogLayer: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let d = model.dialog {
            ZStack {
                Theme.mask
                    .contentShape(Rectangle())
                    .onTapGesture {}   // 吃掉点击，遮罩下面的内容点不到
                Group {
                    switch d {
                    case .invite: InviteDialog()
                    case .codeRenewed: CodeRenewedDialog()
                    case .seek: SeekDialog()
                    case .noDevices: NoDevicesDialog()
                    case .enterCode(let dev): CodeDialog(device: dev)
                    case .pairSuccess: PairSuccessDialog()
                    case .linkInfo: LinkInfoDialog()
                    case .confirmUnpair: UnpairConfirmDialog()
                    case .confirmSwap: SwapConfirmDialog()
                    }
                }
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.10), radius: 20, y: 6)
            }
        }
    }
}

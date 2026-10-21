// 界面文案表：主窗口各页、各弹窗、菜单栏菜单里给人看的全部文字，中文和英文写在一起，一条一行。
//   - 当前语言存在 LanguageSettings.shared.current（全局唯一一份）；切换走 AppModel.setLanguage，
//     会记进本机状态文件（不在两台之间同步），界面立即刷新，不用重启。
//   - 默认语言跟系统：系统首选语言是 zh 开头就中文，否则英文；用户手动切过之后按记住的来。
//   - 界面代码一律通过 L.xxx 取文案：不带参数的是计算属性，要拼名字、数字的是函数。
//   - 英文以设计稿 design/v7 的英文页为准；设计稿没画到的（错误提示、少见状态）按同样语气补写。
//   - 日志（log()）不走这里，保持中文。显示器名字用系统给的，不翻译；只有本程序自己起的「内建屏幕」「显示器」翻译。

import Foundation
import Network

// MARK: - 语言

enum Language: String, Codable, CaseIterable {
    case zh, en

    /// 按系统首选语言判定默认语言：第一个首选语言是 zh 开头（zh-Hans-CN、zh-Hant-TW、zh 等）就中文，否则英文
    static func systemDefault(_ preferred: [String] = Locale.preferredLanguages) -> Language {
        guard let first = preferred.first?.lowercased() else { return .en }
        return first == "zh" || first.hasPrefix("zh-") || first.hasPrefix("zh_") ? .zh : .en
    }

    /// 启动时用哪种语言：记住过（用户手动切过）就按记住的，否则跟系统
    static func resolve(saved: Language?, preferred: [String] = Locale.preferredLanguages) -> Language {
        saved ?? systemDefault(preferred)
    }
}

/// 当前界面语言。主窗口根视图观察它、语言一变整棵视图重建；菜单栏菜单也订阅它、就地更新标题
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    @Published var current: Language = Language.systemDefault()
}

// MARK: - 文案表

enum L {
    static var lang: Language { LanguageSettings.shared.current }

    /// 按当前语言二选一
    static func tr(_ zh: String, _ en: String) -> String { lang == .zh ? zh : en }
    /// 按指定语言二选一（日志等必须固定中文的地方传 .zh）
    static func tr(_ lang: Language, _ zh: String, _ en: String) -> String { lang == .zh ? zh : en }

    // MARK: 标题栏、底栏、语言开关

    static var tabConnection: String { tr("设备连接", "Devices") }
    static var tabRipple: String { tr("光标特效", "Cursor Effects") }
    /// 语言开关两段的文字：两种语言下都一样，各自用本语言写
    static let languageZh = "中文"
    static let languageEn = "EN"
    static var languageHelp: String { tr("切换界面语言", "Change the interface language") }
    static var footerBackground: String { tr("关闭窗口后仍在后台运行 · 开机自动启动", "Runs in the background · Starts at login") }
    /// 「重置键鼠状态」按钮（底栏右侧、菜单栏菜单里各一个，只在本机是被控且已连接时显示）
    static var resetInput: String { tr("重置键鼠状态", "Reset Keyboard & Mouse State") }
    /// 按钮右侧的热键提示，两种语言一样
    static let resetHotkey = "⌃ ⌥ ⌘ L"
    static var resetInputHelp: String {
        tr("光标过到这台之后回不来时点这里：光标和键盘回到主控那台",
           "Use this if the cursor gets stuck on this Mac: the cursor and keyboard go back to the controlling Mac.")
    }

    // MARK: 菜单栏菜单

    static var menuOpen: String { tr("打开 MacKVM 主界面", "Open MacKVM Main Window") }
    static var menuLanguage: String { tr("语言", "Language") }
    static var menuQuit: String { tr("退出 MacKVM", "Quit MacKVM") }
    static var menuUnpaired: String { tr("尚未配对", "Not paired yet") }
    /// 菜单里的状态行：「● 已连接 · 对方名」
    static func menuStatus(_ s: LinkStatus, peer: String) -> String {
        "● " + linkStatusShort(s) + " · " + peer
    }
    /// 本机的角色：操作对方 / 被对方操作
    static func roleLine(controller: Bool) -> String {
        controller ? tr("本机操作对方", "This Mac controls the other Mac")
                   : tr("本机被对方操作", "The other Mac controls this Mac")
    }

    // MARK: 连接状态

    /// 连接状态标签、菜单状态行用的短说法
    static func linkStatusShort(_ s: LinkStatus) -> String {
        switch s {
        case .connected: return tr("已连接", "Connected")
        case .searching: return tr("正在寻找对方", "Looking for the other Mac")
        case .offline: return tr("对方不在线", "The other Mac is offline")
        }
    }

    // MARK: 02 未配对首页

    static var homeTitle: String { tr("从这台 Mac 开始", "Start with this Mac") }
    static var homeSubtitle: String {
        tr("尚未配对。请让两台 Mac 接入同一局域网，并在对方打开 MacKVM。",
           "Not paired yet. Connect both Macs to the same network and open MacKVM on the other Mac.")
    }
    static var homeControllerTitle: String { tr("我是主控", "I control the other Mac") }
    static var homeControllerLine: String { tr("键盘和鼠标接在这台 Mac 上", "The keyboard and mouse are connected here.") }
    static var homeControllerHint: String { tr("查找另一台 Mac，输入它显示的密钥。", "Find the other Mac and enter its pairing code.") }
    static var homeControllerButton: String { tr("添加被控设备", "Add controlled Mac") }
    static var homeControlledTitle: String { tr("我是被控", "This Mac is controlled") }
    static var homeControlledLine: String { tr("用另一台 Mac 的键鼠控制本机", "Use another Mac’s keyboard and mouse here.") }
    static var homeControlledHint: String { tr("显示配对密钥，等待另一台 Mac 连接。", "Show a pairing code and wait for the other Mac.") }
    static var homeControlledButton: String { tr("邀请主控设备", "Invite controlling Mac") }
    static var homeFootnote: String {
        tr("只需配对一次，以后开机或断线后都会自动重新连接。",
           "Pair once. Your Macs reconnect automatically after startup or a disconnection.")
    }

    // MARK: 03 发起邀请

    static var inviteTitle: String { tr("等待另一台 Mac 来连接", "Waiting for the other Mac") }
    static var inviteSubtitle: String {
        tr("在另一台 Mac 点击「添加被控设备」，选择本机并输入下方配对码。",
           "On the other Mac, click “Add controlled Mac”, select this Mac and enter the code below.")
    }
    static var inviteDeviceName: String { tr("本机设备名", "This Mac") }
    static var inviteRenewed: String {
        tr("密钥已自动更新 · 请让对方使用新密钥重新输入", "Pairing code updated · Ask the other Mac to enter the new code")
    }
    static var inviteBroadcasting: String { tr("正在局域网广播 · 等待配对…", "Discoverable on your network · Waiting to pair…") }
    static var inviteTrust: String { tr("请仅向你信任的设备提供此密钥。", "Only share this code with a device you trust.") }
    static var inviteCancel: String { tr("取消配对", "Cancel pairing") }
    static var inviteCancelNote: String { tr("取消后立即停止广播", "Cancelling stops discovery immediately") }

    // MARK: 04 查找设备

    static var seekTitle: String { tr("连接另一台 Mac", "Connect to another Mac") }
    static var seekSubtitle: String {
        tr("选择要连接的设备。对方需先点击「邀请主控设备」。", "Select a Mac. On that Mac, click “Invite controlling Mac” first.")
    }
    static var seekListTitle: String { tr("局域网设备", "Nearby Macs") }
    static var seekListNote: String { tr("持续查找中 · 列表自动更新", "Searching · This list updates automatically") }
    static var seekEmpty: String { tr("正在查找正在邀请的 Mac…", "Looking for Macs that are inviting…") }
    static var seekPair: String { tr("配对…", "Pair…") }
    static var cancel: String { tr("取消", "Cancel") }

    // MARK: 05 输入配对码

    static func codeTitle(_ device: String) -> String { tr("与「\(device)」配对", "Pair with “\(device)”") }
    static var codeSubtitle: String { tr("输入对方屏幕上显示的 8 位配对码", "Enter the 8-digit code shown on the other Mac") }
    static var codePlaceholder: String { tr("8 位数字", "8 digits") }
    static var codePair: String { tr("配对", "Pair") }
    static var codePairing: String { tr("配对中…", "Pairing…") }

    /// 输入配对码时的错误提示。lang：日志里记中文时传 .zh
    static func codeError(_ e: CodeError, _ lang: Language = L.lang) -> String {
        switch e {
        case .incomplete:
            return tr(lang, "请输入完整的 8 位配对码", "Enter all 8 digits of the pairing code.")
        case .wrongCode(let left):
            return tr(lang, "配对码不正确，请重新输入（还可再试 \(left) 次）",
                      "Incorrect code. Please try again (\(left) \(left == 1 ? "attempt" : "attempts") left).")
        case .renewed:
            return tr(lang, "输错次数过多，对方已换了新的配对码，请输入对方屏幕上的新配对码",
                      "Too many incorrect attempts. The other Mac has a new code; enter the new code shown on it.")
        case .busy:
            return tr(lang, "对方正在和别的设备配对，请稍后再试",
                      "The other Mac is pairing with another device. Please try again later.")
        case .failed(let why):
            // 英文界面不带原因：原因是协议层的中文诊断，写在日志里
            return tr(lang, "没能完成配对（\(why)）。请确认对方仍在等待配对",
                      "Couldn’t complete pairing. Make sure the other Mac is still waiting to pair.")
        }
    }

    /// 局域网查找 / 广播出问题时的提示。原文来自 describeNetworkError 和配对监听（同时写进日志，保持中文），
    /// 这里把认得出的几种换成英文；认不出的是系统给的错误描述，原样显示
    static func networkProblem(_ raw: String) -> String {
        guard lang == .en else { return raw }
        if raw == describeNetworkError(NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))) {
            return "No Local Network access. Turn on MacKVM in System Settings → Privacy & Security → Local Network."
        }
        let listenPrefix = "创建监听失败："
        if raw.hasPrefix(listenPrefix) {
            return "Couldn’t start listening: " + raw.dropFirst(listenPrefix.count)
        }
        return raw
    }

    // MARK: 06 设备连接

    static var layoutTitle: String { tr("屏幕相邻关系", "Display arrangement") }
    static var layoutSubtitle: String {
        tr("拖动屏幕自由摆放，蓝色相接边段可跨屏，拖开即停止跨屏。",
           "Drag displays to arrange them. Cross at blue shared edges; move them apart to stop crossing.")
    }
    static var statusHelp: String { tr("查看连接状态说明", "Show connection details") }
    static var unpair: String { tr("解除配对", "Unpair") }
    static var layoutNoScreens: String {
        tr("还没读到显示器信息，连上对方后会显示。", "No display information yet. It appears once the Macs connect.")
    }
    static var noticeNoCrossing: String {
        tr("光标现在跨不到另一台。需要时按 Ctrl + Option + Cmd + L 重置键鼠状态。",
           "The cursor can’t reach the other Mac right now. Press Ctrl + Option + Cmd + L to reset keyboard & mouse state.")
    }
    static var noticeOffline: String {
        tr("对方离线：使用上次连接信息，重连后同步。",
           "The other Mac is offline: showing the last known layout. Changes sync when it reconnects.")
    }
    static var dragHandleHelp: String { tr("拖动摆放这块屏幕", "Drag to arrange this display") }
    /// 对方屏上的「切换为输入设备」（对调角色）。英文按设计稿分两种：本机是主控时在对方（被控）屏上写「Use as input device」，
    /// 本机是被控时在对方（主控）屏上写「Use This Mac for Input」
    static func swapButton(controller: Bool) -> String {
        tr("切换为输入设备", controller ? "Use as input device" : "Use This Mac for Input")
    }

    /// 屏幕卡片的尺寸行：「599 × 340 mm · 27 英寸 · 主屏」
    static func screenSize(mmW: Double, mmH: Double, inches: Int, main: Bool, estimated: Bool) -> String {
        "\(Int(mmW.rounded())) × \(Int(mmH.rounded())) mm · " + tr("\(inches) 英寸", "\(inches)-inch")
            + (main ? tr(" · 主屏", " · Main") : "") + (estimated ? tr("（尺寸为估算）", " (estimated size)") : "")
    }
    /// 屏幕卡片上「本机 / 对方」
    static func screenOwner(local: Bool) -> String { local ? tr("本机", "This Mac") : tr("对方", "Other Mac") }
    /// 屏幕卡片的角色行（设计稿 06 主控视角、06b 被控视角）：
    ///   本机是主控：「本机 · 键盘鼠标接在这里」「对方 · 受控设备」；本机是被控：「本机 · 由对方操作」「对方 · 输入设备」；
    ///   拔掉的屏：「本机 / 对方 · 未接上」
    static func screenRole(local: Bool, present: Bool, input: Bool) -> String {
        let who = screenOwner(local: local)
        guard present else { return who + " · " + tr("未接上", "Unplugged") }
        let what: String
        switch (local, input) {
        case (true, true): what = tr("键盘鼠标接在这里", "Keyboard and mouse connected")
        case (false, true): what = tr("输入设备", "Input device")
        case (true, false): what = tr("由对方操作", "Controlled by other Mac")
        case (false, false): what = tr("受控设备", "Controlled")
        }
        return who + " · " + what
    }

    // MARK: 显示器名字与位置后缀

    /// 显示器的显示名：系统给的名字原样用；本程序自己起的「内建屏幕」「显示器」（读不到名字时）按语言翻译
    static func screenName(_ s: ScreenInfo, _ lang: Language = L.lang) -> String {
        if s.isBuiltin { return tr(lang, "内建屏幕", "Built-in display") }
        if s.name == "显示器" { return tr(lang, "显示器", "Display") }
        return s.name
    }

    /// 位置后缀：中文横向在前、纵向在后（「左上」）；英文纵向在前（「Top Left」），两个方向都在中间时只写一个 Center
    static func positionSuffix(_ p: ScreenPosition, _ lang: Language = L.lang) -> String {
        if lang == .zh {
            let h: String? = p.column.map { ["左", "中", "右"][$0.rawValue] }
            let v: String? = p.row.map { ["上", "中", "下"][$0.rawValue] }
            return (h ?? "") + (v ?? "")
        }
        if p.column == .middle && p.row == .middle { return "Center" }
        let h: String? = p.column.map { ["Left", "Center", "Right"][$0.rawValue] }
        let v: String? = p.row.map { ["Top", "Middle", "Bottom"][$0.rawValue] }
        return [v, h].compactMap { $0 }.joined(separator: " ")
    }

    /// 带后缀的完整标签：中文「DELL U2720QM（左）」（全角括号、前面不空格），英文「DELL U2720QM (Left)」（半角括号、前面空一格）
    static func screenLabel(_ s: ScreenInfo, position: ScreenPosition?, _ lang: Language = L.lang) -> String {
        let name = screenName(s, lang)
        guard let p = position else { return name }
        let suffix = positionSuffix(p, lang)
        guard !suffix.isEmpty else { return name }
        return lang == .zh ? "\(name)（\(suffix)）" : "\(name) (\(suffix))"
    }

    // MARK: 07 光标特效

    static var rippleTitle: String { tr("让光标的去向清晰可见", "Keep your cursor in sight") }
    static var rippleSubtitle: String {
        tr("跨设备时显示波纹 · 修改立即生效，并同步到另一台", "Ripples show where your cursor goes. Changes apply to both Macs.")
    }
    static var rippleReset: String { tr("恢复默认值", "Reset defaults") }
    static func rippleSwitchState(_ on: Bool) -> String { on ? tr("已开启", "On") : tr("已关闭", "Off") }
    static func rippleSwitchHelp(_ on: Bool) -> String {
        on ? tr("关闭光标特效", "Turn off cursor effects") : tr("开启光标特效", "Turn on cursor effects")
    }
    /// 页面底部一行：进入波纹的持续时间说明
    static func rippleFootnote(min: String, idle: String, max: String) -> String {
        tr("鼠标越过两张卡片中间的分界线即可体验波纹；进入波纹至少持续 \(min) 秒，停下 \(idle) 秒后停止出环，最长 \(max) 秒。",
           "Move left to right to preview. Entry ripples run for \(min)–\(max) s and stop after \(idle) s idle.")
    }
    static var leaveRipple: String { tr("离开波纹", "Exit ripple") }
    static var arriveRipple: String { tr("进入波纹", "Entry ripple") }
    static var leaveRippleNote: String {
        tr("光标离开一块屏幕时，在离开位置向外扩散出环", "Move out of this card to preview the exit ripple.")
    }
    static var arriveRippleNote: String {
        tr("光标进入一块屏幕时，沿移动轨迹连续出环", "Move into this card to preview a trail of ripples.")
    }
    static var ringSize: String { tr("环的大小", "Ring size") }
    static var ringDuration: String { tr("每个环的时长", "Duration per ring") }
    static var ringInterval: String { tr("出环间隔", "Ring interval") }
    static var leaveTotal: String { tr("持续时间", "Duration") }
    static var minDuration: String { tr("至少持续", "Minimum duration") }
    static var idleStop: String { tr("停下判定时间", "Idle threshold") }
    static var maxDuration: String { tr("最长持续", "Maximum duration") }
    static var rippleColors: String { tr("波纹颜色", "Ripple colors") }
    static var colorSwatchHelp: String { tr("点按修改颜色；右键可删除", "Click to change the color; right-click to remove it") }
    static var colorDelete: String { tr("删除这个颜色", "Remove this color") }
    static var colorAdd: String { tr("添加颜色", "Add a color") }
    /// 取色器里 HEX 输入框的标签，两种语言一样
    static let colorHex = "HEX"
    /// 步进框里的秒数：「0.4 秒」「0.4 s」
    static func secondsValue(_ v: String) -> String { tr("\(v) 秒", "\(v) s") }

    // MARK: 08 状态弹窗

    static var close: String { tr("关闭", "Close") }
    static var gotIt: String { tr("知道了", "Got it") }

    static var searchingTitle: String { tr("正在寻找对方", "Looking for the other Mac") }
    static func searchingMessage(_ peer: String) -> String {
        tr("已配对「\(peer)」\n正在自动重连，无需重新配对。",
           "Paired with \(peer).\nReconnecting automatically; no need to pair again.")
    }
    static var searchingNote: String { tr("关闭后继续在后台重连。", "Reconnection continues after closing.") }
    static var backToDevices: String { tr("返回设备连接", "Back to Devices") }

    static var offlineTitle: String { tr("对方不在线", "The other Mac is offline") }
    static func offlineMessage(_ peer: String) -> String {
        tr("无法连接「\(peer)」。\n请确认对方已开机、MacKVM 正在运行，且处于同一局域网。",
           "Cannot reach \(peer).\nMake sure it is on, running MacKVM and on the same network.")
    }
    static var offlineNote: String { tr("对方上线后自动连接。", "Connects automatically when the Mac is back online.") }

    static var connectedTitle: String { tr("已连接", "Connected") }
    static func connectedMessage(_ peer: String, controller: Bool) -> String {
        tr("已与「\(peer)」建立加密连接。\n", "Encrypted connection established with \(peer).\n")
            + (controller ? tr("本机正在操作对方。", "This Mac controls the other Mac.")
                          : tr("本机由对方操作。", "The other Mac controls this Mac."))
    }
    static var connectedNote: String {
        tr("断线后会自动重连，无需重新配对。", "Reconnects automatically after a disconnection; no need to pair again.")
    }

    static var noDevicesTitle: String { tr("没找到可配对的设备", "No Macs found") }
    static var noDevicesMessage: String {
        tr("请在另一台 Mac 点击「邀请主控设备」，并确认两台处于同一局域网。",
           "Click “Invite controlling Mac” on the other Mac. Both Macs must be on the same network.")
    }
    static var noDevicesNote: String {
        tr("设备列表持续更新；取消查找可返回角色选择。", "The list keeps updating. Cancel to return to role selection.")
    }
    static var cancelSearch: String { tr("取消查找", "Cancel search") }
    static var keepSearching: String { tr("继续查找", "Keep searching") }

    static var renewedTitle: String { tr("密钥已自动更新", "Pairing code updated") }
    static func renewedMessage(_ code: String) -> String {
        tr("对方连续 5 次输错密钥，旧密钥已作废。\n新密钥：\(code)",
           "The code was entered incorrectly 5 times and has expired.\nNew code: \(code)")
    }
    static var renewedNote: String {
        tr("查看新密钥并告知对方；取消邀请将停止广播。",
           "Share the new code with the other Mac. Cancel the invitation to stop discovery.")
    }
    static var cancelInvitation: String { tr("取消邀请", "Cancel invitation") }
    static var viewNewCode: String { tr("查看新密钥", "View new code") }

    static var pairSuccessTitle: String { tr("配对成功", "Paired successfully") }
    static func pairSuccessMessage(_ peer: String, controller: Bool) -> String {
        controller
            ? tr("已与「\(peer)」配对。\n本机操作对方，从蓝色相接边段推出光标即可切过去。",
                 "Paired with \(peer).\nThis Mac now controls it. Move the cursor across a blue shared edge to switch.")
            : tr("已与「\(peer)」配对。\n本机由对方操作，局域网广播已停止。",
                 "Paired with \(peer).\nIt now controls this Mac. Network discovery has stopped.")
    }
    static var pairSuccessDone: String { tr("完成，查看设备连接", "Done, view devices") }

    static func unpairTitle(_ peer: String) -> String { tr("解除与「\(peer)」的配对？", "Unpair \(peer)?") }
    static func unpairMessage(peerOnline: Bool) -> String {
        peerOnline
            ? tr("解除后，两台都会回到未配对状态。\n再次使用时需要重新配对。",
                 "Both Macs will become unpaired.\nYou will need to pair them again to reconnect.")
            : tr("解除后，两台都会回到未配对状态（对方现在不在线，上线后自动同步）。\n再次使用时需要重新配对。",
                 "Both Macs will become unpaired (the other Mac is offline and will be updated when it comes back).\nYou will need to pair them again to reconnect.")
    }

    static func swapTitle(_ peer: String, peerBecomesInput: Bool) -> String {
        peerBecomesInput ? tr("将「\(peer)」设为输入设备？", "Use \(peer) for input?")
                         : tr("将本机设为输入设备？", "Use this Mac for input?")
    }
    static func swapMessage(_ peer: String, peerBecomesInput: Bool) -> String {
        peerBecomesInput
            ? tr("请将键盘和鼠标接到「\(peer)」。\n确认后，本机将由它控制。",
                 "Connect your keyboard and mouse to \(peer).\nAfter switching, it will control this Mac.")
            : tr("请将键盘和鼠标接到本机。\n确认后，本机将控制「\(peer)」。",
                 "Connect your keyboard and mouse to this Mac.\nAfter switching, this Mac will control \(peer).")
    }
    static var swapConfirm: String { tr("确认切换", "Switch input device") }
}

// MARK: - 显示器标签（带位置后缀）

extension ScreenNaming {
    /// 每块屏的位置后缀；只有一块屏时都是空字符串
    static func suffixes(_ screens: [ScreenInfo], _ lang: Language) -> [String: String] {
        positions(screens).mapValues { L.positionSuffix($0, lang) }
    }

    /// 带后缀的完整标签，见 L.screenLabel
    static func labels(_ screens: [ScreenInfo], _ lang: Language) -> [String: String] {
        let pos = positions(screens)
        var out: [String: String] = [:]
        for s in screens { out[s.id] = L.screenLabel(s, position: pos[s.id], lang) }
        return out
    }
}

// 全局状态与调度中心（界面、菜单栏都只读它的状态、调它的方法）：
//   - 读写持久化状态（Settings.swift 的 Store）；
//   - 未配对时：管「发起邀请」（PairingInviter）和「查找设备 + 输入配对码」（BonjourBrowser + PairingSeeker）；
//   - 已配对时：起 Link 保持连接，按共享设置里的主控 ID 起主控角色或被控角色，运行中可以随时切换；
//   - 两台之间同步共享设置（屏幕布局和相邻规则、角色、波纹参数），处理解除配对、对调角色；
//   - 两台互相交换屏幕清单；配对后由主控生成一次默认布局；旧数据只有规则时按规则摆出布局；
//   - 用户在「设备连接」页摆放屏幕：更新布局、从布局推导相邻规则，一起同步给对方；
//   - 给界面算连接状态：已连接 / 正在寻找对方 / 对方不在线。
//   - 界面语言的切换和记忆（只存本机；当前语言在 LanguageSettings，文案表见 UI/Strings.swift）。
// 所有方法都只在主线程调用（网络回调都排在主队列上）。

import AppKit
import Combine
import CryptoKit
import Foundation
import IOKit.ps
import Network
import SystemConfiguration

enum LinkStatus: Equatable {
    case connected      // 已连接
    case searching      // 正在寻找对方（刚启动或刚断线，正在自动重连）
    case offline        // 对方不在线（找了一阵还没连上）
}

enum MainTab { case connection, ripple }

enum Dialog: Equatable {
    case invite                         // 03 被控方：显示配对码，正在广播
    case codeRenewed                    // 08 被控方：对方输错 5 次，配对码已换新
    case seek                           // 04 主控方：局域网设备列表
    case noDevices                      // 08 主控方：查找一阵仍没有可配对设备
    case enterCode(DiscoveredDevice)    // 05 主控方：输入 8 位配对码
    case pairSuccess                    // 配对成功
    case linkInfo                       // 08 点击连接状态标签才弹出的说明（状态变化时绝不自动弹）
    case confirmUnpair                  // 解除配对确认
    case confirmSwap                    // 切换输入设备（对调角色）确认
}

/// 输入配对码时的错误（给人看的文字在界面层按当前语言拼，见 L.codeError）
enum CodeError: Equatable {
    case incomplete                 // 没输满 8 位
    case wrongCode(left: Int)       // 配对码不对，还能再试几次
    case renewed                    // 输错太多次，对方已换码
    case busy                       // 对方正在和别的设备配对
    case failed(String)             // 网络或协议问题（原因是中文诊断，只有中文界面显示）
}

/// 连上之后互相告知的本机信息
struct PeerInfo: Codable {
    var id: String
    var name: String
    var laptop: Bool
    var version: String
    var platform: String? = nil
}

final class AppModel: ObservableObject {
    let store: Store?
    var state: PersistedState
    let me: DeviceIdentity

    @Published var pairings: [PairingRecord] = []
    var pairing: PairingRecord? {
        get { pairings.first }
        set { pairings = newValue.map { [$0] } ?? [] }
    }
    @Published var shared: SharedSettings?
    @Published var localRipple: RippleConfig
    @Published var linkStatus: LinkStatus = .searching
    @Published var peerStatuses: [String: LinkStatus] = [:]
    @Published var tab: MainTab = .connection
    @Published var dialog: Dialog?
    @Published var unpairTargetID: String? = nil
    @Published var lastPairedName = ""
    /// 加 1 = 让界面把弹窗以外的临时交互状态（预览里拖动中的屏）复位；主窗口重新成为 key、应用重新激活时由 MainWindowController 触发
    @Published var interactionResetToken = 0
    // 发起邀请
    @Published var inviteCode = ""
    @Published var inviteRenewed = false
    @Published var inviteProblem: String?
    // 查找设备 / 输入配对码
    @Published var seekDevices: [DiscoveredDevice] = []
    @Published var seekProblem: String?
    @Published var codeInput = ""
    @Published var codeError: CodeError?
    @Published var pairingBusy = false

    /// 界面层注册：把主窗口叫到前台
    var showWindowHandler: (() -> Void)?
    /// 07 页卡片预览（两张卡片模拟两块并排屏幕）的状态
    let ripplePreview = RipplePreviewModel()

    // 屏幕、布局与相邻规则
    @Published var localScreens: [ScreenInfo] = [] { didSet { cachedMap = nil } }
    @Published var peerScreensByDevice: [String: [ScreenInfo]] = [:] { didSet { cachedMap = nil } }
    var peerScreens: [ScreenInfo] {
        get { peerID.isEmpty ? [] : (peerScreensByDevice[peerID] ?? []) }
        set {
            guard !peerID.isEmpty else { return }
            peerScreensByDevice[peerID] = newValue
            cachedMap = nil
        }
    }
    /// 被控端收到的主控及其它在线被控设备的屏幕清单（用于被控 ↔ 被控直接跨屏）
    @Published var otherScreensByDevice: [String: [ScreenInfo]] = [:] { didSet { cachedMap = nil } }
    /// 这一次连接里是否已经收到过首台对方的屏幕清单（兼容单对端预览与日志）
    var peerScreensFresh: Bool {
        get { !peerID.isEmpty && peerScreensFreshByDevice.contains(peerID) }
        set {
            guard !peerID.isEmpty else { return }
            if newValue { peerScreensFreshByDevice.insert(peerID) }
            else { peerScreensFreshByDevice.remove(peerID) }
        }
    }
    /// 所有见过屏幕的信息（按 ID）：布局里的屏拔掉了，界面上还能显示它的名字和尺寸
    @Published var knownScreens: [String: ScreenInfo] = [:]
    /// 只给离屏自查用：非 nil 时 06 页预览按「这块屏正被拖到这个位置」显示
    @Published var previewDragOverride: ScreenSpot?
    private var cachedMap: CrossingMap?
    private var peerSettingsSeenByDevice: Set<String> = []
    private var peerScreensFreshByDevice: Set<String> = []
    private var linkChangedAtByDevice: [String: Date] = [:]
    private var screenObserver: NSObjectProtocol?

    private var hub: LinkHub?
    private var controller: ControllerRole?
    private var controlled: ControlledRole?
    private var inviter: PairingInviter?
    private var browser: BonjourBrowser?
    private var seeker: PairingSeeker?
    private var linkChangedAt = Date()
    private var statusTimer: Timer?

    init(store: Store) {
        self.store = store
        var s = store.load()
        var loadedPairings = s.pairings ?? s.pairing.map { [$0] } ?? []
        loadedPairings = loadedPairings.filter { $0.key != nil }
        if loadedPairings.isEmpty || s.shared == nil {
            if !loadedPairings.isEmpty || s.pairing != nil { log("警告：配对记录不完整，按未配对处理") }
            loadedPairings = []
            s.pairing = nil
            s.pairings = nil
            s.shared = nil
        }
        if s.pendingUnpairs == nil, let pu = s.pendingUnpair {
            s.pendingUnpairs = [pu]
        }
        state = s
        // 界面语言：用户手动切过就按记住的，否则跟系统（只存本机，不在各台之间同步）
        LanguageSettings.shared.current = Language.resolve(saved: s.language)
        me = DeviceIdentity(id: s.deviceID, name: currentComputerName(), isLaptop: hasInternalBattery())
        pairings = loadedPairings
        shared = s.shared
        localRipple = s.ripple.sanitized()
        var byDev = s.peerScreensByDevice ?? [:]
        if byDev.isEmpty, let first = loadedPairings.first, let ps = s.peerScreens {
            byDev[first.peerID] = ps
        }
        peerScreensByDevice = byDev
        knownScreens = Dictionary((s.knownScreens ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }

    /// 只给离屏渲染等验证代码用：不读盘、不起任何服务
    init(preview me: DeviceIdentity) {
        store = nil
        state = PersistedState(deviceID: me.id)
        self.me = me
        localRipple = .defaults
    }

    /// 切换界面语言（标题栏和菜单栏的「中文 / EN」开关）：立即生效，记进本机状态文件，下次启动按记住的来
    func setLanguage(_ l: Language) {
        let changed = l != LanguageSettings.shared.current
        if changed { LanguageSettings.shared.current = l }
        guard state.language != l else { return }
        state.language = l
        persist()
        if changed { log("界面语言切换为\(l == .zh ? "中文" : "英文")") }
    }

    /// 复位弹窗以外的临时交互状态（兜底：拖动被打断没收到结束、弹出框状态和实际不一致）
    func resetTransientInteraction() {
        if store != nil { previewDragOverride = nil }   // 只有离屏自查会设它；真实运行时有值就是残留
        interactionResetToken &+= 1
    }

    /// 弹窗里「确认 / 添加」这类按钮：等这次鼠标事件处理完、按钮的点按手势结束后再改状态。
    /// 在按钮自己的动作里同步关弹窗、改规则，会把按钮所在的视图树在点按手势结束前拆掉，界面可能点不动。
    /// 只在弹窗仍是 expected 时执行，防止连点执行两次。
    func dialogAction(_ expected: Dialog, _ f: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dialog == expected else { return }
            f()
        }
    }

    // MARK: - 派生状态

    var isPaired: Bool { !pairings.isEmpty && shared != nil }
    var isController: Bool { shared?.controllerID == me.id }
    var canAddMoreDevices: Bool { isPaired && isController }
    var canSwapController: Bool {
        guard isPaired, pairings.count == 1, let first = pairings.first, !first.isLinux else { return false }
        if let devs = shared?.devices, devs.contains(where: \.isLinux) || devs.count > 2 { return false }
        return true
    }
    var peerName: String { pairing?.peerName ?? "" }
    var rules: [AdjacencyRule] { shared?.rules ?? [] }
    var peerID: String { pairing?.peerID ?? "" }

    func deviceName(for id: String) -> String {
        if id == me.id { return me.name }
        if let rec = pairings.first(where: { $0.peerID == id }) { return rec.peerName }
        if let d = shared?.devices.first(where: { $0.id == id }) { return d.name }
        return id
    }

    func isLinuxDevice(_ id: String) -> Bool {
        if let rec = pairings.first(where: { $0.peerID == id }) { return rec.isLinux }
        return shared?.devices.first(where: { $0.id == id })?.isLinux ?? false
    }

    func status(for id: String) -> LinkStatus {
        peerStatuses[id] ?? linkStatus
    }

    func screensForDevice(_ id: String) -> [ScreenInfo] {
        if id == me.id { return localScreens }
        return peerScreensByDevice[id] ?? otherScreensByDevice[id] ?? []
    }

    /// 当前生效的相邻规则（本机视角）和全部在线设备屏幕信息；跨屏判定每个鼠标事件都要用，所以缓存起来
    var crossingMap: CrossingMap {
        if let m = cachedMap { return m }
        var byDev: [String: [ScreenInfo]] = [:]
        if isController {
            let connected = hub?.connectedPeerIDs
            for rec in pairings {
                if let connected, !connected.contains(rec.peerID) { continue }
                byDev[rec.peerID] = peerScreensByDevice[rec.peerID] ?? []
            }
        } else {
            if !otherScreensByDevice.isEmpty {
                byDev = otherScreensByDevice
            } else if !peerID.isEmpty {
                byDev[peerID] = peerScreens
            }
        }
        let m = CrossingMap(views: rules.compactMap { $0.view(from: me.id) },
                            localScreens: localScreens, remoteByDevice: byDev)
        cachedMap = m
        return m
    }

    /// 某台的某块屏的信息：现在接着的优先，其次是见过的（拔掉的屏）
    func screenInfo(device: String, screen: String) -> ScreenInfo? {
        screensForDevice(device).first { $0.id == screen } ?? knownScreens[screen]
    }

    /// 界面上摆出来的布局：共享设置里的布局，加上现在接着、布局里还没有的屏（放在最右边）
    var placedScreens: [PlacedScreen] {
        var present: [(device: String, info: ScreenInfo)] = localScreens.map { (device: me.id, info: $0) }
        var seen: Set<String> = [me.id]
        for rec in pairings where !seen.contains(rec.peerID) {
            seen.insert(rec.peerID)
            for s in (peerScreensByDevice[rec.peerID] ?? []) {
                present.append((device: rec.peerID, info: s))
            }
        }
        for (dev, list) in otherScreensByDevice where !seen.contains(dev) {
            seen.insert(dev)
            for s in list { present.append((device: dev, info: s)) }
        }
        return ScreenLayout.placed(spots: shared?.layout ?? [], present: present, info: screenInfo)
    }
    var ripple: RippleConfig { shared?.ripple ?? localRipple }

    // MARK: - 启动 / 退出

    func startServices() {
        log("本机：「\(me.name)」，设备 ID \(me.id)，\(me.isLaptop ? "笔记本" : "台式机")")
        rippleConfig = ripple
        refreshLocalScreens(log: true)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLocalScreens(log: true)
        }
        if isPaired {
            startPaired()
        } else {
            logRole = "未配对"
            log("未配对，等待用户在界面上配对")
            syncHub()
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    /// 进程退出前：在远端就先收回光标、补发按键抬起，再断开连接让对方立刻知道
    func shutdown() {
        stopRole()
        hub?.stop()
        hub = nil
        inviter?.stop()
        browser?.stop()
    }

    func quit() {
        log("用户在菜单选择「退出 MacKVM」，停止运行（launchd 不会再拉起，下次登录或双击 MacKVM 时再启动）")
        shutdown()
        exit(0)
    }

    /// 「重置键鼠状态」按钮只在这时显示：本机是被控、和对方连着（主控那台用不上，底栏和菜单都不显示）
    var canResetInput: Bool { isPaired && !isController && linkStatus == .connected }

    /// 「重置键鼠状态」（主界面底栏按钮、菜单栏菜单）：光标在本机时交还主控，见 ControlledRole.resetInputState
    func resetInputState(from source: String) {
        guard let c = controlled else {
            log("\(source)点了「重置键鼠状态」，但本机不是被控角色，忽略")
            return
        }
        c.resetInputState("\(source)点了「重置键鼠状态」")
    }

    // MARK: - 已配对：连接与角色

    private func expectedDevicesList() -> [DeviceSummary] {
        var list = [DeviceSummary(id: me.id, name: me.name, isLaptop: me.isLaptop, platform: "macos")]
        for rec in pairings {
            list.append(DeviceSummary(id: rec.peerID, name: rec.peerName, isLaptop: rec.peerIsLaptop,
                                      platform: rec.platform ?? "macos"))
        }
        return list
    }

    private func syncHub() {
        let peerEntries: [LinkHub.Entry] = pairings.compactMap { rec in
            guard let k = rec.key else { return nil }
            return LinkHub.Entry(peerID: rec.peerID, name: rec.peerName, key: k, lastAddress: rec.lastAddress)
        }
        let unpairEntries: [LinkHub.Entry] = (state.pendingUnpairs ?? []).compactMap { rec in
            guard let k = rec.key else { return nil }
            return LinkHub.Entry(peerID: rec.peerID, name: rec.peerName, key: k, lastAddress: rec.lastAddress)
        }
        if peerEntries.isEmpty && unpairEntries.isEmpty {
            hub?.stop()
            hub = nil
            return
        }
        let h: LinkHub
        if let existing = hub {
            h = existing
        } else {
            h = LinkHub(me: me)
            h.onAuthenticated = { [weak self] pid, p in self?.linkUp(pid, p) }
            h.onMessage = { [weak self] pid, _, t, d in self?.linkMessage(pid, t, d) }
            h.onDisconnected = { [weak self] pid in self?.linkDown(pid) }
            h.onAddressLearned = { [weak self] pid, ip in
                guard let self, let i = self.pairings.firstIndex(where: { $0.peerID == pid }) else { return }
                self.pairings[i].lastAddress = ip
                self.persist()
                log("记住「\(self.pairings[i].peerName)」地址 \(ip)（Bonjour 找不到时用）")
            }
            h.onUnpairDelivered = { [weak self] pid in
                guard let self else { return }
                if let name = self.state.pendingUnpairs?.first(where: { $0.peerID == pid })?.peerName {
                    log("已通知「\(name)」解除配对")
                }
                self.state.pendingUnpairs?.removeAll { $0.peerID == pid }
                if self.state.pendingUnpairs?.isEmpty == true { self.state.pendingUnpairs = nil }
                self.persist()
                self.syncHub()
            }
            hub = h
            h.start()
        }
        h.setPeers(peerEntries)
        h.setUnpairTargets(unpairEntries)
    }

    private func startPaired() {
        guard let s = shared, !pairings.isEmpty else { return }
        logRole = isController ? "主控" : "被控"
        let names = pairings.map { "「\($0.peerName)」" }.joined(separator: "、")
        log("已配对 \(names)：本机是\(isController ? "主控（键鼠接在本机）" : "被控（被对方操作）")，屏幕布局 \(s.layout.count) 块屏、相邻规则 \(s.rules.count) 条\(s.rulesInitialized ? "" : "（还没生成过默认布局）")，共享设置修订号 \(s.revision)")
        let now = Date()
        linkChangedAt = now
        for rec in pairings {
            linkChangedAtByDevice[rec.peerID] = now
            peerStatuses[rec.peerID] = .searching
        }
        linkStatus = .searching
        syncHub()
        startRole()
        maybeMigrateLayout()
    }

    private func startRole() {
        stopRole()
        guard isPaired else { logRole = "未配对"; return }
        let map: () -> CrossingMap = { [weak self] in
            self?.crossingMap ?? CrossingMap(views: [], localScreens: [], remoteScreens: [])
        }
        if isController {
            logRole = "主控"
            let c = ControllerRole(
                myID: me.id,
                peerFor: { [weak self] pid in self?.hub?.activePeer(for: pid) },
                peerIsLinux: { [weak self] pid in self?.isLinuxDevice(pid) ?? false },
                map: map)
            controller = c
            c.start()
            for rec in pairings where hub?.activePeer(for: rec.peerID) != nil {
                c.peerOnline(peerID: rec.peerID, replaced: false)
            }
        } else {
            logRole = "被控"
            let peer: () -> Peer? = { [weak self] in
                guard let self, let ctl = self.shared?.controllerID else { return nil }
                return self.hub?.activePeer(for: ctl)
            }
            let c = ControlledRole(peer: peer, map: map)
            controlled = c
            c.start()
            if peer() != nil { c.peerOnline(replaced: false) }
        }
    }

    private func stopRole() {
        controller?.stop()
        controller = nil
        controlled?.stop()
        controlled = nil
    }

    private func linkUp(_ pid: String, _ p: Peer) {
        let now = Date()
        linkChangedAt = now
        linkChangedAtByDevice[pid] = now
        peerSettingsSeenByDevice.remove(pid)
        peerScreensFreshByDevice.remove(pid)
        cachedMap = nil
        refreshStatus()
        sendInfo(p)
        sendSettings(to: p)
        sendScreens(to: p)
        if isController {
            broadcastAllScreens()
            controller?.peerOnline(peerID: pid, replaced: false)
        } else {
            controlled?.peerOnline(replaced: false)
        }
    }

    private func linkDown(_ pid: String) {
        let now = Date()
        peerScreensFreshByDevice.remove(pid)
        linkChangedAt = now
        linkChangedAtByDevice[pid] = now
        cachedMap = nil
        refreshStatus()
        if isController {
            broadcastAllScreens()
            controller?.peerOffline(peerID: pid)
        } else {
            controlled?.peerOffline()
        }
    }

    private func linkMessage(_ pid: String, _ t: Msg, _ d: Data) {
        switch t {
        case .settings:
            receiveSettings(from: pid, d)
            peerSettingsSeenByDevice.insert(pid)
            maybeCreateDefaultLayout()
            maybeMigrateLayout()
        case .screens:
            guard let list = try? JSONDecoder().decode([ScreenInfo].self, from: d) else {
                log("警告：对方（\(pid.prefix(8))）发来的屏幕清单解析失败")
                return
            }
            let changed = list != (peerScreensByDevice[pid] ?? [])
            peerScreensByDevice[pid] = list
            peerScreensFreshByDevice.insert(pid)
            remember(list)
            cachedMap = nil
            persist()
            if changed { log("对方屏幕（\(deviceName(for: pid))）：\(describeScreens(list))") }
            maybeCreateDefaultLayout()
            maybeAppendDeviceLayout(pid)
            maybeMigrateLayout()
            if isController { broadcastAllScreens() }
        case .allScreens:
            guard !isController, let dict = try? JSONDecoder().decode([String: [ScreenInfo]].self, from: d) else { return }
            var filtered = dict
            filtered.removeValue(forKey: me.id)
            otherScreensByDevice = filtered
            for list in filtered.values { remember(list) }
            cachedMap = nil
        case .unpair:
            log("「\(deviceName(for: pid))」解除了配对")
            removePairing(pid, reason: "对方解除了配对")
        case .info:
            guard let info = try? JSONDecoder().decode(PeerInfo.self, from: d),
                  let idx = pairings.firstIndex(where: { $0.peerID == pid }) else { return }
            if info.id != pid { log("警告：对方报的设备 ID \(info.id) 和配对记录不一致") }
            var rec = pairings[idx]
            let plat = info.platform ?? rec.platform ?? "macos"
            if info.name != rec.peerName || info.laptop != rec.peerIsLaptop || plat != rec.platform {
                if info.name != rec.peerName {
                    log("对方设备名更新：「\(rec.peerName)」→「\(info.name)」")
                }
                rec.peerName = info.name
                rec.peerIsLaptop = info.laptop
                rec.platform = plat
                pairings[idx] = rec
                persist()
                syncHub()
            }
            if isController, let s = shared, s.devices != expectedDevicesList() {
                editShared { $0.devices = self.expectedDevicesList() }
            }
            log("「\(rec.peerName)」版本 \(info.version)\(rec.isLinux ? "（Linux）" : "")")
        case .leave:
            controller?.message(from: pid, t, d)
        case .enter, .move, .button, .event, .release:
            controlled?.message(t, d)
        default:
            break
        }
    }

    private func sendInfo(_ p: Peer) {
        let info = PeerInfo(id: me.id, name: me.name, laptop: me.isLaptop, version: kVersion, platform: "macos")
        if let d = try? JSONEncoder().encode(info) { p.send(.info, d) }
    }

    private func sendSettings(to target: Peer? = nil, excluding excludedID: String? = nil) {
        guard let s = shared, let d = try? JSONEncoder().encode(s) else { return }
        if let target {
            target.send(.settings, d)
            return
        }
        for rec in pairings where rec.peerID != excludedID {
            hub?.activePeer(for: rec.peerID)?.send(.settings, d)
        }
    }

    private func broadcastAllScreens() {
        guard isController else { return }
        var all: [String: [ScreenInfo]] = [me.id: localScreens]
        for rec in pairings where hub?.activePeer(for: rec.peerID) != nil {
            if let list = peerScreensByDevice[rec.peerID], !list.isEmpty {
                all[rec.peerID] = list
            }
        }
        guard let d = try? JSONEncoder().encode(all) else { return }
        for rec in pairings {
            hub?.activePeer(for: rec.peerID)?.send(.allScreens, d)
        }
    }

    private func receiveSettings(from pid: String, _ d: Data) {
        guard let cur = shared else { return }
        let allowed = Set(pairings.map(\.peerID))
        guard var s = try? JSONDecoder().decode(SharedSettings.self, from: d),
              s.isValid(me: me.id, allowedPeers: allowed) else {
            log("警告：从 \(pid.prefix(8)) 收到的共享设置不合法，忽略")
            return
        }
        s.ripple = s.ripple.sanitized()
        if s.isNewer(than: cur) {
            log("采用「\(deviceName(for: pid))」的共享设置（修订号 \(cur.revision) → \(s.revision)）")
            applyShared(s)
            if isController { sendSettings(excluding: pid) }
        } else if cur.isNewer(than: s), let p = hub?.activePeer(for: pid) {
            sendSettings(to: p) // 对方的旧，把本机的发回去，很快收敛到同一份
        }
    }

    /// 生效一份共享设置：保存、更新波纹参数；角色变了就就地切换主控/被控逻辑（不重启进程）
    private func applyShared(_ s: SharedSettings) {
        let wasController = isController
        let old = shared
        shared = s
        cachedMap = nil
        localRipple = s.ripple
        rippleConfig = s.ripple
        persist()
        if s.layout != old?.layout || s.rules != old?.rules {
            log("屏幕布局 \(s.layout.count) 块屏；相邻规则 \(s.rules.count) 条，\(crossingMap.activeViews.count) 条生效")
        }
        if wasController != isController {
            log("角色切换：本机现在是\(isController ? "主控（键鼠接在本机）" : "被控（被对方操作）")")
            startRole()
        }
    }

    /// 本机修改共享设置：修订号加 1，立即生效并同步给所有已连接对端
    private func editShared(_ f: (inout SharedSettings) -> Void) {
        guard var s = shared else { return }
        f(&s)
        s.revision += 1
        s.editor = me.id
        applyShared(s)
        sendSettings()
    }

    // MARK: - 界面操作：已配对

    // MARK: - 屏幕与相邻规则

    private func refreshLocalScreens(log doLog: Bool, attempt: Int = 0) {
        let list = ScreenCatalog.current()
        if list.isEmpty {
            // 刚登录、显示器还没就绪时可能读不到：每 2 秒再读一次
            if attempt % 15 == 0 { log("暂时读不到本机显示器（\(ScreenCatalog.debugSummary())），2 秒后再试") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.refreshLocalScreens(log: doLog, attempt: attempt + 1)
            }
            return
        }
        guard list != localScreens else { return }
        let old = Dictionary(localScreens.map { ($0.id, $0.usableFrame) }, uniquingKeysWith: { a, _ in a })
        if list.contains(where: { old[$0.id] != $0.usableFrame }) {
            log("屏幕可用区域更新：" + list.map { s in
                let u = s.usableFrame
                return "「\(s.name)」可用区域 x \(Int(u.minX))…\(Int(u.maxX))、y \(Int(u.minY))…\(Int(u.maxY))（\(ScreenCatalog.describeInsets(s))）"
            }.joined(separator: "；"))
        }
        localScreens = list
        remember(list)
        if doLog { log("本机屏幕：\(describeScreens(list))") }
        sendScreens()
        if isController { broadcastAllScreens() }
        maybeMigrateLayout()
    }

    private func remember(_ list: [ScreenInfo]) {
        for s in list { knownScreens[s.id] = s }
        state.knownScreens = Array(knownScreens.values)
        persist()
    }

    private func sendScreens(to target: Peer? = nil) {
        guard let d = try? JSONEncoder().encode(localScreens) else { return }
        if let target {
            target.send(.screens, d)
            return
        }
        for rec in pairings {
            hub?.activePeer(for: rec.peerID)?.send(.screens, d)
        }
    }

    private func newRuleID() -> String { UUID().uuidString.lowercased() }

    /// 配对后还没生成过默认布局：由主控（拿到首台对方屏幕清单、并且收到过对方共享设置之后）生成一次，
    /// 再从布局推导规则（效果是「主控最右侧屏的右边 ↔ 被控最左侧屏的左边，中点对齐」）
    private func maybeCreateDefaultLayout() {
        guard let s = shared, s.needsDefaultLayout, isController, let rec = pairings.first,
              hub?.activePeer(for: rec.peerID) != nil,
              peerSettingsSeenByDevice.contains(rec.peerID),
              peerScreensFreshByDevice.contains(rec.peerID),
              !localScreens.isEmpty, let rScreens = peerScreensByDevice[rec.peerID], !rScreens.isEmpty else { return }
        let layout = ScreenLayout.defaultLayout(controller: me.id, controllerScreens: localScreens,
                                                controlled: rec.peerID, controlledScreens: rScreens)
        let placed = ScreenLayout.placed(spots: layout, present: [], info: screenInfo)
        let rules = ScreenLayout.rules(from: placed, existing: s.rules, newID: newRuleID)
        log("生成默认屏幕布局：\(layout.count) 块屏，相邻规则 \(rules.count) 条")
        editShared {
            $0.devices = self.expectedDevicesList()
            $0.layout = layout
            $0.rules = rules
            $0.rulesInitialized = true
        }
    }

    /// 新添加的被控设备连上并报来屏幕清单后，自动把它追加到现有布局的最右侧
    private func maybeAppendDeviceLayout(_ id: String) {
        guard let s = shared, isController, !s.needsDefaultLayout, !s.needsLayoutMigration,
              let screens = peerScreensByDevice[id], !screens.isEmpty else { return }
        guard !s.layout.contains(where: { $0.device == id }) else { return }
        let newLayout = ScreenLayout.appendDevice(id, screens: screens, to: s.layout, info: screenInfo)
        let placed = ScreenLayout.placed(spots: newLayout, present: [], info: screenInfo)
        let rules = ScreenLayout.rules(from: placed, existing: s.rules, newID: newRuleID)
        log("为新加入设备「\(deviceName(for: id))」安排屏幕位置：共 \(newLayout.count) 块屏，相邻规则 \(rules.count) 条")
        editShared {
            $0.devices = self.expectedDevicesList()
            $0.layout = newLayout
            $0.rules = rules
        }
    }

    /// 旧数据只有规则、没有布局：按规则把屏摆出来（见 ScreenLayout.migrated），再从布局重新推导规则。
    /// 修订号同步机制会让双方收敛到同一份
    private func maybeMigrateLayout() {
        guard let s = shared, s.needsLayoutMigration, let rec = pairings.first,
              !localScreens.isEmpty, let rScreens = peerScreensByDevice[rec.peerID], !rScreens.isEmpty else { return }
        let layout = ScreenLayout.migrated(rules: s.rules, me: me.id, localScreens: localScreens, peer: rec.peerID,
                                           peerScreens: rScreens, info: screenInfo)
        let placed = ScreenLayout.placed(spots: layout, present: [], info: screenInfo)
        let rules = ScreenLayout.rules(from: placed, existing: s.rules, newID: newRuleID)
        log("按已有的 \(s.rules.count) 条相邻规则摆出屏幕布局：\(layout.count) 块屏，重新推导出相邻规则 \(rules.count) 条")
        editShared {
            $0.devices = self.isController ? self.expectedDevicesList() : $0.devices
            $0.layout = layout
            $0.rules = rules
        }
    }

    /// 在预览里把一块屏拖到新位置放下（调用前界面已确认不和别的屏叠在一起）：
    /// 整份布局（含补上的新屏）写进共享设置，同时从布局推导规则，一起同步给所有对端
    func moveScreen(device: String, screen: String, to p: CGPoint) {
        guard isPaired, shared != nil else { return }
        var placed = placedScreens
        guard let i = placed.firstIndex(where: { $0.isSame(device, screen) }),
              placed[i].x != p.x || placed[i].y != p.y else { return }
        placed[i].x = p.x
        placed[i].y = p.y
        let rules = ScreenLayout.rules(from: placed, existing: self.rules, newID: newRuleID)
        log("用户摆放屏幕：\(device == me.id ? "本机" : deviceName(for: device))「\(placed[i].info.name)」移到 (\(Int(p.x)), \(Int(p.y))) 毫米，相邻规则 \(rules.count) 条")
        editShared {
            if self.isController { $0.devices = self.expectedDevicesList() }
            $0.layout = placed.map(\.spot)
            $0.rules = rules
        }
    }

    /// 这块未连接的屏能否从布局中移除（只有对应设备当前有在线屏幕清单、且其中确实不包含它时才允许）
    func canRemoveUnpluggedScreen(device: String, screen: String) -> Bool {
        guard isPaired, let s = shared,
              s.layout.contains(where: { $0.device == device && $0.screen == screen }) else { return false }
        let live = screensForDevice(device)
        return !live.isEmpty && !live.contains(where: { $0.id == screen })
    }

    /// 从共享布局与相邻规则中永久移除一块不再使用的未连接屏幕，并同步给所有对端
    func removeUnpluggedScreen(device: String, screen: String) {
        guard canRemoveUnpluggedScreen(device: device, screen: screen), let s = shared else { return }
        let name = screenInfo(device: device, screen: screen)?.name ?? screen
        let devName = device == me.id ? "本机" : deviceName(for: device)
        let updated = ScreenLayout.removing(device: device, screen: screen,
                                            from: s.layout, existingRules: s.rules,
                                            info: screenInfo, newID: newRuleID)
        editShared {
            if self.isController { $0.devices = self.expectedDevicesList() }
            $0.layout = updated.layout
            $0.rules = updated.rules
        }
        let stillUsed = (shared?.layout.contains { $0.screen == screen } ?? false)
            || localScreens.contains { $0.id == screen }
            || peerScreensByDevice.values.contains { $0.contains { $0.id == screen } }
            || otherScreensByDevice.values.contains { $0.contains { $0.id == screen } }
        if !stillUsed, knownScreens.removeValue(forKey: screen) != nil {
            state.knownScreens = Array(knownScreens.values)
            persist()
        }
        log("用户移除未连接屏幕：\(devName)「\(name)」，剩余 \(updated.layout.count) 块屏、相邻规则 \(updated.rules.count) 条")
    }

    func confirmSwap() {
        dialog = nil
        guard canSwapController, let rec = pairings.first else { return }
        log("用户确认切换输入设备（对调角色）：\(isController ? "「\(rec.peerName)」" : "本机")将成为输入设备")
        editShared { $0.controllerID = isController ? rec.peerID : me.id }
    }

    func updateRipple(_ f: (inout RippleConfig) -> Void) {
        var r = ripple
        f(&r)
        r = r.sanitized()
        guard r != ripple else { return }
        if isPaired {
            editShared { $0.ripple = r }
        } else {
            localRipple = r
            rippleConfig = r
            persist()
        }
    }

    func resetRipple() {
        log("用户恢复波纹默认值")
        updateRipple { r in
            let on = r.enabled
            r = .defaults          // 颜色也一起恢复成默认三色
            r.enabled = on
        }
    }

    func promptUnpair(_ targetID: String? = nil) {
        unpairTargetID = targetID ?? pairings.first?.peerID
        dialog = .confirmUnpair
    }

    func confirmUnpair() {
        dialog = nil
        let targetID = unpairTargetID ?? pairings.first?.peerID
        unpairTargetID = nil
        guard let targetID, let rec = pairings.first(where: { $0.peerID == targetID }) else { return }
        log("用户确认解除与「\(rec.peerName)」的配对")
        guard let p = hub?.activePeer(for: rec.peerID) else {
            finishUnpair(rec, delivered: false)
            return
        }
        var done = false
        let complete: (Bool) -> Void = { [weak self] ok in
            guard !done else { return }
            done = true
            self?.finishUnpair(rec, delivered: ok)
        }
        p.send(.unpair) { ok in DispatchQueue.main.async { complete(ok) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { complete(false) }
    }

    private func finishUnpair(_ rec: PairingRecord, delivered: Bool) {
        removePairing(rec.peerID, reason: delivered ? "本机解除配对，已通知对方" : "本机解除配对")
        if !delivered {
            var pending = state.pendingUnpairs ?? []
            if !pending.contains(where: { $0.peerID == rec.peerID }) { pending.append(rec) }
            state.pendingUnpairs = pending
            persist()
            log("「\(rec.peerName)」现在不在线：等它上线后再通知它解除配对")
            syncHub()
        }
    }

    private func removePairing(_ targetID: String, reason: String) {
        if pairings.count <= 1 && pairings.first?.peerID == targetID {
            clearPairing(reason: reason)
            return
        }
        guard let rec = pairings.first(where: { $0.peerID == targetID }) else { return }
        if controller?.activePeerID == targetID {
            controller?.peerOffline(peerID: targetID)
        }
        pairings.removeAll { $0.peerID == targetID }
        peerScreensByDevice.removeValue(forKey: targetID)
        peerStatuses.removeValue(forKey: targetID)
        peerSettingsSeenByDevice.remove(targetID)
        peerScreensFreshByDevice.remove(targetID)
        linkChangedAtByDevice.removeValue(forKey: targetID)
        cachedMap = nil
        if var s = shared {
            s.devices = expectedDevicesList()
            s.layout.removeAll { $0.device == targetID }
            let placed = ScreenLayout.placed(spots: s.layout, present: [], info: screenInfo)
            let keptRules = s.rules.filter { $0.aDevice != targetID && $0.bDevice != targetID }
            s.rules = ScreenLayout.rules(from: placed, existing: keptRules, newID: newRuleID)
            s.revision += 1
            s.editor = me.id
            applyShared(s)
            sendSettings()
        }
        persist()
        syncHub()
        if isController { broadcastAllScreens() }
        refreshStatus()
        log("已移除设备「\(rec.peerName)」（\(reason)），当前还剩 \(pairings.count) 台配对设备")
    }

    private func clearPairing(reason: String) {
        stopRole()
        pairings = []
        shared = nil
        peerScreensByDevice = [:]
        otherScreensByDevice = [:]
        peerStatuses = [:]
        peerSettingsSeenByDevice = []
        peerScreensFreshByDevice = []
        linkChangedAtByDevice = [:]
        unpairTargetID = nil
        persist()
        syncHub()
        logRole = "未配对"
        log("已解除配对（\(reason)）。未配对，等待用户在界面上配对")
        tab = .connection
        if [.confirmSwap, .confirmUnpair, .pairSuccess, .linkInfo].contains(dialog) {
            dialog = nil
        }
        linkStatus = .searching
    }

    // MARK: - 界面操作：配对

    func openInvite() {
        guard !isPaired else { return }
        closePairingFlows()
        let inv = PairingInviter(me: me)
        inv.onCodeChanged = { [weak self] code, renewed in
            guard let self else { return }
            self.inviteCode = code
            self.inviteRenewed = renewed
            // 这是对方在配对流程里的操作结果（不是连接状态），弹出「密钥已自动更新」
            if renewed, self.dialog == .invite { self.dialog = .codeRenewed }
        }
        inv.onPaired = { [weak self] r in self?.pairingCompleted(r, asController: false) }
        inv.onProblem = { [weak self] p in self?.inviteProblem = p }
        inviter = inv
        inviteCode = inv.code
        inviteRenewed = false
        inviteProblem = nil
        log("发起邀请：本机设备名「\(me.name)」，生成新的配对码")
        inv.start()
        dialog = .invite
    }

    func cancelInvite() {
        if inviter != nil { log("取消邀请，停止广播") }
        inviter?.stop()
        inviter = nil
        dialog = nil
    }

    func openSeek() {
        guard !isPaired || isController else { return }
        closePairingFlows()
        let b = BonjourBrowser(type: kPairServiceType, label: "查找设备")
        b.onChange = { [weak self] list in
            guard let self else { return }
            self.seekDevices = list.filter { d in
                d.id != self.me.id && !self.pairings.contains(where: { $0.peerID == d.id })
            }
            // 「没找到」提示期间发现了设备：回到设备列表
            if !self.seekDevices.isEmpty, self.dialog == .noDevices { self.dialog = .seek }
        }
        b.onProblem = { [weak self] p in self?.seekProblem = p }
        browser = b
        seekDevices = []
        seekProblem = nil
        b.start()
        dialog = .seek
        // 查找 6 秒仍一台都没有：提示一次「没找到可配对的设备」（每次查找只提示一次）
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak b] in
            guard let self, let b, self.browser === b, self.dialog == .seek, self.seekDevices.isEmpty else { return }
            self.dialog = .noDevices
        }
    }

    /// 「没找到」提示里点「继续查找」或关闭：回到设备列表，继续查找
    func continueSeek() {
        if dialog == .noDevices { dialog = .seek }
    }

    /// 「密钥已自动更新」里点「查看新密钥」或关闭：回到显示配对码的弹窗
    func showNewCode() {
        if dialog == .codeRenewed { dialog = .invite }
    }

    func cancelSeek() {
        seeker?.cancel()
        seeker = nil
        browser?.stop()
        browser = nil
        pairingBusy = false
        dialog = nil
    }

    func chooseDevice(_ d: DiscoveredDevice) {
        codeInput = ""
        codeError = nil
        pairingBusy = false
        dialog = .enterCode(d)
    }

    func cancelCodeEntry() {
        seeker?.cancel()
        seeker = nil
        pairingBusy = false
        codeError = nil
        dialog = .seek
    }

    func submitCode() {
        guard case .enterCode(let d) = dialog, !pairingBusy else { return }
        let code = PairingCrypto.digits(codeInput)
        guard code.count == 8 else {
            codeError = .incomplete
            return
        }
        pairingBusy = true
        codeError = nil
        let ep = seekDevices.first(where: { $0.id == d.id })?.endpoint ?? d.endpoint
        log("向「\(d.name)」提交配对码")
        let s = PairingSeeker(me: me)
        seeker = s
        s.pair(endpoint: ep, expectedID: d.id, code: code) { [weak self] result in
            guard let self, self.seeker === s else { return }
            self.pairingBusy = false
            self.seeker = nil
            switch result {
            case .success(let r):
                self.pairingCompleted(r, asController: true)
            case .failure(let f):
                switch f {
                case .wrongCode(let left):
                    self.codeError = .wrongCode(left: left)
                case .renewed:
                    self.codeError = .renewed
                case .busy:
                    self.codeError = .busy
                case .failed(let why):
                    self.codeError = .failed(why)
                }
                if f != .busy { self.codeInput = "" }
                log("配对没有成功：\(self.codeError.map { L.codeError($0, .zh) } ?? "")")
            }
        }
    }

    private func closePairingFlows() {
        inviter?.stop()
        inviter = nil
        seeker?.cancel()
        seeker = nil
        browser?.stop()
        browser = nil
        pairingBusy = false
    }

    private func pairingCompleted(_ r: PairingResult, asController: Bool) {
        let addingMore = isPaired && isController && asController
        guard !isPaired || addingMore else { return }
        // 被控方：确认消息已交给系统发出，稍等再关监听，免得最后一帧被截断
        let inv = inviter
        inviter = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { inv?.stop() }
        browser?.stop()
        browser = nil
        seeker = nil
        state.pendingUnpairs?.removeAll { $0.peerID == r.peerID }
        if state.pendingUnpairs?.isEmpty == true { state.pendingUnpairs = nil }
        state.pendingUnpair = nil

        let keyB64 = r.key.withUnsafeBytes { Data($0).base64EncodedString() }
        let rec = PairingRecord(peerID: r.peerID, peerName: r.peerName, peerIsLaptop: r.peerIsLaptop,
                                keyBase64: keyB64, lastAddress: r.peerAddress, platform: r.platform)
        lastPairedName = r.peerName

        if !addingMore {
            let controllerID = asController ? me.id : r.peerID
            pairings = [rec]
            let devs = asController
                ? [DeviceSummary(id: me.id, name: me.name, isLaptop: me.isLaptop, platform: "macos"),
                   DeviceSummary(id: rec.peerID, name: rec.peerName, isLaptop: rec.peerIsLaptop, platform: rec.platform)]
                : []
            // 两台各自生成同一份初始共享设置；主控那份修订号是 1，连上后被控方会采用主控的（含主控的波纹参数）
            shared = SharedSettings(revision: asController ? 1 : 0, editor: controllerID, controllerID: controllerID,
                                    ripple: localRipple.sanitized(), devices: devs)
            persist()
            rippleConfig = ripple
            log("配对成功：对方「\(r.peerName)」（\(r.peerID)），地址 \(r.peerAddress ?? "未知")，本机是\(asController ? "主控" : "被控")，密钥指纹 \(PairingCrypto.fingerprint(r.key))")
            tab = .connection
            dialog = .pairSuccess
            startPaired()
        } else {
            pairings.removeAll { $0.peerID == rec.peerID }
            pairings.append(rec)
            linkChangedAtByDevice[rec.peerID] = Date()
            peerStatuses[rec.peerID] = .searching
            editShared { $0.devices = self.expectedDevicesList() }
            syncHub()
            refreshStatus()
            log("新增被控设备成功：「\(r.peerName)」（\(r.peerID)），地址 \(r.peerAddress ?? "未知")，当前共 \(pairings.count) 台被控设备，密钥指纹 \(PairingCrypto.fingerprint(r.key))")
            tab = .connection
            dialog = .pairSuccess
        }
    }

    // MARK: - 状态

    private func refreshStatus() {
        guard isPaired else { return }
        let now = Date()
        let activeIDs = Set(pairings.map(\.peerID))
        for k in Array(peerStatuses.keys) where !activeIDs.contains(k) {
            peerStatuses.removeValue(forKey: k)
        }
        for rec in pairings {
            if hub?.activePeer(for: rec.peerID) != nil {
                peerStatuses[rec.peerID] = .connected
            } else {
                let changed = linkChangedAtByDevice[rec.peerID] ?? linkChangedAt
                peerStatuses[rec.peerID] = now.timeIntervalSince(changed) < 10 ? .searching : .offline
            }
        }
        let sts = pairings.compactMap { peerStatuses[$0.peerID] }
        let s: LinkStatus
        if !sts.isEmpty && sts.allSatisfy({ $0 == .connected }) {
            s = .connected
        } else if sts.contains(where: { $0 == .connected || $0 == .searching }) {
            s = .searching
        } else {
            s = .offline
        }
        if s != linkStatus { linkStatus = s }
    }

    private func persist() {
        state.pairings = pairings.isEmpty ? nil : pairings
        state.pairing = pairings.first
        state.shared = shared
        state.ripple = localRipple
        state.peerScreensByDevice = peerScreensByDevice.isEmpty ? nil : peerScreensByDevice
        state.peerScreens = peerID.isEmpty ? nil : peerScreensByDevice[peerID]
        state.pendingUnpair = (state.pendingUnpairs ?? []).first
        store?.save(state)
    }
}

/// 日志里描述一组屏幕
func describeScreens(_ list: [ScreenInfo]) -> String {
    let labels = ScreenNaming.labels(list, .zh)
    return list.map { s in
        "「\(labels[s.id] ?? s.name)」\(s.isMain ? "主屏 " : "")\(Int(s.w))×\(Int(s.h)) 点 @(\(Int(s.x)),\(Int(s.y)))，\(Int(s.mmW.rounded()))×\(Int(s.mmH.rounded())) 毫米\(s.estimated ? "（估算）" : "")，ID \(s.id.prefix(8))"
    }.joined(separator: "；")
}

// MARK: - 本机信息

/// 系统设置 → 通用 → 关于本机 里的「名称」
func currentComputerName() -> String {
    if let n = SCDynamicStoreCopyComputerName(nil, nil) as String?, !n.isEmpty { return n }
    return Host.current().localizedName ?? "Mac"
}

/// 有内置电池就当是笔记本（Apple 芯片的机型标识都是 MacXX,Y，看不出是不是 MacBook）
func hasInternalBattery() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
    for ps in list {
        if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
           d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
            return true
        }
    }
    return false
}

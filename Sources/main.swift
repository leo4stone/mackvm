// MacKVM —— 两台 Mac 共用一套键鼠。
// 入口：单实例判断 → 建 AppModel（状态与调度）→ 菜单栏图标 → 主循环。
// 整个产品只有这一个进程：界面、网络、事件截获（主控）、事件注入（被控）都在里面，
// 由 LaunchAgent 开机拉起；进程是 .accessory，不在程序坞显示图标，关掉窗口也照常运行，
// 只有菜单里「退出 MacKVM」才结束（exit(0)，LaunchAgent 的 KeepAlive 设成只在异常退出时拉起）。
// 不再接受 server / client 参数：角色、对方是谁都来自界面上的配对，存在 ~/Library/Application Support/MacKVM/。

import AppKit
import ApplicationServices
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    var statusMenu: StatusMenu?
    var window: MainWindowController?
    var showAtLaunch = false

    init(model: AppModel) { self.model = model }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let w = MainWindowController(model: model)
        w.startReactivationReset()
        window = w
        model.showWindowHandler = { [weak w] in w?.show() }
        statusMenu = StatusMenu(model: model)
        DistributedNotificationCenter.default().addObserver(forName: kShowWindowNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            log("收到另一个进程的请求：弹出主窗口")
            self?.window?.show()
        }
        model.startServices()
        if showAtLaunch { w.show() }
    }

    // 已在运行时再双击 app：LaunchServices 发来「重新打开」
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 进程是 .accessory，不显示菜单栏，但文本框的复制粘贴、⌘W 关窗口要靠主菜单里的按键对应
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

// 不是 launchd 拉起时 stderr 没人接，日志也写进同一个文件
if !launchedByAgent() {
    freopen(kLogPath, "a", stderr)
}

log("MacKVM \(kVersion) 启动：pid \(getpid())，\(launchedByAgent() ? "由 LaunchAgent 拉起" : "由用户打开")，程序 \(Bundle.main.bundlePath)")
if CommandLine.arguments.count > 1 {
    log("提示：新版不再使用命令行参数（收到 \(CommandLine.arguments.dropFirst().joined(separator: " "))），已忽略；请用新版 install-agent.sh 重装 LaunchAgent")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let (shouldRun, showAtLaunch) = resolveSingleInstance()
if !shouldRun { exit(0) }

// 防止系统对这个后台进程做定时器合并/节流，影响鼠标跟手；但不阻止系统休眠
let activity = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
    reason: "MacKVM 实时转发键鼠")

let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
log("辅助功能权限：\(trusted ? "已授权" : "未授权（已请求系统弹出授权提示）")")

let model = AppModel(store: Store())
let delegate = AppDelegate(model: model)
delegate.showAtLaunch = showAtLaunch
app.delegate = delegate

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        log("收到信号 \(sig)，退出")
        model.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

app.run()

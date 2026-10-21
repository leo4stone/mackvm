// 单实例与「双击 app 打开主界面」：
//   正常情况下 MacKVM 由 LaunchAgent（io.github.leo4stone.mackvm）拉起，整个系统只跑这一个进程。
//   - 已有实例在跑时双击 app：LaunchServices 直接把「重新打开」事件发给已有实例（AppDelegate 里弹窗口），
//     万一还是起了第二个进程，它发一条分布式通知让已有实例弹窗口，然后自己退出；
//   - 用户从菜单退出后再双击 app：新进程不是 launchd 拉起的，它留个「要弹窗口」的记号，
//     用 launchctl kickstart 让 launchd 重新拉起正式实例，然后自己退出——这样常驻的始终是 launchd 管的那个进程；
//   - 没装 LaunchAgent（比如手动运行）：就地作为正式实例运行并弹窗口。

import AppKit
import Foundation

let kShowWindowNotification = Notification.Name("io.github.leo4stone.mackvm.showWindow")
private let showMarkerPath = NSHomeDirectory() + "/Library/Application Support/MacKVM/show-window"

/// 本进程是不是 LaunchAgent 拉起的
func launchedByAgent() -> Bool {
    ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == kAgentLabel
}

private func runLaunchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    } catch {
        return -1
    }
}

private func otherInstancePIDs() -> [pid_t] {
    NSRunningApplication.runningApplications(withBundleIdentifier: kBundleID)
        .map(\.processIdentifier)
        .filter { $0 != getpid() && kill($0, 0) == 0 }
}

/// 决定本进程要不要继续当正式实例。返回 true = 继续运行；返回 false 之前已经安排好了别的实例弹窗口，调用方应退出。
/// 第二个返回值：继续运行时是否一启动就弹主窗口。
func resolveSingleInstance() -> (run: Bool, showWindow: Bool) {
    // 旧实例可能正在退出（比如 launchctl kickstart -k 重启时），给它 3 秒
    var others = otherInstancePIDs()
    var waited = 0.0
    while !others.isEmpty, waited < 3 {
        Thread.sleep(forTimeInterval: 0.2)
        waited += 0.2
        others = otherInstancePIDs()
    }
    if let other = others.first {
        log("已有实例在运行（pid \(other)），让它弹出主窗口，本进程退出")
        DistributedNotificationCenter.default().postNotificationName(kShowWindowNotification, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        return (false, false)
    }

    if launchedByAgent() {
        // 正式实例：看看是不是用户双击 app 让 launchd 拉起来的
        let show = consumeShowMarker()
        return (true, show)
    }

    // 用户双击 app（或手动运行），而正式实例没在跑
    let domain = "gui/\(getuid())/\(kAgentLabel)"
    if runLaunchctl(["print", domain]) == 0 {
        writeShowMarker()
        let st = runLaunchctl(["kickstart", domain])
        if st == 0 {
            log("LaunchAgent 已装载但没在运行：已让 launchd 重新拉起 MacKVM，本进程退出")
            return (false, false)
        }
        removeShowMarker()
        log("警告：launchctl kickstart 失败（\(st)），本进程直接运行")
    } else {
        log("没有装载 LaunchAgent，本进程直接运行（不会开机自启）")
    }
    return (true, true)
}

private func writeShowMarker() {
    try? FileManager.default.createDirectory(atPath: (showMarkerPath as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: showMarkerPath, contents: Data())
}

private func removeShowMarker() {
    try? FileManager.default.removeItem(atPath: showMarkerPath)
}

/// 记号存在且是 30 秒内留下的，就弹窗口；不管新旧都删掉
private func consumeShowMarker() -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: showMarkerPath),
          let t = attrs[.modificationDate] as? Date else { return false }
    removeShowMarker()
    return Date().timeIntervalSince(t) < 30
}

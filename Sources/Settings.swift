// 本机持久化的全部状态，以及两台之间同步的共享设置：
//   - 本机设备 ID（第一次启动时随机生成，之后不变）；
//   - 配对记录：对方设备 ID、对方设备名、长期密钥、上次连上对方的 IPv4 地址；
//   - 共享设置 SharedSettings：谁是主控、屏幕布局和相邻规则、波纹参数，带修订号，两台按修订号取新的；
//   - 待通知的解除配对：本机解除配对时对方不在线，就先记着，等对方上线再告诉它；
//   - 界面语言（用户手动切过才记，只存本机，不在两台之间同步）。
// 全部写在 ~/Library/Application Support/MacKVM/state.json（目录 700、文件 600，里面有密钥）。
// 环境变量 MACKVM_HOME 可以把目录换掉，只给自测用。

import CryptoKit
import Foundation

// MARK: - 方向

/// 屏幕的一条边：up = 上边，down = 下边，left = 左边，right = 右边。
enum Direction: String, Codable, CaseIterable {
    case up, down, left, right

    var opposite: Direction {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }
    var label: String {
        switch self {
        case .up: return "上"
        case .down: return "下"
        case .left: return "左"
        case .right: return "右"
        }
    }
    var arrow: String {
        switch self {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        }
    }
    /// 上边、下边为 true（这两条边是横线，沿边方向是 x）
    var isVertical: Bool { self == .up || self == .down }
    /// 作为「边」时的叫法：上边 / 下边 / 左边 / 右边
    var edgeLabel: String { label + "边" }
}

// MARK: - 波纹参数

/// 07「光标特效」页上的总开关 + 10 个参数。数值单位：大小是点，时间是秒。
struct RippleConfig: Codable, Equatable {
    var enabled = true
    var leaveSize: Double = 70          // 离开波纹：环的大小（最大半径）
    var leaveDuration: Double = 0.4     // 离开波纹：每个环的时长
    var leaveInterval: Double = 0.1     // 离开波纹：出环间隔（环都出在离开点，不跟随光标）
    var leaveTotal: Double = 1.0        // 离开波纹：持续时间（到点不再出新环；光标回到本机也立即停）
    var arriveSize: Double = 140        // 进入波纹：环的大小
    var arriveDuration: Double = 0.5    // 进入波纹：每个环的时长
    var spawnInterval: Double = 0.1     // 进入波纹：出环间隔
    var minDuration: Double = 1.0       // 进入波纹：至少持续
    var idleStop: Double = 0.5          // 进入波纹：停下判定时间
    var maxDuration: Double = 5.0       // 进入波纹：最长持续
    var leaveColors: [String] = RippleConfig.defaultLeaveColors    // 离开波纹的颜色（#RRGGBB），出环时按顺序循环取色
    var arriveColors: [String] = RippleConfig.defaultArriveColors  // 进入波纹的颜色

    /// 默认颜色（设计稿 v7）：离开波纹先白后黑，进入波纹先黑后白。只影响新装和「恢复默认值」，已同步的配置不动
    static let defaultLeaveColors = ["#FFFFFF", "#000000"]
    static let defaultArriveColors = ["#000000", "#FFFFFF"]
    /// 每组最多几个颜色（卡片里放得下的数量）；最少一个
    static let maxColors = 5

    static let defaults = RippleConfig()

    /// 每个参数的取值范围和步进（界面步进框、同步收到的数据都按它夹取）
    struct Spec {
        let range: ClosedRange<Double>
        let step: Double
        let isSeconds: Bool
    }
    static let specs: [WritableKeyPath<RippleConfig, Double>: Spec] = [
        \.leaveSize: Spec(range: 20...300, step: 10, isSeconds: false),
        \.leaveDuration: Spec(range: 0.1...3, step: 0.1, isSeconds: true),
        \.leaveInterval: Spec(range: 0.05...1, step: 0.05, isSeconds: true),
        \.leaveTotal: Spec(range: 0...5, step: 0.1, isSeconds: true),
        \.arriveSize: Spec(range: 20...400, step: 10, isSeconds: false),
        \.arriveDuration: Spec(range: 0.1...3, step: 0.1, isSeconds: true),
        \.spawnInterval: Spec(range: 0.05...1, step: 0.05, isSeconds: true),
        \.minDuration: Spec(range: 0...10, step: 0.5, isSeconds: true),
        \.idleStop: Spec(range: 0.1...5, step: 0.1, isSeconds: true),
        \.maxDuration: Spec(range: 0.5...20, step: 0.5, isSeconds: true),
    ]

    /// 把每个参数夹到合法范围、按步进取整，并保证「最长持续」不小于「至少持续」
    func sanitized() -> RippleConfig {
        var c = self
        for (kp, spec) in RippleConfig.specs {
            var v = c[keyPath: kp]
            if !v.isFinite { v = RippleConfig.defaults[keyPath: kp] }
            v = (v / spec.step).rounded() * spec.step
            v = (v * 1000).rounded() / 1000
            c[keyPath: kp] = min(max(v, spec.range.lowerBound), spec.range.upperBound)
        }
        if c.maxDuration < c.minDuration { c.maxDuration = c.minDuration }
        c.leaveColors = RippleConfig.cleanColors(c.leaveColors, fallback: RippleConfig.defaultLeaveColors)
        c.arriveColors = RippleConfig.cleanColors(c.arriveColors, fallback: RippleConfig.defaultArriveColors)
        return c
    }

    init() {}

    // 自己写解码：将来加了新参数，旧文件里缺的键用默认值，不至于整个读不出来
    init(from decoder: Decoder) throws {
        let d = RippleConfig.defaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        leaveSize = try c.decodeIfPresent(Double.self, forKey: .leaveSize) ?? d.leaveSize
        leaveDuration = try c.decodeIfPresent(Double.self, forKey: .leaveDuration) ?? d.leaveDuration
        leaveInterval = try c.decodeIfPresent(Double.self, forKey: .leaveInterval) ?? d.leaveInterval
        leaveTotal = try c.decodeIfPresent(Double.self, forKey: .leaveTotal) ?? d.leaveTotal
        arriveSize = try c.decodeIfPresent(Double.self, forKey: .arriveSize) ?? d.arriveSize
        arriveDuration = try c.decodeIfPresent(Double.self, forKey: .arriveDuration) ?? d.arriveDuration
        spawnInterval = try c.decodeIfPresent(Double.self, forKey: .spawnInterval) ?? d.spawnInterval
        minDuration = try c.decodeIfPresent(Double.self, forKey: .minDuration) ?? d.minDuration
        idleStop = try c.decodeIfPresent(Double.self, forKey: .idleStop) ?? d.idleStop
        maxDuration = try c.decodeIfPresent(Double.self, forKey: .maxDuration) ?? d.maxDuration
        leaveColors = try c.decodeIfPresent([String].self, forKey: .leaveColors) ?? d.leaveColors
        arriveColors = try c.decodeIfPresent([String].self, forKey: .arriveColors) ?? d.arriveColors
    }
}

// MARK: - 颜色

extension RippleConfig {
    /// 只留合法的 #RRGGBB（统一成大写），最多 maxColors 个；一个都不剩就回到这一组的默认颜色
    static func cleanColors(_ list: [String], fallback: [String]) -> [String] {
        let ok = list.compactMap { s -> String? in
            guard let rgb = parseHexColor(s) else { return nil }
            return hexColorString(rgb)
        }
        return ok.isEmpty ? fallback : Array(ok.prefix(maxColors))
    }
}

/// 第 index 个环（从 0 起）用的颜色：按列表顺序循环
func cycledColor(_ colors: [String], _ index: Int) -> String {
    guard !colors.isEmpty else { return RippleConfig.defaultArriveColors[0] }
    return colors[((index % colors.count) + colors.count) % colors.count]
}

/// 用户输入的 HEX 是否有效：六位十六进制数字，带不带 # 都认（前后空格忽略）；有效时返回统一成大写的 #RRGGBB
func normalizedHexInput(_ s: String) -> String? {
    var h = Substring(s.trimmingCharacters(in: .whitespaces))
    if h.hasPrefix("#") { h = h.dropFirst() }
    guard h.count == 6, h.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
    return "#" + h.uppercased()
}

/// "#RRGGBB" → 0~1 的 r、g、b
func parseHexColor(_ s: String) -> (Double, Double, Double)? {
    guard let h = normalizedHexInput(s), let v = UInt32(h.dropFirst(), radix: 16) else { return nil }
    return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
}

func hexColorString(_ rgb: (Double, Double, Double)) -> String {
    func b(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", b(rgb.0), b(rgb.1), b(rgb.2))
}

// MARK: - 共享设置（两台同步）

/// 两台存的是同一份：谁是主控、屏幕布局和由它推导出的相邻规则、波纹参数。规则里写的是具体哪台的哪块屏，
/// 各自用 AdjacencyRule.view(from:) 换算成本机视角，两台不会存反；对调角色时布局和规则都不变。
/// 布局和规则总是一起改：修改的一方从布局算出规则、一起发出去，另一方照单全收，不自己重算。
struct SharedSettings: Codable, Equatable {
    var revision: UInt64            // 每改一次加 1；同步时取修订号大的
    var editor: String              // 最后修改者的设备 ID（修订号相同时按它比大小，两台结论一致）
    var controllerID: String        // 主控（键鼠所在那台）的设备 ID
    var layout: [ScreenSpot] = []   // 屏幕布局：两台每块屏在「设备连接」页上的位置（毫米）
    var rules: [AdjacencyRule] = [] // 屏幕相邻规则（从布局推导）
    var rulesInitialized = false    // 默认布局生成过没有（配对后只生成一次）
    var ripple: RippleConfig

    init(revision: UInt64, editor: String, controllerID: String, layout: [ScreenSpot] = [],
         rules: [AdjacencyRule] = [], rulesInitialized: Bool = false, ripple: RippleConfig) {
        self.revision = revision
        self.editor = editor
        self.controllerID = controllerID
        self.layout = layout
        self.rules = rules
        self.rulesInitialized = rulesInitialized
        self.ripple = ripple
    }

    // 自己写解码，兼容旧数据：没有规则字段（更早的版本只有已废弃的 layoutAnchor / layoutOtherIs）按「还没有规则」处理；
    // 有规则、没有布局字段的，布局读成空，由 AppModel 按规则摆出布局（见 ScreenLayout.migrated）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(UInt64.self, forKey: .revision)
        editor = try c.decode(String.self, forKey: .editor)
        controllerID = try c.decode(String.self, forKey: .controllerID)
        layout = try c.decodeIfPresent([ScreenSpot].self, forKey: .layout) ?? []
        rules = try c.decodeIfPresent([AdjacencyRule].self, forKey: .rules) ?? []
        rulesInitialized = try c.decodeIfPresent(Bool.self, forKey: .rulesInitialized) ?? false
        ripple = try c.decodeIfPresent(RippleConfig.self, forKey: .ripple) ?? .defaults
    }

    func isNewer(than o: SharedSettings) -> Bool {
        if revision != o.revision { return revision > o.revision }
        return editor > o.editor
    }

    /// 只认这两台的 ID：对方发来的设置里出现别的 ID 就当它不合法
    func isValid(me: String, peer: String) -> Bool {
        let ids: Set<String> = [me, peer]
        return ids.contains(controllerID) && ids.contains(editor)
            && rules.allSatisfy { ids.contains($0.aDevice) && ids.contains($0.bDevice) && $0.aDevice != $0.bDevice
                && $0.offsetMM.isFinite }
            && layout.allSatisfy { ids.contains($0.device) && $0.x.isFinite && $0.y.isFinite }
    }

    /// 还要不要补生成默认布局
    var needsDefaultLayout: Bool { !rulesInitialized }

    /// 旧数据：生成过默认规则（或有规则），但还没有布局
    var needsLayoutMigration: Bool { rulesInitialized && layout.isEmpty }
}

// MARK: - 配对记录

struct PairingRecord: Codable, Equatable {
    var peerID: String
    var peerName: String
    var peerIsLaptop: Bool
    var keyBase64: String
    var lastAddress: String?        // 上次成功连上对方时对方的 IPv4 地址（Bonjour 找不到时的后备）

    var key: SymmetricKey? {
        guard let d = Data(base64Encoded: keyBase64), d.count == 32 else { return nil }
        return SymmetricKey(data: d)
    }
}

// MARK: - 落盘

struct PersistedState: Codable {
    var deviceID: String
    var pairing: PairingRecord?
    var shared: SharedSettings?
    var ripple: RippleConfig = .defaults        // 本机保留的一份波纹参数：配对时作为初值，解除配对后也不丢
    var pendingUnpair: PairingRecord?           // 解除配对时对方不在线：记着，等它上线再通知
    var peerScreens: [ScreenInfo]?              // 对方上次发来的屏幕清单（离线时界面用它）
    var knownScreens: [ScreenInfo]?             // 两台见过的所有屏幕（拔掉的屏在界面上还能显示名字和尺寸）
    var language: Language?                     // 界面语言：用户手动切过才有；nil = 跟系统。只存本机，不同步

    init(deviceID: String) { self.deviceID = deviceID }
}

final class Store {
    let dir: URL
    var file: URL { dir.appendingPathComponent("state.json") }

    init() {
        if let h = ProcessInfo.processInfo.environment["MACKVM_HOME"], !h.isEmpty {
            dir = URL(fileURLWithPath: h)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MacKVM")
        }
    }

    init(dir: URL) { self.dir = dir }

    func load() -> PersistedState {
        if let d = FileManager.default.contents(atPath: file.path) {
            do {
                return try JSONDecoder().decode(PersistedState.self, from: d)
            } catch {
                // 读坏了不要直接覆盖：留一份备查，再从头开始
                let bad = dir.appendingPathComponent("state.broken-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: file, to: bad)
                log("警告：\(file.path) 解析失败（\(error)），已改名为 \(bad.lastPathComponent)，按未配对处理")
            }
        }
        let s = PersistedState(deviceID: UUID().uuidString.lowercased())
        log("第一次运行：生成本机设备 ID \(s.deviceID)")
        save(s)
        return s
    }

    /// 原子写入：先写同目录的临时文件（创建时就是 600），再改名替换
    func save(_ s: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(s)
            let tmp = dir.appendingPathComponent(".state.\(getpid()).tmp")
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let ok = data.withUnsafeBytes { buf -> Bool in
                write(fd, buf.baseAddress, buf.count) == buf.count
            }
            fsync(fd)
            Darwin.close(fd)
            guard ok else { throw POSIXError(.EIO) }
            guard rename(tmp.path, file.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } catch {
            log("错误：保存 \(file.path) 失败：\(error)")
        }
    }
}

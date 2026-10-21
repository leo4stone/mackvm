// 公共小工具：
//   - log()：写一行带时间和角色标签的日志到 stderr（launchd 把 stderr 重定向到 ~/Library/Logs/MacKVM.log；
//     不是 launchd 拉起时 main.swift 会把 stderr 接到同一个文件）；
//   - 数值格式化、夹取；
//   - 当前所有显示器的矩形（CG 全局坐标）；
//   - Data 的大端整数 / Double 读写。

import AppKit
import Foundation

let kVersion = "16.3"
let kBundleID = "io.github.leo4stone.mackvm"
let kAgentLabel = "io.github.leo4stone.mackvm"
let kLogPath = NSHomeDirectory() + "/Library/Logs/MacKVM.log"

// MARK: - 日志

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// 日志行里方括号中的角色标签：未配对 / 主控 / 被控
var logRole = "未配对"

func log(_ s: String) {
    let line = "\(logFormatter.string(from: Date())) [\(logRole)] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

func fmt(_ d: Double) -> String { String(format: "%.3f", d) }
func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }

// MARK: - 显示器

/// 所有活动显示器的范围（CG 全局坐标：原点在主屏左上角，y 向下）
func activeDisplays() -> [CGRect] {
    ScreenCatalog.activeDisplayIDs().map { CGDisplayBounds($0) }
}

// MARK: - 二进制读写

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var b = v.bigEndian
        Swift.withUnsafeBytes(of: &b) { append(contentsOf: $0) }
    }
    mutating func appendDouble(_ d: Double) { appendBE(d.bitPattern) }

    func readBE<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= count else { return nil }
        var v: T = 0
        for i in 0..<size { v = (v << 8) | T(self[startIndex + offset + i]) }
        return v
    }
    func readDouble(_ offset: Int) -> Double? {
        readBE(offset, UInt64.self).map { Double(bitPattern: $0) }
    }
}

// 读取本机的显示器清单（给相邻规则用）：
//   - 稳定 ID：CGDisplayCreateUUIDFromDisplayID（系统按厂商 / 型号 / 序列号生成的显示器 UUID，跨重启、跨插拔不变；
//     换个接口插也一样）。拿不到时退回「厂商-型号-序列号」拼的字符串；
//   - 名字：内建屏一律叫「内建屏幕」，外接屏用系统给的显示器名（如「DELL U2720QM」）；
//   - 物理尺寸：CGDisplayScreenSize（毫米）。读不到或明显不合理（太小、太大、长宽比和分辨率对不上）时按分辨率估算并标明；
//   - 镜像：镜像组里只保留被镜像的那一块（镜像出来的屏和它同一个坐标框），算一块屏；
//   - 可用区域：NSScreen.visibleFrame 换算成 CG 坐标后，只扣掉程序坞条（菜单栏那一条补回来，不扣——
//     否则规则在上边时菜单栏就点不到了）。用于跨屏触发线和落点，见 CrossingMap.hit / landing。
// 屏幕排列、接线、程序坞位置变化时由 AppModel 收到 NSApplication.didChangeScreenParametersNotification 后重新读取。

import AppKit
import CoreGraphics

enum ScreenCatalog {
    static func current() -> [ScreenInfo] {
        let ids = activeDisplayIDs()
        guard !ids.isEmpty else { return [] }
        let main = CGMainDisplayID()
        var names: [CGDirectDisplayID: String] = [:]
        var visible: [CGDirectDisplayID: (frame: CGRect, visible: CGRect)] = [:]
        // AppKit 坐标原点在主屏（菜单栏所在那块，NSScreen.screens[0]）左下角、y 向上；CG 坐标原点在它左上角、y 向下
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        func toCG(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height) }
        for s in NSScreen.screens {
            if let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[CGDirectDisplayID(num.uint32Value)] = s.localizedName
                visible[CGDirectDisplayID(num.uint32Value)] = (toCG(s.frame), toCG(s.visibleFrame))
            }
        }
        var out: [ScreenInfo] = []
        for d in ids {
            // 镜像出来的屏跳过，只留被镜像的那一块
            if CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay { continue }
            let b = CGDisplayBounds(d)
            let builtin = CGDisplayIsBuiltin(d) != 0
            let (mmW, mmH, est) = physicalSize(d, bounds: b)
            var info = ScreenInfo(id: stableID(d), name: builtin ? "内建屏幕" : (names[d] ?? "显示器"),
                                  isMain: d == main || CGDisplayIsMain(d) != 0, isBuiltin: builtin,
                                  x: b.minX, y: b.minY, w: b.width, h: b.height,
                                  mmW: mmW, mmH: mmH, estimated: est)
            if let v = visible[d], let u = usableRect(bounds: b, nsFrame: v.frame, nsVisible: v.visible) {
                info.ux = u.minX; info.uy = u.minY; info.uw = u.width; info.uh = u.height
            }
            out.append(info)
        }
        return out
    }

    /// 可用区域（CG 坐标）：visibleFrame 只扣程序坞条，菜单栏那一条（总在顶上）补回来。
    /// NSScreen 的框和 CGDisplayBounds 对不上（坐标换算有误）、或扣完和整块屏一样时返回 nil（= 用整块屏）
    static func usableRect(bounds b: CGRect, nsFrame: CGRect, nsVisible: CGRect) -> CGRect? {
        guard abs(nsFrame.minX - b.minX) < 1, abs(nsFrame.minY - b.minY) < 1,
              abs(nsFrame.width - b.width) < 1, abs(nsFrame.height - b.height) < 1 else { return nil }
        let v = nsVisible.intersection(b)
        guard !v.isNull, v.width >= 100, v.height >= 100 else { return nil }
        let u = CGRect(x: v.minX, y: b.minY, width: v.width, height: v.maxY - b.minY)
        return u == b ? nil : u
    }

    /// 可用区域比整块屏少了哪几条边（写日志用），如「程序坞占 下边 97 点」
    static func describeInsets(_ s: ScreenInfo) -> String {
        let f = s.frame, u = s.usableFrame
        var parts: [String] = []
        if u.minX - f.minX >= 1 { parts.append("左边 \(Int(u.minX - f.minX)) 点") }
        if f.maxX - u.maxX >= 1 { parts.append("右边 \(Int(f.maxX - u.maxX)) 点") }
        if u.minY - f.minY >= 1 { parts.append("上边 \(Int(u.minY - f.minY)) 点") }
        if f.maxY - u.maxY >= 1 { parts.append("下边 \(Int(f.maxY - u.maxY)) 点") }
        return parts.isEmpty ? "程序坞不占这块屏" : "程序坞占 " + parts.joined(separator: "、")
    }

    /// 活动显示器的 ID。实测（macOS 26，LaunchAgent 进程）先用 0 问数量的写法会得到 0 块，
    /// 所以直接给一个够大的缓冲区；仍然拿不到时退回 NSScreen 的显示器编号
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        if CGGetActiveDisplayList(32, &ids, &n) == .success, n > 0 { return Array(ids.prefix(Int(n))) }
        return NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
        }
    }

    /// 读不到显示器时写进日志的排查信息
    static func debugSummary() -> String {
        var n: UInt32 = 0
        let e = CGGetActiveDisplayList(0, nil, &n)
        return "CGGetActiveDisplayList 结果 \(e.rawValue)、\(n) 块，NSScreen \(NSScreen.screens.count) 块"
    }

    static func stableID(_ d: CGDirectDisplayID) -> String {
        if let u = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, u) as String? {
            return s
        }
        return "\(CGDisplayVendorNumber(d))-\(CGDisplayModelNumber(d))-\(CGDisplaySerialNumber(d))"
    }

    /// 物理尺寸（毫米）和是否为估算
    static func physicalSize(_ d: CGDirectDisplayID, bounds b: CGRect) -> (Double, Double, Bool) {
        let mm = CGDisplayScreenSize(d)
        let ok = mm.width > 50 && mm.height > 30 && mm.width < 3000 && mm.height < 2000
            && b.width > 0 && b.height > 0
            && abs(Double(mm.width / mm.height) / Double(b.width / b.height) - 1) < 0.2
        if ok { return (Double(mm.width), Double(mm.height), false) }
        // 估算：按每点 0.25 毫米（约 100 点 / 英寸，常见外接屏「看起来像」的密度）
        return (Double(b.width) * 0.25, Double(b.height) * 0.25, true)
    }
}

// 界面里的图标：
//   - DeviceIcon：设计稿里的线条显示器图标（72×72 网格）：屏幕外框、下巴分隔线、两根支架、底座，线宽 1.5。
//     输入设备（键鼠接在这台）的显示器里画上键盘和鼠标；另一台是空显示器。
//     SF Symbols 里的显示器屏幕是实心的，和设计稿不像，所以自己画；
//   - AppIcon / AppIconView：程序图标（圆环里一只鼠标，单色模板图、不带底板），菜单栏和主窗口标题栏用。

import AppKit
import SwiftUI

struct DeviceIcon: View {
    var withInput: Bool
    var color: Color
    var size: CGFloat = 72

    var body: some View {
        let k = size / 72
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
                var path = Path(roundedRect: CGRect(x: 4.3 * k, y: 12.4 * k, width: 62.3 * k, height: 39.5 * k),
                                cornerRadius: 1.7 * k)
                path.move(to: p(4.3, 48.7)); path.addLine(to: p(66.6, 48.7))      // 下巴分隔线
                path.move(to: p(33.1, 51.9)); path.addLine(to: p(33.1, 60.2))     // 支架
                path.move(to: p(39.3, 51.9)); path.addLine(to: p(39.3, 60.2))
                path.move(to: p(23.4, 60.8)); path.addLine(to: p(47.4, 60.8))     // 底座
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
            if withInput {
                HStack(spacing: 5 * k) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 15 * k, weight: .regular))
                        .frame(width: 25 * k, height: 22 * k)
                    Image(systemName: "computermouse")
                        .font(.system(size: 13 * k, weight: .regular))
                        .frame(width: 14 * k, height: 22 * k)
                }
                .foregroundStyle(color)
                .offset(x: 14 * k, y: 20 * k)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 程序图标

/// 程序图标的加载。资源在 MacKVM.app/Contents/Resources（build.sh 从仓库的 Resources/ 拷进去）：
/// 优先用矢量的 mackvm-icon.svg，系统读不了 SVG 时退回 22 / 43 / 86 像素的三张 PNG（按屏幕缩放挑最合适的一张）。
/// 离屏渲染程序不是 .app，由它把 resourceDirectory 指到仓库的 Resources/。哪里都找不到就返回 nil，调用方不画图标。
/// 图标是模板图：只用透明度，颜色由使用的地方定（菜单栏随深浅色自动反白，标题栏用正文色）。
enum AppIcon {
    static var resourceDirectory: URL? = Bundle.main.resourceURL
    private static var cache: [CGFloat: NSImage] = [:]

    /// 边长 points 点的图标
    static func image(points: CGFloat) -> NSImage? {
        if let img = cache[points] { return img }
        guard let dir = resourceDirectory else { return nil }
        let size = NSSize(width: points, height: points)
        var img: NSImage
        if let svg = NSImage(contentsOf: dir.appendingPathComponent("mackvm-icon.svg")), svg.isValid, svg.size.width > 0 {
            img = svg
        } else {
            let reps = ["mackvm-icon-22px.png", "mackvm-icon-43px.png", "mackvm-icon-86px.png"]
                .compactMap { NSImageRep(contentsOf: dir.appendingPathComponent($0)) }
            guard !reps.isEmpty else { return nil }
            img = NSImage(size: size)
            for r in reps {
                r.size = size
                img.addRepresentation(r)
            }
        }
        img.size = size
        img.isTemplate = true
        cache[points] = img
        return img
    }
}

/// 标题栏里的程序图标：颜色取 foregroundStyle
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        if let img = AppIcon.image(points: size) {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .frame(width: size, height: size)
        }
    }
}

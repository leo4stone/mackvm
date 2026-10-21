// 设计稿里的线条显示器图标（72×72 网格）：屏幕外框、下巴分隔线、两根支架、底座，线宽 1.5。
// 输入设备（键鼠接在这台）的显示器里画上键盘和鼠标；另一台是空显示器。
// SF Symbols 里的显示器屏幕是实心的，和设计稿不像，所以自己画。

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

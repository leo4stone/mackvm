// 界面公共样式：设计稿（design/design.html）里用到的颜色、字号，以及几种按钮、卡片、描边的写法。
// 设计稿只有浅色，界面固定用浅色外观。

import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

enum Theme {
    static let text = Color(hex: 0x202632)
    static let sub = Color(hex: 0x6B7482)
    static let blue = Color(hex: 0x2869E8)
    static let border = Color(hex: 0xE3E7EE)
    static let windowBG = Color(hex: 0xF7F8FA)
    static let titleBG = Color(hex: 0xF0F2F5)
    static let tabOff = Color(hex: 0xF0F2F5)
    static let segmentBG = Color(hex: 0xE5E9F0)
    static let closeBG = Color(hex: 0xF3F5F8)
    static let greyButton = Color(hex: 0xF0F2F6)
    static let green = Color(hex: 0x248451)
    static let greenText = Color(hex: 0x237A4D)
    static let greenBG = Color(hex: 0xE4F4EC)
    static let amber = Color(hex: 0x9B6917)
    static let amberBG = Color(hex: 0xFBF1DF)
    static let red = Color(hex: 0xC13E3E)
    static let offlineBG = Color(hex: 0xEDEFF2)
    static let diagramBG = Color(hex: 0xEDF2FA)
    static let peerCardBG = Color(hex: 0xE0EAFE)
    static let peerCardBorder = Color(hex: 0x6A96EC)
    static let localCardBorder = Color(hex: 0xBFCADB)
    static let caption = Color(hex: 0x4E6487)
    static let codeCell = Color(hex: 0xF0F4FC)
    static let rowSelected = Color(hex: 0xEAF1FF)
    static let fieldBG = Color(hex: 0xF7F8FA)
    static let ringStrong = Color(hex: 0x6192ED)
    static let ringLight = Color(hex: 0xCADAF9)
    static let mask = Color(hex: 0x202632, alpha: Double(0x55) / 255)
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - 行高

extension View {
    /// 设计稿的文字行高是字号 × 1.448（Noto Sans SC 的 normal 行高），SwiftUI 的系统字体只有约 1.2 倍：
    /// 上下各补一半差值，让各元素的高度和间距和设计稿对齐
    func lh(_ size: CGFloat) -> some View {
        padding(.vertical, max(0, (size * 1.448 - (size * 1.2).rounded(.up)) / 2))
    }
}

// MARK: - 按钮

/// 设计稿里的几种按钮：蓝底白字（主操作）、白底描边（次要操作）、浅灰底（取消）、红底（危险操作）
struct KVMButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, grey, danger }
    var kind: Kind = .primary
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var padV: CGFloat = 10
    var padH: CGFloat = 18
    var radius: CGFloat = 8
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg, stroke): (Color, Color, Color?) = {
            switch kind {
            case .primary: return (Theme.blue, .white, nil)
            case .secondary: return (.white, Theme.text, Theme.border)
            case .grey: return (Theme.greyButton, Theme.text, nil)
            case .danger: return (Theme.red, .white, nil)
            }
        }()
        return configuration.label
            .font(.ui(size, weight)).lh(size)
            .foregroundStyle(fg)
            .padding(.vertical, padV)
            .padding(.horizontal, padH)
            .background(RoundedRectangle(cornerRadius: radius).fill(bg))
            .overlay {
                if let stroke { RoundedRectangle(cornerRadius: radius).strokeBorder(stroke, lineWidth: 1) }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    /// 白底、圆角、1 像素浅灰描边的卡片
    func card(radius: CGFloat = 12, padding: CGFloat = 28, fill: Color = .white, stroke: Color = Theme.border) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke, lineWidth: 1))
    }
}

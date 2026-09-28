import ETOSCore
import SwiftUI
import UIKit

/// 气泡与发送层共用实际材质；这里只绘制背景，不订阅配置或参与文字排版。
struct ChatBubbleBackground<S: Shape>: View {
    let shape: S
    let fill: AnyShapeStyle
    let enableLiquidGlass: Bool

    var body: some View {
        if enableLiquidGlass, #available(iOS 26.0, *) {
            shape.fill(fill)
                .glassEffect(.clear, in: shape)
                .clipShape(shape)
        } else {
            shape.fill(fill)
        }
    }
}

struct ChatOutgoingBubbleColors {
    let start: Color
    let end: Color

    init(profile: ChatAppearanceProfile) {
        let fallback = Color(red: 0.24, green: 0.56, blue: 0.95)
        start = profile.userBubble.isEnabled
            ? ChatAppearanceColorCodec.color(from: profile.userBubble.hex, fallback: fallback)
            : fallback
        end = profile.userBubble.isEnabled
            ? ChatAppearanceColorCodec.darkened(start, factor: 0.86)
            : Color(red: 0.17, green: 0.45, blue: 0.82)
    }

    func gradient(enableBackground: Bool) -> LinearGradient {
        let opacity = enableBackground ? 0.85 : 1.0
        return LinearGradient(
            colors: [start.opacity(opacity), end.opacity(opacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct ChatSendFlightBackground {
    let fill: AnyShapeStyle
    let enableLiquidGlass: Bool
    let isFile: Bool
    var cornerRadius: CGFloat { isFile ? 12 : 18 }

    static func resolved(
        for source: ChatSendPresentationSource,
        colors: ChatOutgoingBubbleColors,
        enableBackground: Bool,
        enableLiquidGlass: Bool
    ) -> Self? {
        switch source {
        case .image:
            return nil
        case .file:
            // 文件原来就是纯色卡片，不应用正文的玻璃或壁纸透明度。
            return Self(fill: AnyShapeStyle(colors.end), enableLiquidGlass: false, isFile: true)
        case .text, .audio:
            return Self(
                fill: AnyShapeStyle(colors.gradient(enableBackground: enableBackground)),
                enableLiquidGlass: enableLiquidGlass,
                isFile: false
            )
        }
    }
}

private struct ChatSendFlightBackgroundContent: View {
    let background: ChatSendFlightBackground
    let cornerRadius: CGFloat

    var body: some View {
        if background.isFile {
            ChatBubbleBackground(
                shape: RoundedRectangle(cornerRadius: cornerRadius),
                fill: background.fill,
                enableLiquidGlass: false
            )
        } else {
            ChatBubbleBackground(
                shape: BubbleCornerShape(
                    topLeft: cornerRadius, topRight: cornerRadius,
                    bottomLeft: cornerRadius, bottomRight: cornerRadius
                ),
                fill: background.fill,
                enableLiquidGlass: background.enableLiquidGlass
            )
        }
    }
}

/// 只宿主无状态背景；原生表面继续持有位置与尺寸，不向聊天根视图发布逐帧进度。
@MainActor
final class ChatSendFlightBackgroundHost {
    let view: UIView & UIContentView
    private let background: ChatSendFlightBackground
    private let environment: EnvironmentValues
    private var cornerRadius: CGFloat = 0

    init(background: ChatSendFlightBackground, environment: EnvironmentValues) {
        self.background = background
        self.environment = environment
        view = Self.configuration(background, radius: 0, environment: environment).makeContentView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.alpha = 0
    }

    func update(frame: CGRect, progress: CGFloat) {
        view.frame = frame
        view.alpha = progress
        let radius = background.cornerRadius * progress
        guard radius != cornerRadius else { return }
        cornerRadius = radius
        // 保留同一个宿主，仅在展开形状改变时更新这棵无文字子树。
        view.configuration = Self.configuration(background, radius: radius, environment: environment)
    }

    private static func configuration(
        _ background: ChatSendFlightBackground,
        radius: CGFloat,
        environment: EnvironmentValues
    ) -> some UIContentConfiguration {
        UIHostingConfiguration {
            ChatSendFlightBackgroundContent(background: background, cornerRadius: radius)
                .environment(\.self, environment)
        }
        .margins(.all, 0)
        .minSize(width: 0, height: 0)
    }
}

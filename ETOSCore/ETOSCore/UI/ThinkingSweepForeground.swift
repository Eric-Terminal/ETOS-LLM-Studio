import SwiftUI

private struct ThinkingSweepUsesRainbowKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// 由消息气泡注入当次请求快照，推理标题和工具等待提示共用同一样式。
    var thinkingSweepUsesRainbow: Bool {
        get { self[ThinkingSweepUsesRainbowKey.self] }
        set { self[ThinkingSweepUsesRainbowKey.self] = newValue }
    }
}

/// 默认沿用原来的单色扫光，只有请求档位满足条件时才使用彩虹。
public struct ThinkingSweepForeground<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.thinkingSweepUsesRainbow) private var usesRainbow

    private let baseColor: Color
    private let highlightColor: Color
    private let content: Content

    public init(baseColor: Color, highlightColor: Color, @ViewBuilder content: () -> Content) {
        self.baseColor = baseColor
        self.highlightColor = highlightColor
        self.content = content()
    }

    public var body: some View {
        if usesRainbow {
            RainbowSweepForeground(baseColor: baseColor) { content }
        } else {
            content
                .foregroundStyle(baseColor)
                .overlay {
                    if !reduceMotion {
                        GeometryReader { proxy in
                            TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
                                monochromeBand(size: proxy.size, date: timeline.date)
                            }
                        }
                        .mask { content }
                        .allowsHitTesting(false)
                    }
                }
        }
    }

    private var frameInterval: TimeInterval {
#if os(watchOS)
        1.0 / 20.0
#else
        1.0 / 30.0
#endif
    }

    private func monochromeBand(size: CGSize, date: Date) -> some View {
#if os(watchOS)
        let bandWidth = max(1, size.width * 0.7)
#else
        let bandWidth = max(1, size.width * 0.6)
#endif
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
        return Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: highlightColor, location: 0.35),
                        .init(color: highlightColor, location: 0.65),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: bandWidth, height: max(1, size.height * 1.6))
            .rotationEffect(.degrees(18))
            .position(x: -bandWidth + (size.width + 2 * bandWidth) * phase, y: size.height / 2)
            .blendMode(.screen)
    }
}

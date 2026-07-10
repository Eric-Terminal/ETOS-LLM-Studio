// ============================================================================
// FlowingRainbowViews.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供滑块最高档与思考状态共用的流动彩虹和柔和彩色扫光。
// ============================================================================

import SwiftUI

public enum FlowingRainbowAxis: Sendable {
    case horizontal
    case vertical
}

// 色值与间隔参考 Google AI Studio 的 Thinking 扫光，透明区保留原文字色。
private let rainbowSweepStops: [Gradient.Stop] = [
    .init(color: .clear, location: 0),
    .init(color: Color(red: 0.48, green: 0.67, blue: 0.97), location: 0.18),
    .init(color: Color(red: 0.48, green: 0.67, blue: 0.97), location: 0.25),
    .init(color: .clear, location: 0.31),
    .init(color: Color(red: 0.37, green: 0.77, blue: 0.48), location: 0.39),
    .init(color: Color(red: 0.37, green: 0.77, blue: 0.48), location: 0.46),
    .init(color: .clear, location: 0.52),
    .init(color: Color(red: 0.99, green: 0.83, blue: 0.38), location: 0.60),
    .init(color: Color(red: 0.99, green: 0.83, blue: 0.38), location: 0.67),
    .init(color: .clear, location: 0.73),
    .init(color: Color(red: 0.91, green: 0.72, blue: 0.71), location: 0.81),
    .init(color: Color(red: 0.91, green: 0.72, blue: 0.71), location: 0.88),
    .init(color: .clear, location: 1)
]

#if os(watchOS)
private let rainbowSweepFrameInterval: TimeInterval = 1.0 / 20.0
#else
private let rainbowSweepFrameInterval: TimeInterval = 1.0 / 30.0
#endif

public struct FlowingRainbowGradient: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let axis: FlowingRainbowAxis
    private let duration: TimeInterval

    public init(axis: FlowingRainbowAxis = .horizontal, duration: TimeInterval = 2.8) {
        self.axis = axis
        self.duration = duration
    }

    public var body: some View {
        GeometryReader { proxy in
            if reduceMotion {
                rainbowLayer(size: proxy.size, phase: 0.2)
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval)) { timeline in
                    rainbowLayer(size: proxy.size, phase: phase(at: timeline.date))
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func rainbowLayer(size: CGSize, phase: Double) -> some View {
        switch axis {
        case .horizontal:
            LinearGradient(
                colors: Self.repeatingRainbowColors,
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: max(size.width * 2, 1), height: max(size.height, 1))
            .offset(x: -size.width * phase)
        case .vertical:
            LinearGradient(
                colors: Self.repeatingRainbowColors,
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )
            .frame(width: max(size.width, 1), height: max(size.height * 2, 1))
            .offset(y: -size.height * phase)
        }
    }

    private func phase(at date: Date) -> Double {
        let safeDuration = max(duration, 0.1)
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: safeDuration) / safeDuration
    }

    private static let repeatingRainbowColors: [Color] = {
        let cycle: [Color] = [
            Color(red: 0.92, green: 0.26, blue: 0.21),
            Color(red: 0.98, green: 0.58, blue: 0.12),
            Color(red: 0.99, green: 0.82, blue: 0.25),
            Color(red: 0.20, green: 0.66, blue: 0.33),
            Color(red: 0.14, green: 0.76, blue: 0.88),
            Color(red: 0.26, green: 0.52, blue: 0.96),
            Color(red: 0.63, green: 0.26, blue: 0.96),
            Color(red: 0.92, green: 0.26, blue: 0.21)
        ]
        return cycle + cycle.dropFirst()
    }()

#if os(watchOS)
    private static let frameInterval: TimeInterval = 1.0 / 20.0
#else
    private static let frameInterval: TimeInterval = 1.0 / 30.0
#endif
}

public struct FlowingRainbowForeground<Content: View>: View {
    private let axis: FlowingRainbowAxis
    private let duration: TimeInterval
    private let content: Content

    public init(
        axis: FlowingRainbowAxis = .horizontal,
        duration: TimeInterval = 2.8,
        @ViewBuilder content: () -> Content
    ) {
        self.axis = axis
        self.duration = duration
        self.content = content()
    }

    public var body: some View {
        content
            .hidden()
            .overlay {
                FlowingRainbowGradient(axis: axis, duration: duration)
                    .mask { content }
            }
            .accessibilityRepresentation {
                content
            }
    }
}

public struct RainbowSweepForeground<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let baseColor: Color
    private let duration: TimeInterval
    private let content: Content

    public init(
        baseColor: Color,
        duration: TimeInterval = 5,
        @ViewBuilder content: () -> Content
    ) {
        self.baseColor = baseColor
        self.duration = duration
        self.content = content()
    }

    public var body: some View {
        content
            .foregroundStyle(baseColor)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        TimelineView(.animation(minimumInterval: rainbowSweepFrameInterval)) { timeline in
                            sweepBand(
                                size: proxy.size,
                                phase: phase(at: timeline.date)
                            )
                        }
                    }
                    .mask { content }
                    .allowsHitTesting(false)
                }
            }
    }

    private func sweepBand(size: CGSize, phase: Double) -> some View {
        let bandWidth = max(size.width * 2.5, 1)
        let startX = -bandWidth / 2
        let endX = size.width + bandWidth / 2
        return LinearGradient(
            stops: rainbowSweepStops,
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: bandWidth, height: max(size.height * 1.6, 1))
        .position(
            x: startX + (endX - startX) * phase,
            y: size.height / 2
        )
    }

    private func phase(at date: Date) -> Double {
        let safeDuration = max(duration, 0.1)
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: safeDuration) / safeDuration
    }

}

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

enum FlowingRainbowColorCycle {
    private static let canonicalHues: [Double] = [
        0,
        1.0 / 12.0,
        1.0 / 6.0,
        1.0 / 3.0,
        1.0 / 2.0,
        2.0 / 3.0,
        3.0 / 4.0
    ]

    static func unwrappedHues(startingAt rawHue: Double) -> [Double] {
        let hue = normalizedHue(rawHue)
        // 以最近的命名色判断“下一色”，起点仍保留用户设置的精确色相。
        let nearestIndex = canonicalHues.indices.min { lhs, rhs in
            circularDistance(from: hue, to: canonicalHues[lhs])
                < circularDistance(from: hue, to: canonicalHues[rhs])
        } ?? 0
        let followingHues = (1..<canonicalHues.count).map { offset in
            let unwrappedIndex = nearestIndex + offset
            var followingHue = canonicalHues[unwrappedIndex % canonicalHues.count]
                + Double(unwrappedIndex / canonicalHues.count)
            while followingHue <= hue {
                followingHue += 1
            }
            return followingHue
        }
        return [hue] + followingHues + [hue + 1]
    }

    static func repeatingColors(startingAt startingColor: Color?) -> [Color] {
        guard let startingColor,
              let components = RequestBodySliderColorComponents(color: startingColor) else {
            return defaultRepeatingColors
        }
        let hsba = hsbaComponents(from: components)
        var cycle = unwrappedHues(startingAt: hsba.hue).map { hue in
            Color(
                hue: normalizedHue(hue),
                saturation: hsba.saturation,
                brightness: hsba.brightness,
                opacity: hsba.alpha
            )
        }
        cycle[0] = startingColor
        cycle[cycle.count - 1] = startingColor
        return cycle + cycle.dropFirst()
    }

    private static func hsbaComponents(
        from components: RequestBodySliderColorComponents
    ) -> (hue: Double, saturation: Double, brightness: Double, alpha: Double) {
        let maximum = max(components.red, components.green, components.blue)
        let minimum = min(components.red, components.green, components.blue)
        let delta = maximum - minimum
        let saturation = maximum > 0 ? delta / maximum : 0
        let hue: Double
        if delta <= 0.000_001 {
            hue = 0
        } else if maximum == components.red {
            hue = ((components.green - components.blue) / delta) / 6
        } else if maximum == components.green {
            hue = (2 + (components.blue - components.red) / delta) / 6
        } else {
            hue = (4 + (components.red - components.green) / delta) / 6
        }
        return (
            hue: normalizedHue(hue),
            saturation: saturation,
            brightness: maximum,
            alpha: components.alpha
        )
    }

    private static func normalizedHue(_ hue: Double) -> Double {
        guard hue.isFinite else { return 0 }
        let remainder = hue.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func circularDistance(from lhs: Double, to rhs: Double) -> Double {
        let directDistance = abs(lhs - rhs)
        return min(directDistance, 1 - directDistance)
    }

    private static let defaultRepeatingColors: [Color] = {
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
}

public struct FlowingRainbowGradient: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let axis: FlowingRainbowAxis
    private let duration: TimeInterval
    private let phaseOrigin: Date?
    private let startDelay: TimeInterval
    private let rainbowColors: [Color]
    private let reversedRainbowColors: [Color]
    private let cycleLengthMultiplier: CGFloat

    public init(
        axis: FlowingRainbowAxis = .horizontal,
        duration: TimeInterval = 2.8,
        phaseOrigin: Date? = nil,
        startDelay: TimeInterval = 0,
        startingColor: Color? = nil,
        cycleLengthMultiplier: CGFloat = 1
    ) {
        let rainbowColors = FlowingRainbowColorCycle.repeatingColors(startingAt: startingColor)
        self.axis = axis
        self.duration = duration
        self.phaseOrigin = phaseOrigin
        self.startDelay = startDelay
        self.rainbowColors = rainbowColors
        self.reversedRainbowColors = Array(rainbowColors.reversed())
        self.cycleLengthMultiplier = max(cycleLengthMultiplier, 0.1)
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
            let cycleLength = max(size.width * cycleLengthMultiplier, 1)
            LinearGradient(
                colors: rainbowColors,
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: cycleLength * 2, height: max(size.height, 1))
            .offset(x: -cycleLength * phase)
        case .vertical:
            let cycleLength = max(size.height * cycleLengthMultiplier, 1)
            LinearGradient(
                colors: reversedRainbowColors,
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(width: max(size.width, 1), height: cycleLength * 2)
            .offset(y: -cycleLength * phase)
        }
    }

    private func phase(at date: Date) -> Double {
        let safeDuration = max(duration, 0.1)
        let elapsed = if let phaseOrigin {
            max(date.timeIntervalSince(phaseOrigin) - max(startDelay, 0), 0)
        } else {
            date.timeIntervalSinceReferenceDate
        }
        return elapsed
            .truncatingRemainder(dividingBy: safeDuration) / safeDuration
    }

#if os(watchOS)
    private static let frameInterval: TimeInterval = 1.0 / 20.0
#else
    private static let frameInterval: TimeInterval = 1.0 / 30.0
#endif
}

// 完整色谱以循环流动的速度接管原颜色，反向则快速弹簧收回。
public struct FlowingRainbowReveal: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let isActive: Bool
    private let axis: FlowingRainbowAxis
    private let flowDuration: TimeInterval
    private let revealDuration: TimeInterval
    private let retractResponse: TimeInterval
    private let startingColor: Color?
    private let cycleLengthMultiplier: CGFloat
    private let animatesTransition: Bool

    @State private var revealProgress: CGFloat = 0
    @State private var phaseOrigin = Date()
    @State private var rendersRainbow = false
    @State private var cleanupTask: Task<Void, Never>?

    public init(
        isActive: Bool,
        axis: FlowingRainbowAxis = .horizontal,
        flowDuration: TimeInterval = 2.8,
        revealDuration: TimeInterval? = nil,
        retractResponse: TimeInterval = 0.55,
        startingColor: Color? = nil,
        cycleLengthMultiplier: CGFloat = 1,
        animatesTransition: Bool = true
    ) {
        self.isActive = isActive
        self.axis = axis
        self.flowDuration = flowDuration
        self.revealDuration = revealDuration ?? flowDuration
        self.retractResponse = retractResponse
        self.startingColor = startingColor
        self.cycleLengthMultiplier = cycleLengthMultiplier
        self.animatesTransition = animatesTransition
    }

    public var body: some View {
        GeometryReader { proxy in
            if rendersRainbow {
                FlowingRainbowGradient(
                    axis: axis,
                    duration: flowDuration,
                    phaseOrigin: phaseOrigin,
                    startDelay: reduceMotion ? 0 : revealDuration,
                    startingColor: startingColor,
                    cycleLengthMultiplier: cycleLengthMultiplier
                )
                .offset(revealOffset(in: proxy.size))
                .opacity(reduceMotion ? revealProgress : 1)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            setRevealImmediately(isActive: isActive)
        }
        .onChange(of: isActive) { _, isActive in
            updateReveal(isActive: isActive)
        }
        .onChange(of: reduceMotion) { _, _ in
            updateReveal(isActive: isActive)
        }
        .onDisappear {
            cleanupTask?.cancel()
        }
    }

    private func revealOffset(in size: CGSize) -> CGSize {
        guard !reduceMotion else { return .zero }
        let remainingProgress = 1 - min(max(revealProgress, 0), 1)
        switch axis {
        case .horizontal:
            return CGSize(width: size.width * remainingProgress, height: 0)
        case .vertical:
            return CGSize(width: 0, height: size.height * remainingProgress)
        }
    }

    private func updateReveal(isActive: Bool) {
        cleanupTask?.cancel()
        guard animatesTransition else {
            setRevealImmediately(isActive: isActive)
            return
        }
        if isActive {
            phaseOrigin = Date()
            rendersRainbow = true
        }

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.2)) {
                revealProgress = isActive ? 1 : 0
            }
        } else if isActive {
            withAnimation(.linear(duration: revealDuration)) {
                revealProgress = 1
            }
        } else {
            withAnimation(.spring(response: retractResponse, dampingFraction: 1)) {
                revealProgress = 0
            }
        }

        guard !isActive else { return }
        let cleanupDelay = reduceMotion ? 0.25 : retractResponse * 2
        cleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(cleanupDelay))
            guard !Task.isCancelled else { return }
            rendersRainbow = false
        }
    }

    private func setRevealImmediately(isActive: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            revealProgress = isActive ? 1 : 0
            rendersRainbow = isActive
            if isActive {
                phaseOrigin = Date().addingTimeInterval(-revealDuration)
            }
        }
    }
}

public struct FlowingRainbowForeground<Content: View>: View {
    private let axis: FlowingRainbowAxis
    private let duration: TimeInterval
    private let startingColor: Color?
    private let cycleLengthMultiplier: CGFloat
    private let content: Content

    public init(
        axis: FlowingRainbowAxis = .horizontal,
        duration: TimeInterval = 2.8,
        startingColor: Color? = nil,
        cycleLengthMultiplier: CGFloat = 1,
        @ViewBuilder content: () -> Content
    ) {
        self.axis = axis
        self.duration = duration
        self.startingColor = startingColor
        self.cycleLengthMultiplier = cycleLengthMultiplier
        self.content = content()
    }

    public var body: some View {
        content
            .hidden()
            .overlay {
                FlowingRainbowGradient(
                    axis: axis,
                    duration: duration,
                    startingColor: startingColor,
                    cycleLengthMultiplier: cycleLengthMultiplier
                )
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

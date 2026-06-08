// ============================================================================
// WatchChatBubbleVisualSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡使用的闪烁文本与长按入口辅助视图。
// ============================================================================

import SwiftUI

struct ShimmeringText: View {
    let text: String
    let font: Font
    let baseColor: Color
    let highlightColor: Color
    var duration: Double = 1.6
    var angle: Double = 18
    var bandWidthRatio: CGFloat = 0.7
    var bandHeightRatio: CGFloat = 1.6

    var body: some View {
        Text(text)
            .etFont(font)
            .foregroundStyle(baseColor)
            .overlay(
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    let bandWidth = max(1, width * bandWidthRatio)
                    let bandHeight = max(1, height * bandHeightRatio)
                    let startX = -bandWidth
                    let endX = width + bandWidth
                    let safeDuration = max(duration, 0.1)
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: safeDuration) / safeDuration
                        Rectangle()
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
                            .frame(width: bandWidth, height: bandHeight)
                            .rotationEffect(.degrees(angle))
                            .position(
                                x: startX + (endX - startX) * CGFloat(phase),
                                y: height / 2
                            )
                            .blendMode(.screen)
                    }
                }
                .mask(
                    Text(text)
                        .etFont(font)
                )
                .allowsHitTesting(false)
            )
    }
}

struct StreamingMessageSweepModifier: ViewModifier {
    let isActive: Bool
    let highlightColor: Color
    var duration: Double = 1.7
    var bandWidthRatio: CGFloat = 0.32
    var opacity: Double = 0.12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive && !reduceMotion {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let height = proxy.size.height
                        let bandWidth = max(24, width * bandWidthRatio)
                        let bandHeight = max(18, height * 1.2)
                        let startX = -bandWidth
                        let endX = width + bandWidth
                        let safeDuration = max(duration, 0.2)
                        TimelineView(.animation) { timeline in
                            let phase = timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: safeDuration) / safeDuration
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0),
                                            .init(color: highlightColor.opacity(opacity), location: 0.46),
                                            .init(color: highlightColor.opacity(opacity * 0.55), location: 0.6),
                                            .init(color: .clear, location: 1)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: bandWidth, height: bandHeight)
                                .rotationEffect(.degrees(12))
                                .blur(radius: 2)
                                .position(
                                    x: startX + (endX - startX) * CGFloat(phase),
                                    y: height * 0.56
                                )
                                .blendMode(.screen)
                        }
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func streamingMessageSweep(
        isActive: Bool,
        highlightColor: Color,
        duration: Double = 1.7,
        bandWidthRatio: CGFloat = 0.32,
        opacity: Double = 0.12
    ) -> some View {
        modifier(
            StreamingMessageSweepModifier(
                isActive: isActive,
                highlightColor: highlightColor,
                duration: duration,
                bandWidthRatio: bandWidthRatio,
                opacity: opacity
            )
        )
    }
}

struct ChatBubbleOpenMoreGestureModifier: ViewModifier {
    let onOpenMore: (() -> Void)?

    func body(content: Content) -> some View {
        if let onOpenMore {
            content
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.45) {
                    onOpenMore()
                }
        } else {
            content
        }
    }
}

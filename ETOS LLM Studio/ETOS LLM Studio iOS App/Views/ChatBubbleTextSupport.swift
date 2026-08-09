// ============================================================================
// ChatBubbleTextSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的可滚动文本与闪烁文本辅助视图。
// ============================================================================

import ETOSCore
import Foundation
import SwiftUI

struct ShimmeringText: View {
    let text: String
    let font: Font
    let baseColor: Color
    let highlightColor: Color
    var duration: Double = 5

    var body: some View {
        RainbowSweepForeground(baseColor: baseColor, duration: duration) {
            Text(text)
                .etFont(font)
        }
    }
}

struct CappedScrollableText: View {
    let text: String
    let maxHeight: CGFloat
    let font: Font
    let foreground: Color
    let enableSelection: Bool
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            textView
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TextHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: resolvedHeight)
        .onPreferenceChange(TextHeightKey.self) { measuredHeight = $0 }
    }

    private var resolvedHeight: CGFloat {
        guard measuredHeight > 0 else { return maxHeight }
        return min(measuredHeight, maxHeight)
    }

    @ViewBuilder
    private var textView: some View {
        if enableSelection {
            Text(text)
                .etFont(font)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .etFont(font)
                .foregroundStyle(foreground)
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 流式气泡以顶部对齐的完整前景作为内容源，只动画外层可见高度。
/// 底部锚点会随每一帧高度变化上移，因此既能维持输入栏间距，也不会让气泡顶部与文字脱节。
struct ETBottomPinnedStreamingBubble<Foreground: View, Background: View>: View {
    let duration: TimeInterval
    private let foreground: Foreground
    private let background: Background

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleHeight: CGFloat = 0

    init(
        duration: TimeInterval,
        @ViewBuilder foreground: () -> Foreground,
        @ViewBuilder background: () -> Background
    ) {
        self.duration = duration
        self.foreground = foreground()
        self.background = background()
    }

    var body: some View {
        foreground
            // 先测量完整的新内容，再由外层高度从旧值追到新值；避免动画值反过来压缩测量结果。
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                updateVisibleHeight(newHeight)
            }
            .frame(height: visibleHeight > 0 ? visibleHeight : nil, alignment: .top)
            // 新增行暂时留在当前气泡底边之外，随高度增长自然显现。
            .clipped()
            .background {
                background
            }
    }

    private func updateVisibleHeight(_ newHeight: CGFloat) {
        guard newHeight.isFinite,
              newHeight > 0,
              abs(newHeight - visibleHeight) > 0.5 else {
            return
        }

        guard ETStreamingBubbleGrowthPolicy.shouldAnimate(
            from: visibleHeight,
            to: newHeight,
            reduceMotion: reduceMotion
        ) else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                visibleHeight = newHeight
            }
            return
        }

        // 高度必须在下一批 UI 发布前准确落到终点，避免连续流式更新累积出固定的视觉偏差。
        withAnimation(.linear(duration: duration)) {
            visibleHeight = newHeight
        }
    }
}

enum ETStreamingBubbleGrowthPolicy {
    nonisolated static func shouldAnimate(
        from currentHeight: CGFloat,
        to newHeight: CGFloat,
        reduceMotion: Bool
    ) -> Bool {
        !reduceMotion && currentHeight > 0 && newHeight > currentHeight + 0.5
    }
}

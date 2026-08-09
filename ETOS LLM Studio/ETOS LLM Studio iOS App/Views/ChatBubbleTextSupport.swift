// ============================================================================
// ChatBubbleTextSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的可滚动文本与闪烁文本辅助视图。
// ============================================================================

import SwiftUI
import ETOSCore

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

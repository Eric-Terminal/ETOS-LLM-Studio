// ============================================================================
// WatchChatBubbleTextSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡共用的可滚动截断文本组件。
// ============================================================================

import SwiftUI

struct CappedScrollableText: View {
    let text: String
    let maxHeight: CGFloat
    let font: Font
    let foreground: Color
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            Text(text)
                .etFont(font)
                .foregroundColor(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
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
}

private struct TextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

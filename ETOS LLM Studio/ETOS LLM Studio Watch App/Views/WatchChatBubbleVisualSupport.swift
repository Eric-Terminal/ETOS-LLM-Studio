// ============================================================================
// WatchChatBubbleVisualSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡使用的闪烁文本与长按入口辅助视图。
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

struct ChatBubbleOpenMoreGestureModifier: ViewModifier {
    let isSelectionMode: Bool
    let onToggleSelection: () -> Void
    let onOpenMore: (() -> Void)?

    func body(content: Content) -> some View {
        if isSelectionMode {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture()
                        .onEnded { _ in
                            onToggleSelection()
                        }
                )
        } else if let onOpenMore {
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

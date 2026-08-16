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
                // 工具、媒体控件会优先消费触摸；多选时由整行蒙层统一接管。
                .allowsHitTesting(false)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToggleSelection)
                }
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

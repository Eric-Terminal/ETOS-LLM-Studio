// ============================================================================
// ChatBubble+State.swift
// ============================================================================
// iOS 聊天气泡的输入参数、状态、依赖与初始化。
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import AVFoundation
import Combine
import WebKit

// MARK: - Telegram 风格气泡形状

/// Telegram 风格的气泡形状（无尾巴）

struct ChatBubble: View {
    @ObservedObject var messageState: ChatMessageRenderState
    let preparedMarkdownPayload: ETPreparedMarkdownRenderPayload?
    let preparedReasoningMarkdownPayload: ETPreparedMarkdownRenderPayload?
    @Binding var isReasoningExpanded: Bool
    let isReasoningAutoPreview: Bool
    @Binding var isToolCallsExpanded: Bool
    let enableMarkdown: Bool
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let enableNoBubbleUI: Bool
    let enableAdvancedRenderer: Bool
    let enableExperimentalToolResultDisplay: Bool
    let enableMathRendering: Bool
    let showsStreamingIndicators: Bool
    let mergeWithPrevious: Bool
    let mergeWithNext: Bool
    let connectsTimelineFromPrevious: Bool
    let connectsTimelineToNext: Bool
    let responseAttemptVersionInfo: ChatResponseAttemptVersionInfo?
    let hasAutoOpenedPendingToolCall: (String) -> Bool
    let markPendingToolCallAutoOpened: (String) -> Void
    let onSwitchToPreviousVersion: () -> Void
    let onSwitchToNextVersion: () -> Void
    let onOpenMore: (() -> Void)?
    
    @StateObject var audioPlayer = AudioPlayerManager()
    @State var imagePreview: ImagePreviewPayload?
    @State var selectedToolCallDetailSheetItem: ToolCallDetailSheetItem?
    @State var showRawToolResultInDetailSheet: Bool = false
    @ObservedObject var toolPermissionCenter = ToolPermissionCenter.shared
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("enableCustomUserBubbleColor") var enableCustomUserBubbleColor: Bool = false
    @AppStorage("customUserBubbleColorHex") var customUserBubbleColorHex: String = "3D8FF2FF"
    @AppStorage("enableCustomAssistantBubbleColor") var enableCustomAssistantBubbleColor: Bool = false
    @AppStorage("customAssistantBubbleColorHex") var customAssistantBubbleColorHex: String = "F2F2F7FF"
    @AppStorage("enableCustomLightTextColor") var enableCustomLightTextColor: Bool = false
    @AppStorage("customLightTextColorHex") var customLightTextColorHex: String = "1C1C1EFF"
    @AppStorage("enableCustomDarkTextColor") var enableCustomDarkTextColor: Bool = false
    @AppStorage("customDarkTextColorHex") var customDarkTextColorHex: String = "FFFFFFFF"

    init(
        messageState: ChatMessageRenderState,
        preparedMarkdownPayload: ETPreparedMarkdownRenderPayload? = nil,
        preparedReasoningMarkdownPayload: ETPreparedMarkdownRenderPayload? = nil,
        isReasoningExpanded: Binding<Bool>,
        isReasoningAutoPreview: Bool = false,
        isToolCallsExpanded: Binding<Bool>,
        enableMarkdown: Bool,
        enableBackground: Bool,
        enableLiquidGlass: Bool,
        enableNoBubbleUI: Bool,
        enableAdvancedRenderer: Bool = false,
        enableExperimentalToolResultDisplay: Bool = true,
        enableMathRendering: Bool = false,
        showsStreamingIndicators: Bool,
        mergeWithPrevious: Bool,
        mergeWithNext: Bool,
        connectsTimelineFromPrevious: Bool = false,
        connectsTimelineToNext: Bool = false,
        responseAttemptVersionInfo: ChatResponseAttemptVersionInfo? = nil,
        hasAutoOpenedPendingToolCall: @escaping (String) -> Bool = { _ in false },
        markPendingToolCallAutoOpened: @escaping (String) -> Void = { _ in },
        onSwitchToPreviousVersion: @escaping () -> Void,
        onSwitchToNextVersion: @escaping () -> Void,
        onOpenMore: (() -> Void)? = nil
    ) {
        self.messageState = messageState
        self.preparedMarkdownPayload = preparedMarkdownPayload
        self.preparedReasoningMarkdownPayload = preparedReasoningMarkdownPayload
        self._isReasoningExpanded = isReasoningExpanded
        self.isReasoningAutoPreview = isReasoningAutoPreview
        self._isToolCallsExpanded = isToolCallsExpanded
        self.enableMarkdown = enableMarkdown
        self.enableBackground = enableBackground
        self.enableLiquidGlass = enableLiquidGlass
        self.enableNoBubbleUI = enableNoBubbleUI
        self.enableAdvancedRenderer = enableAdvancedRenderer
        self.enableExperimentalToolResultDisplay = enableExperimentalToolResultDisplay
        self.enableMathRendering = enableMathRendering
        self.showsStreamingIndicators = showsStreamingIndicators
        self.mergeWithPrevious = mergeWithPrevious
        self.mergeWithNext = mergeWithNext
        self.connectsTimelineFromPrevious = connectsTimelineFromPrevious
        self.connectsTimelineToNext = connectsTimelineToNext
        self.responseAttemptVersionInfo = responseAttemptVersionInfo
        self.hasAutoOpenedPendingToolCall = hasAutoOpenedPendingToolCall
        self.markPendingToolCallAutoOpened = markPendingToolCallAutoOpened
        self.onSwitchToPreviousVersion = onSwitchToPreviousVersion
        self.onSwitchToNextVersion = onSwitchToNextVersion
        self.onOpenMore = onOpenMore
    }

    // Telegram 颜色
    let telegramBlue = Color(red: 0.24, green: 0.56, blue: 0.95)
    let telegramBlueDark = Color(red: 0.17, green: 0.45, blue: 0.82)
    
    /// 图片占位符文本（各语言版本）
    static let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]"]
}

// ============================================================================
// ChatBubble.swift
// ============================================================================
// ETOS LLM Studio
//
// 本视图作为 watchOS 聊天消息气泡入口，负责组织消息布局、
// 附件入口、工具详情入口与正文渲染流程。
// ============================================================================

import SwiftUI
import WatchKit
import Foundation
import MarkdownUI
import Shared
import AVFoundation
import Combine

/// 聊天消息气泡组件
struct ChatBubble: View {

    // MARK: - 属性与绑定

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
    let hasAutoOpenedPendingToolCall: (String) -> Bool
    let markPendingToolCallAutoOpened: (String) -> Void
    let onCodeBlockHeaderTap: ((String) -> Void)?
    let onOpenMore: (() -> Void)?

    @StateObject var audioPlayer = WatchAudioPlayerManager()
    @State var imagePreview: ImagePreviewPayload?
    @State var toolCallResultExpandedState: [String: Bool] = [:]
    @State var selectedToolCallDetailSheetItem: ToolCallDetailSheetItem?
    @State var showRawToolResultInDetailSheet: Bool = false
    @ObservedObject var toolPermissionCenter = ToolPermissionCenter.shared
    @ObservedObject private var appearanceProfileManager = ChatAppearanceProfileManager.shared
    @Environment(\.displayScale) var displayScale
    @Environment(\.colorScheme) var colorScheme

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
        hasAutoOpenedPendingToolCall: @escaping (String) -> Bool = { _ in false },
        markPendingToolCallAutoOpened: @escaping (String) -> Void = { _ in },
        onCodeBlockHeaderTap: ((String) -> Void)? = nil,
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
        self.hasAutoOpenedPendingToolCall = hasAutoOpenedPendingToolCall
        self.markPendingToolCallAutoOpened = markPendingToolCallAutoOpened
        self.onCodeBlockHeaderTap = onCodeBlockHeaderTap
        self.onOpenMore = onOpenMore
    }

    var message: ChatMessage {
        messageState.visualMessage
    }

    var activeAppearanceProfile: ChatAppearanceProfile {
        appearanceProfileManager.activeProfile
    }

    var resolvedUserBubbleColorOverride: Color? {
        let slot = activeAppearanceProfile.userBubble
        guard slot.isEnabled else { return nil }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: .blue)
    }

    var resolvedAssistantBubbleColorOverride: Color? {
        let fallback = Color(.sRGB, red: 0.949, green: 0.949, blue: 0.969, opacity: 1)
        let slot = activeAppearanceProfile.assistantBubble
        guard slot.isEnabled else { return nil }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: fallback)
    }

    var customTextColorOverride: Color? {
        if colorScheme == .dark {
            let slot = activeAppearanceProfile.darkText
            guard slot.isEnabled else { return nil }
            return ChatAppearanceColorCodec.color(from: slot.hex, fallback: .white)
        }
        let slot = activeAppearanceProfile.lightText
        guard slot.isEnabled else { return nil }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: .primary)
    }

    func resolvedTextColor(default defaultColor: Color) -> Color {
        customTextColorOverride ?? defaultColor
    }

    func resolvedSecondaryTextColor(default defaultColor: Color, customOpacity: Double) -> Color {
        if let customTextColorOverride {
            return customTextColorOverride.opacity(customOpacity)
        }
        return defaultColor
    }

    /// 图片占位符文本（各语言版本）
    static let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]"]

    // MARK: - 视图主体

    var body: some View {
        HStack {
            // 重构: 使用 MessageRole 枚举进行判断
            switch message.role {
            case .user:
                Spacer()
                userBubble
            case .error:
                errorBubble
                Spacer()
            case .assistant, .system, .tool: // system 和 tool 也使用 assistant 样式
                if usesNoBubbleStyle {
                    Spacer(minLength: 0)
                }
                assistantBubble
                if usesNoBubbleStyle {
                    Spacer(minLength: 0)
                } else {
                    Spacer()
                }
            @unknown default:
                // 为未来可能增加的 role 类型提供一个默认的回退，防止编译错误
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, usesNoBubbleStyle ? noBubbleRowHorizontalPadding : nil)
        .padding(.top, mergeWithPrevious ? 0 : rowVerticalPadding)
        .padding(.bottom, mergeWithNext ? 0 : rowVerticalPadding)
        .modifier(ChatBubbleOpenMoreGestureModifier(onOpenMore: onOpenMore))
        .sheet(item: $imagePreview) { payload in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: payload.image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            }
        }
        .sheet(item: $selectedToolCallDetailSheetItem) { item in
            toolCallDetailSheet(for: item)
        }
        .onAppear {
            autoPresentPendingToolCallIfNeeded()
        }
        .onChange(of: toolPermissionCenter.activeRequest?.id) { _, _ in
            autoPresentPendingToolCallIfNeeded()
        }
        .onChange(of: toolCallAutoPresentationSignature) { _, _ in
            autoPresentPendingToolCallIfNeeded()
        }
    }

    // MARK: - 气泡视图

    @ViewBuilder
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
                imageAttachmentsView(fileNames: imageFileNames, isOutgoing: true)
            }

            if shouldShowUserBubble {
                userTextBubble
            }
        }
    }

    @ViewBuilder
    private var errorBubble: some View {
        let content = Text(message.content)
            .padding(10)
            .foregroundColor(usesNoBubbleStyle ? .red : .white)

        if usesNoBubbleStyle {
            content
        } else if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                    .background(Color.red.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                errorBubbleFallback(content)
            }
        } else {
            errorBubbleFallback(content)
        }
    }

    @ViewBuilder
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !shouldPlaceAssistantImagesAfterText,
               let imageFileNames = message.imageFileNames,
               !imageFileNames.isEmpty {
                imageAttachmentsView(fileNames: imageFileNames, isOutgoing: false)
            }

            if shouldShowAssistantBubble {
                if shouldRenderToolCallsAsSeparateBubbles {
                    separatedAssistantBubbles
                } else {
                    assistantTextBubble
                }
            }

            if shouldPlaceAssistantImagesAfterText,
               let imageFileNames = message.imageFileNames,
               !imageFileNames.isEmpty {
                imageAttachmentsView(fileNames: imageFileNames, isOutgoing: false)
            }
        }
        .frame(width: usesNoBubbleStyle ? bubbleMaxWidth : nil, alignment: .leading)
        .frame(maxWidth: usesNoBubbleStyle ? nil : bubbleMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private var userTextBubble: some View {
        let userTextColor: Color = usesNoBubbleStyle
            ? resolvedTextColor(default: .primary)
            : resolvedTextColor(default: .white)
        let content = Group {
            if let audioFileName = message.audioFileName {
                audioPlayerView(fileName: audioFileName, isUser: true)
            } else if hasNonPlaceholderText {
                renderContent(message.content)
            }
        }
        .padding(10)
        .foregroundColor(userTextColor)

        if usesNoBubbleStyle {
            content
        } else if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                content
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12))
                    .background((resolvedUserBubbleColorOverride ?? .blue).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                userBubbleFallback(content)
            }
        } else {
            userBubbleFallback(content)
        }
    }

    @ViewBuilder
    private var separatedAssistantBubbles: some View {
        let hasReasoning = message.reasoningContent != nil && !((message.reasoningContent ?? "").isEmpty)
        let isErrorVersion = message.content.hasPrefix("重试失败")
        let toolCalls = message.toolCalls ?? []
        let hasMainBubble = hasMainContentWhenToolCallsSeparated
        let totalBubbleCount = toolCalls.count + (hasMainBubble ? 1 : 0)

        VStack(alignment: .leading, spacing: 0) {
            if hasMainBubble {
                let content = VStack(alignment: .leading, spacing: 8) {
                    if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                        reasoningView(reasoning)
                    }

                    if hasReasoning && hasNonPlaceholderText {
                        Divider().background(Color.gray)
                    }

                    if message.role != .tool && hasNonPlaceholderText {
                        renderContent(message.content)
                            .foregroundColor(
                                isErrorVersion
                                    ? resolvedTextColor(default: usesNoBubbleStyle ? .red : .white)
                                    : resolvedTextColor(default: message.role == .user ? .white : .primary)
                            )
                    }
                }
                .padding(assistantContentInsets)

                connectedToolBubbleContainer(
                    isFirst: true,
                    isLast: totalBubbleCount == 1,
                    isError: isErrorVersion
                ) {
                    content
                }
                .contentShape(Rectangle())
            }

            ForEach(Array(toolCalls.enumerated()), id: \.element.id) { offset, call in
                let position = (hasMainBubble ? 1 : 0) + offset
                let isFirst = position == 0
                let isLast = position == (totalBubbleCount - 1)

                let content = toolCallBubbleContent(for: call)
                    .padding(assistantContentInsets)

                connectedToolBubbleContainer(isFirst: isFirst, isLast: isLast, isError: false) {
                    content
                }
                .contentShape(Rectangle())
            }
        }
    }

    @ViewBuilder
    private var assistantTextBubble: some View {
        if message.role == .tool {
            let content = VStack(alignment: .leading, spacing: 6) {
                if shouldRenderReasoningToolTimeline,
                   let toolCalls = message.toolCalls,
                   !toolCalls.isEmpty {
                    reasoningToolTimeline(reasoning: nil, toolCalls: toolCalls)
                } else if let standaloneShowWidgetPayload {
                    widgetInlineSummaryView(payload: standaloneShowWidgetPayload)
                } else if hasNonPlaceholderText {
                    renderContent(message.content)
                }
            }
            .padding(assistantContentInsets)

            assistantBubbleContainer(content, isError: false)
            .contentShape(Rectangle())
        } else {
            let hasReasoning = message.reasoningContent != nil && !message.reasoningContent!.isEmpty
            let isErrorVersion = message.content.hasPrefix("重试失败")
            let toolCalls = message.toolCalls ?? []
            let reasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
            let canUseTimeline = shouldRenderReasoningToolTimeline

            let content = VStack(alignment: .leading, spacing: 8) {
                if canUseTimeline {
                    if let reasoning, !reasoning.isEmpty {
                        reasoningToolTimeline(
                            reasoning: reasoning,
                            toolCalls: shouldShowToolCallsBeforeContent ? toolCalls : []
                        )
                    } else if shouldShowToolCallsBeforeContent {
                        reasoningToolTimeline(reasoning: nil, toolCalls: toolCalls)
                    }
                } else {
                    if let reasoning, !reasoning.isEmpty {
                        reasoningView(reasoning)
                    }

                    if shouldShowToolCallsBeforeContent {
                        toolCallsSection
                    }
                }

                if hasReasoning && hasNonPlaceholderText {
                    Divider().background(Color.gray)
                }

                if hasNonPlaceholderText {
                    renderContent(message.content)
                        .foregroundColor(
                            isErrorVersion
                                ? resolvedTextColor(default: usesNoBubbleStyle ? .red : .white)
                                : resolvedTextColor(default: message.role == .user ? .white : .primary)
                        )
                }

                if canUseTimeline {
                    if shouldShowToolCallsAfterContent {
                        reasoningToolTimeline(reasoning: nil, toolCalls: toolCalls)
                    }
                } else if shouldShowToolCallsAfterContent {
                    toolCallsSection
                }

                if shouldShowThinkingIndicator {
                    if showsStreamingIndicators {
                        ShimmeringText(
                            text: currentThinkingText,
                            font: .caption,
                            baseColor: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.75),
                            highlightColor: resolvedTextColor(default: .primary.opacity(0.85))
                        )
                    } else {
                        Text(currentThinkingText)
                            .etFont(.caption)
                            .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.75))
                    }
                }
            }
            .padding(assistantContentInsets)

            assistantBubbleContainer(content, isError: isErrorVersion)
            .contentShape(Rectangle())
        }
    }
}

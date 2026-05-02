// ============================================================================
// ChatBubble.swift
// ============================================================================
// ETOS LLM Studio Watch App 聊天气泡视图 (已重构)
//
// 功能特性:
// - 根据角色（用户/AI/错误）显示不同样式的气泡
// - 支持 Markdown 渲染
// - 思考过程的展开/折叠状态由外部传入的绑定控制
// - 支持语音消息播放
// ============================================================================

import SwiftUI
import WatchKit
import Foundation
import MarkdownUI
import Shared
import AVFoundation
import Combine

extension ChatBubble {
    
    var message: ChatMessage {
        messageState.message
    }

    var resolvedUserBubbleColorOverride: Color? {
        guard enableCustomUserBubbleColor else { return nil }
        return ChatAppearanceColorCodec.color(from: customUserBubbleColorHex, fallback: .blue)
    }

    var resolvedAssistantBubbleColorOverride: Color? {
        let fallback = Color(.sRGB, red: 0.949, green: 0.949, blue: 0.969, opacity: 1)
        guard enableCustomAssistantBubbleColor else { return nil }
        return ChatAppearanceColorCodec.color(from: customAssistantBubbleColorHex, fallback: fallback)
    }

    var customTextColorOverride: Color? {
        if colorScheme == .dark {
            guard enableCustomDarkTextColor else { return nil }
            return ChatAppearanceColorCodec.color(from: customDarkTextColorHex, fallback: .white)
        }
        guard enableCustomLightTextColor else { return nil }
        return ChatAppearanceColorCodec.color(from: customLightTextColorHex, fallback: .primary)
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

    var hasNonPlaceholderText: Bool {
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }
        return !Self.imagePlaceholders.contains(trimmedContent)
    }
    
    var hasToolCalls: Bool {
        !(message.toolCalls ?? []).isEmpty
    }
    
    var hasToolResults: Bool {
        let hasWidgetPayload = message.toolCalls?.contains { call in
            ToolWidgetPayloadParser.parse(from: call.arguments) != nil
        } ?? false
        let hasCallResults = message.toolCalls?.contains { call in
            !(call.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        if message.role == .tool {
            let hasContent = !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasCallResults || hasContent || hasWidgetPayload
        }
        return hasCallResults || hasWidgetPayload
    }

    func isShowWidgetToolCall(_ call: InternalToolCall) -> Bool {
        call.toolName == AppToolKind.showWidget.toolName
    }

    func showWidgetPayload(for call: InternalToolCall) -> ToolWidgetPayload? {
        guard isShowWidgetToolCall(call) else { return nil }

        if let payload = ToolWidgetPayloadParser.parse(from: call.arguments) {
            return payload
        }

        let resolved = resolvedToolResultText(for: call)
        if let payload = ToolWidgetPayloadParser.parse(from: resolved) {
            return payload
        }

        if message.role == .tool,
           let payload = ToolWidgetPayloadParser.parse(from: message.content) {
            return payload
        }

        return nil
    }

    var standaloneShowWidgetPayload: ToolWidgetPayload? {
        guard message.role == .tool,
              (message.toolCalls?.isEmpty ?? true) else {
            return nil
        }
        return ToolWidgetPayloadParser.parse(from: message.content)
    }

    var hasPendingToolResults: Bool {
        guard message.role != .tool else { return false }
        guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return false }
        guard !hasToolResults else { return false }
        return activeToolPermissionRequest == nil
    }

    var shouldShimmerReasoningHeader: Bool {
        showsStreamingIndicators
            && message.role == .assistant
            && reasoningCompletedAt == nil
    }

    var reasoningStartedAt: Date? {
        if let reasoningStartedAt = message.responseMetrics?.reasoningStartedAt {
            return reasoningStartedAt
        }
        if showsStreamingIndicators {
            return message.responseMetrics?.requestStartedAt ?? message.requestedAt
        }
        return nil
    }

    var reasoningCompletedAt: Date? {
        message.responseMetrics?.reasoningCompletedAt ?? message.responseMetrics?.responseCompletedAt
    }

    var fallbackReasoningDuration: TimeInterval? {
        guard !showsStreamingIndicators,
              message.responseMetrics?.reasoningStartedAt == nil,
              message.responseMetrics?.reasoningCompletedAt == nil else {
            return nil
        }
        return message.responseMetrics?.totalResponseDuration
    }

    var isReasoningFinishedForTimeline: Bool {
        reasoningCompletedAt != nil || !showsStreamingIndicators
    }

    var reasoningSummaryText: String? {
        let trimmed = message.responseMetrics?.reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    var resolvedToolCallsPlacement: ToolCallsPlacement {
        if let placement = message.toolCallsPlacement {
            return placement
        }
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedContent.isEmpty ? .afterReasoning : .afterContent
    }

    var shouldShowToolCallsBeforeContent: Bool {
        hasToolCalls && resolvedToolCallsPlacement == .afterReasoning
    }

    var shouldShowToolCallsAfterContent: Bool {
        hasToolCalls && resolvedToolCallsPlacement == .afterContent
    }

    var shouldRenderToolCallsAsSeparateBubbles: Bool {
        // 工具调用已并入同一个助手气泡的时间线，保留旧分支以降低本次改动范围。
        false
    }

    var shouldRenderReasoningToolTimeline: Bool {
        message.role != .user
            && message.role != .error
            && (hasToolCalls || !(message.reasoningContent ?? "").isEmpty)
    }

    var usesNoBubbleStyle: Bool {
        enableNoBubbleUI && message.role != .user && message.role != .error
    }

    var hasMainContentWhenToolCallsSeparated: Bool {
        let hasReasoning = message.reasoningContent != nil && !(message.reasoningContent ?? "").isEmpty
        let hasVisibleContent = hasNonPlaceholderText && message.role != .tool
        return hasReasoning || hasVisibleContent
    }

    var assistantBubbleShape: BubbleCornerShape {
        let baseRadius: CGFloat = 12
        let mergedRadius: CGFloat = 0
        let topRadius = mergeWithPrevious ? mergedRadius : baseRadius
        let bottomRadius = mergeWithNext ? mergedRadius : baseRadius
        return BubbleCornerShape(
            topLeft: topRadius,
            topRight: topRadius,
            bottomLeft: bottomRadius,
            bottomRight: bottomRadius
        )
    }

    func connectedAssistantBubbleShape(isFirst: Bool, isLast: Bool) -> BubbleCornerShape {
        let baseRadius: CGFloat = 12
        let mergedRadius: CGFloat = 0
        let topRadius = isFirst ? (mergeWithPrevious ? mergedRadius : baseRadius) : mergedRadius
        let bottomRadius = isLast ? (mergeWithNext ? mergedRadius : baseRadius) : mergedRadius
        return BubbleCornerShape(
            topLeft: topRadius,
            topRight: topRadius,
            bottomLeft: bottomRadius,
            bottomRight: bottomRadius
        )
    }

    var shouldShowMergedSeparator: Bool {
        !usesNoBubbleStyle && mergeWithPrevious && message.role != .user && message.role != .error
    }

    var separatorThickness: CGFloat {
        1 / displayScale
    }

    var separatorColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    var separatorLine: some View {
        Rectangle()
            .fill(separatorColor)
            .frame(height: separatorThickness)
    }

    var noBubbleRowHorizontalPadding: CGFloat {
        2
    }

    var rowSpacerReserveWidth: CGFloat {
        16
    }

    var bubbleMaxWidth: CGFloat {
        let rowWidth = max(WKInterfaceDevice.current().screenBounds.width, 1)
        if usesNoBubbleStyle {
            let availableBubbleWidth = max(1, rowWidth - noBubbleRowHorizontalPadding * 2)
            return min(max(rowWidth * 0.92, 1), availableBubbleWidth)
        }
        let availableBubbleWidth = max(1, rowWidth - rowSpacerReserveWidth)
        let widthRatio: CGFloat = (message.role == .user || message.role == .error) ? 0.86 : 0.92
        return min(rowWidth * widthRatio, availableBubbleWidth)
    }

    var shouldForceMergedWidth: Bool {
        if usesNoBubbleStyle {
            return true
        }
        return message.role != .user
            && message.role != .error
            && (mergeWithPrevious || mergeWithNext || shouldRenderReasoningToolTimeline)
    }

    var rowVerticalPadding: CGFloat {
        4
    }

    var assistantContentInsets: EdgeInsets {
        if usesNoBubbleStyle {
            return EdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
        }
        return EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
    }
    
    var activeToolPermissionRequest: ToolPermissionRequest? {
        guard let toolCalls = message.toolCalls else { return nil }
        return toolCalls.compactMap(activeToolPermissionRequest(for:)).first
    }

    var pendingToolCallForAutoPresentation: InternalToolCall? {
        guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return nil }
        return toolCalls.first { call in
            activeToolPermissionRequest(for: call) != nil && !hasAutoOpenedPendingToolCall(call.id)
        }
    }


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

    struct ToolCallDetailSheetItem: Identifiable, Equatable {
        let messageID: UUID
        let toolCallID: String
        let fallbackToolCall: InternalToolCall

        var id: String {
            "\(messageID.uuidString)-\(toolCallID)"
        }
    }

    enum ToolCallBubbleStatus: Equatable {
        case pendingApproval
        case running
        case finished
        case rejected

        var title: String {
            switch self {
            case .pendingApproval:
                return NSLocalizedString("等待审批", comment: "")
            case .running:
                return NSLocalizedString("执行中", comment: "")
            case .finished:
                return NSLocalizedString("已完成", comment: "")
            case .rejected:
                return NSLocalizedString("已拒绝", comment: "")
            }
        }

        var iconName: String {
            switch self {
            case .pendingApproval:
                return "hourglass"
            case .running:
                return "clock.arrow.trianglehead.counterclockwise.rotate.90"
            case .finished:
                return "checkmark.circle.fill"
            case .rejected:
                return "xmark.circle.fill"
            }
        }

        var accentColor: Color {
            switch self {
            case .pendingApproval:
                return .orange
            case .running:
                return .blue
            case .finished:
                return .green
            case .rejected:
                return .red
            }
        }
    }
    
    // MARK: - 气泡视图
    
    @ViewBuilder
    var userBubble: some View {
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
    var errorBubble: some View {
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
    var assistantBubble: some View {
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
    var userTextBubble: some View {
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
    var separatedAssistantBubbles: some View {
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
    var assistantTextBubble: some View {
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

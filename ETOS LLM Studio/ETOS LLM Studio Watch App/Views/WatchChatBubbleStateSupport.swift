// ============================================================================
// WatchChatBubbleStateSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡的状态判断与工具调用辅助逻辑。
// ============================================================================

import SwiftUI
import Shared

extension ChatBubble {
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

    var shouldShowThinkingIndicator: Bool {
        message.role == .assistant
            && message.content.isEmpty
            && (message.reasoningContent ?? "").isEmpty
            && (message.toolCalls ?? []).isEmpty
    }

    var currentThinkingText: String {
        guard shouldShowThinkingIndicator else { return "" }
        return NSLocalizedString("正在思考...", comment: "")
    }
}

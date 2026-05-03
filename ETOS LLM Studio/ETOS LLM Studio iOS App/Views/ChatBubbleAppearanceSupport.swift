// ============================================================================
// ChatBubbleAppearanceSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 ChatBubble 的外观、布局与状态判断辅助逻辑。
// ============================================================================

import Foundation
import SwiftUI
import UIKit
import Shared

extension ChatBubble {
    var telegramBlue: Color {
        Color(red: 0.24, green: 0.56, blue: 0.95)
    }

    var telegramBlueDark: Color {
        Color(red: 0.17, green: 0.45, blue: 0.82)
    }

    var activeAppearanceProfile: ChatAppearanceProfile {
        appearanceProfileManager.activeProfile
    }

    var resolvedUserBubbleStartColor: Color {
        let slot = activeAppearanceProfile.userBubble
        guard slot.isEnabled else { return telegramBlue }
        return ChatAppearanceColorCodec.color(from: slot.hex, fallback: telegramBlue)
    }

    var resolvedUserBubbleEndColor: Color {
        guard activeAppearanceProfile.userBubble.isEnabled else { return telegramBlueDark }
        return ChatAppearanceColorCodec.darkened(resolvedUserBubbleStartColor, factor: 0.86)
    }

    var resolvedAssistantBubbleColor: Color? {
        let slot = activeAppearanceProfile.assistantBubble
        guard slot.isEnabled else { return nil }
        return ChatAppearanceColorCodec.color(
            from: slot.hex,
            fallback: Color(uiColor: .secondarySystemBackground)
        )
    }

    var versionSwitcherBackgroundColor: Color {
        if isOutgoing, responseAttemptVersionInfo == nil {
            return resolvedUserBubbleEndColor.opacity(colorScheme == .dark ? 0.28 : 0.18)
        }
        if let resolvedAssistantBubbleColor {
            return resolvedAssistantBubbleColor.opacity(enableBackground ? 0.75 : 1)
        }
        return enableBackground
            ? Color(uiColor: .secondarySystemBackground).opacity(0.75)
            : Color(uiColor: .systemBackground)
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

    var isOutgoing: Bool {
        message.role == .user
    }

    var isError: Bool {
        message.role == .error || (message.role == .assistant && message.content.hasPrefix("重试失败"))
    }

    var usesNoBubbleStyle: Bool {
        enableNoBubbleUI && !isOutgoing && !isError
    }

    var bubbleShape: BubbleCornerShape {
        let baseRadius: CGFloat = 18
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

    var shouldShowMergedSeparator: Bool {
        !usesNoBubbleStyle && mergeWithPrevious && !isOutgoing
    }

    var separatorThickness: CGFloat {
        1 / UIScreen.main.scale
    }

    var separatorColor: Color {
        if isOutgoing {
            return Color.white.opacity(0.2)
        }
        return colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    var bubbleShadow: (color: Color, radius: CGFloat, y: CGFloat) {
        if usesNoBubbleStyle {
            return (Color.clear, 0, 0)
        }
        if mergeWithPrevious && mergeWithNext {
            return (Color.black.opacity(0.04), 1, 0)
        }
        return (Color.black.opacity(0.08), 3, 1)
    }

    var bubbleMaxWidth: CGFloat {
        let baseWidth = max(UIScreen.main.bounds.width, 1)
        let rowChromeWidth = rowHorizontalPadding * 2 + (usesNoBubbleStyle ? 0 : rowSideSpacerMinLength)
        let availableBubbleWidth = max(1, baseWidth - rowChromeWidth)
        let widthRatio: CGFloat
        if usesNoBubbleStyle {
            widthRatio = 0.92
        } else if isOutgoing {
            widthRatio = 0.88
        } else {
            widthRatio = 0.94
        }
        return min(baseWidth * widthRatio, availableBubbleWidth)
    }

    var shouldForceMergedWidth: Bool {
        if usesNoBubbleStyle {
            return true
        }
        return !isOutgoing && (mergeWithPrevious || mergeWithNext || shouldRenderReasoningToolTimeline)
    }

    var rowSideSpacerMinLength: CGFloat {
        usesNoBubbleStyle ? 0 : 20
    }

    var rowHorizontalPadding: CGFloat {
        8
    }

    var rowVerticalPadding: CGFloat {
        let basePadding: CGFloat = 3
        return enableNoBubbleUI ? basePadding * 3 : basePadding
    }

    var bubbleContentVerticalPadding: CGFloat {
        usesNoBubbleStyle ? 4 : 8
    }

    var textForegroundColor: Color {
        if isError && usesNoBubbleStyle {
            return .red
        }
        if usesNoBubbleStyle {
            return resolvedTextColor(default: .primary)
        }
        return resolvedTextColor(default: isOutgoing ? .white : .primary)
    }

    func resolvedTextColor(default defaultColor: Color) -> Color {
        customTextColorOverride ?? defaultColor
    }

    func resolvedSecondaryTextColor(default defaultColor: Color, customOpacity: Double = 0.78) -> Color {
        if let customTextColorOverride {
            return customTextColorOverride.opacity(customOpacity)
        }
        return defaultColor
    }

    static let imagePlaceholders: Set<String> = ["[图片]", "[圖片]", "[Image]", "[画像]"]

    var hasOnlyImages: Bool {
        guard let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty else {
            return false
        }
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholderOnly = trimmedContent.isEmpty || Self.imagePlaceholders.contains(trimmedContent)
        return isPlaceholderOnly && message.reasoningContent == nil && message.toolCalls == nil && message.audioFileName == nil
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
        !isOutgoing
            && !isError
            && (hasToolCalls || !(message.reasoningContent ?? "").isEmpty)
    }

    var hasMainContentWhenToolCallsSeparated: Bool {
        if hasOnlyImages {
            return false
        }
        let hasReasoning = !(message.reasoningContent ?? "").isEmpty
        let hasVisibleContent = !message.content.isEmpty && message.role != .tool
        return hasReasoning || hasVisibleContent
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

    var shouldShowTextBubble: Bool {
        if hasOnlyImages {
            return false
        }
        let hasReasoning = !(message.reasoningContent ?? "").isEmpty
        let hasContent = !message.content.isEmpty
        let shouldShowThinking = message.role == .assistant
            && !hasContent
            && !hasReasoning
            && !hasToolCalls

        switch message.role {
        case .tool:
            return hasToolCalls || hasContent
        case .assistant, .system:
            return hasToolCalls || hasReasoning || hasContent || shouldShowThinking
        case .user, .error:
            return hasContent || hasReasoning || hasToolCalls
        @unknown default:
            return hasReasoning || hasContent
        }
    }

    var shouldPlaceImagesAfterText: Bool {
        !isOutgoing && shouldShowTextBubble
    }
}

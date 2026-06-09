// ============================================================================
// WatchChatBubbleStateSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡的状态判断与工具调用辅助逻辑。
// ============================================================================

import SwiftUI
import ETOSCore

extension ChatBubble {
    var messageActionBarConfiguration: MessageActionBarConfiguration {
        appConfig.messageActionBarSettings
    }

    var messageActionBarRole: MessageActionBarRole {
        message.role == .user ? .user : .assistant
    }

    var configuredMessageActionBarItems: [MessageActionBarItem] {
        messageActionBarConfiguration.items(for: messageActionBarRole).filter { isMessageActionBarItemAvailable($0) }
    }

    var displayedMessageActionBarItems: [MessageActionBarItem] {
        switch messageActionBarConfiguration.alignment(for: messageActionBarRole) {
        case .leading:
            return configuredMessageActionBarItems
        case .trailing:
            return Array(configuredMessageActionBarItems.reversed())
        }
    }

    var messageActionBarAlignment: Alignment {
        switch messageActionBarConfiguration.alignment(for: messageActionBarRole) {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    @ViewBuilder
    var messageActionBarRow: some View {
        ViewThatFits(in: .horizontal) {
            messageActionBarContent
                .watchMessageActionBarGroupStyle(
                    showsBorder: showsMessageActionBarOuterBorder,
                    background: {
                        messageActionBarBackground()
                    }
                )

            ScrollView(.horizontal, showsIndicators: false) {
                messageActionBarContent
            }
            .watchMessageActionBarGroupStyle(
                showsBorder: showsMessageActionBarOuterBorder,
                background: {
                    messageActionBarBackground()
                }
            )
        }
        .frame(width: bubbleMaxWidth, alignment: messageActionBarAlignment)
        .padding(.top, 2)
    }

    @ViewBuilder
    var messageActionBarContent: some View {
        HStack(spacing: 5) {
            ForEach(displayedMessageActionBarItems) { item in
                messageActionBarItemView(item)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    func messageActionBarBackground() -> some View {
        if showsMessageActionBarOuterBorder {
            let shape = Capsule()

            if message.role == .user {
                if enableLiquidGlass {
                    if #available(watchOS 26.0, *) {
                        shape
                            .fill(userLiquidGlassBackground)
                            .glassEffect(.clear, in: shape)
                            .clipShape(shape)
                    } else {
                        shape.fill(userFallbackBackground)
                    }
                } else {
                    shape.fill(userFallbackBackground)
                }
            } else if message.role == .error {
                if enableLiquidGlass {
                    if #available(watchOS 26.0, *) {
                        shape
                            .fill(errorLiquidGlassBackground)
                            .glassEffect(.clear, in: shape)
                            .clipShape(shape)
                    } else {
                        shape.fill(enableBackground ? Color.red.opacity(0.7) : Color.red)
                    }
                } else {
                    shape.fill(enableBackground ? Color.red.opacity(0.7) : Color.red)
                }
            } else if enableLiquidGlass {
                if #available(watchOS 26.0, *) {
                    shape
                        .fill(assistantLiquidGlassBackground)
                        .glassEffect(.clear, in: shape)
                        .clipShape(shape)
                } else {
                    shape.fill(assistantFallbackBackground)
                }
            } else {
                shape.fill(assistantFallbackBackground)
            }
        }
    }

    var showsMessageActionBarOuterBorder: Bool {
        messageActionBarConfiguration.showsOuterBorder && !usesNoBubbleStyle
    }

    var messageActionBarForegroundColor: Color {
        if showsMessageActionBarOuterBorder {
            switch message.role {
            case .user, .error:
                return resolvedTextColor(default: .white)
            case .assistant, .system, .tool:
                return resolvedTextColor(default: .primary)
            @unknown default:
                return resolvedTextColor(default: .primary)
            }
        }
        return resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.86)
    }

    @ViewBuilder
    func messageActionBarItemView(_ item: MessageActionBarItem) -> some View {
        switch item {
        case .quickRetry:
            Button(action: onRetry) {
                Image(systemName: item.systemImage)
                    .etFont(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.title))
            .watchMessageActionBarItemStyle(foreground: messageActionBarForegroundColor)
        case .copyMessage:
            Button(action: onCopy) {
                Image(systemName: item.systemImage)
                    .etFont(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.title))
            .watchMessageActionBarItemStyle(foreground: messageActionBarForegroundColor)
        case .requestTime:
            Label(messageRequestTimeText, systemImage: item.systemImage)
                .etFont(.system(size: 10, weight: .semibold))
                .watchMessageActionBarItemStyle(foreground: messageActionBarForegroundColor)
        case .inputTokens:
            Label("\(inputTokenCount)", systemImage: item.systemImage)
                .etFont(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .watchMessageActionBarItemStyle(foreground: messageActionBarForegroundColor)
        case .outputTokens:
            Label("\(outputTokenCount)", systemImage: item.systemImage)
                .etFont(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .watchMessageActionBarItemStyle(foreground: messageActionBarForegroundColor)
        case .costEstimate:
            if let estimate = resolvedCostEstimate {
                Label(MessageCostFormatter.formatCompact(estimate), systemImage: item.systemImage)
                    .etFont(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .watchMessageActionBarItemStyle(foreground: messageActionBarForegroundColor)
            }
        case .versionSwitcher:
            compactVersionIndicator
        }
    }

    @ViewBuilder
    var compactVersionIndicator: some View {
        let currentIndex = responseAttemptVersionInfo?.currentIndex ?? message.getCurrentVersionIndex()
        let totalCount = responseAttemptVersionInfo?.totalCount ?? message.getAllVersions().count
        HStack(spacing: 4) {
            Button {
                onSwitchToPreviousVersion()
            } label: {
                Image(systemName: "chevron.left")
                    .etFont(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == 0)
            .opacity(currentIndex > 0 ? 1 : 0.4)

            Text("\(currentIndex + 1)/\(totalCount)")
                .etFont(.system(size: 10, weight: .semibold))
                .monospacedDigit()

            Button {
                onSwitchToNextVersion()
            } label: {
                Image(systemName: "chevron.right")
                    .etFont(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= totalCount - 1)
            .opacity(currentIndex < totalCount - 1 ? 1 : 0.4)
        }
        .watchMessageActionBarItemStyle(foreground: messageActionBarForegroundColor)
    }

    var shouldShowVersionIndicator: Bool {
        responseAttemptVersionInfo != nil || message.hasMultipleVersions
    }

    var shouldShowMessageActionBar: Bool {
        !messageActionBarContinuesToNext && !configuredMessageActionBarItems.isEmpty
    }

    func isMessageActionBarItemAvailable(_ item: MessageActionBarItem) -> Bool {
        switch item {
        case .quickRetry:
            return canRetry
        case .copyMessage:
            return !message.content.isEmpty
        case .requestTime:
            return messageRequestDate != nil
        case .inputTokens:
            return message.tokenUsage?.promptTokens != nil
        case .outputTokens:
            return message.tokenUsage?.completionTokens != nil
        case .costEstimate:
            return resolvedCostEstimate != nil
        case .versionSwitcher:
            return shouldShowVersionIndicator
        }
    }

    var messageRequestDate: Date? {
        message.responseMetrics?.requestStartedAt ?? message.requestedAt
    }

    var messageRequestTimeText: String {
        guard let messageRequestDate else { return "" }
        return messageRequestDate.formatted(date: .omitted, time: .shortened)
    }

    var inputTokenCount: Int {
        message.tokenUsage?.promptTokens ?? 0
    }

    var outputTokenCount: Int {
        message.tokenUsage?.completionTokens ?? 0
    }

    var resolvedCostEstimate: MessageCostEstimate? {
        MessageCostResolver.resolvedCost(for: message, providers: providers)
    }

    var hasNonPlaceholderText: Bool {
        let trimmedContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }
        return !Self.imagePlaceholders.contains(trimmedContent)
            && !Self.filePlaceholders.contains(trimmedContent)
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

private struct WatchMessageActionBarItemStyle: ViewModifier {
    let foreground: Color

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foreground)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule())
    }
}

private struct WatchMessageActionBarGroupStyle: ViewModifier {
    let showsBorder: Bool
    let background: AnyView
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(background)
            .overlay(
                Capsule()
                    .strokeBorder(
                        Color.primary.opacity(showsBorder ? (colorScheme == .dark ? 0.14 : 0.1) : 0),
                        lineWidth: showsBorder ? 0.5 : 0
                    )
            )
            .contentShape(Capsule())
    }
}

private extension View {
    func watchMessageActionBarItemStyle(foreground: Color) -> some View {
        modifier(WatchMessageActionBarItemStyle(foreground: foreground))
    }

    func watchMessageActionBarGroupStyle<Background: View>(
        showsBorder: Bool,
        @ViewBuilder background: () -> Background
    ) -> some View {
        modifier(WatchMessageActionBarGroupStyle(showsBorder: showsBorder, background: AnyView(background())))
    }
}

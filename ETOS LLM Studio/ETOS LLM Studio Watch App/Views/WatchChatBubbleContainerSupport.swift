// ============================================================================
// WatchChatBubbleContainerSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡的外壳、回退样式与时间线承载容器。
// ============================================================================

import ETOSCore
import SwiftUI

extension ChatBubble {
    @ViewBuilder
    func userBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(userFallbackBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var userFallbackBackground: Color {
        if let resolvedUserBubbleColorOverride {
            return enableBackground ? resolvedUserBubbleColorOverride.opacity(0.7) : resolvedUserBubbleColorOverride
        }
        return enableBackground ? Color.blue.opacity(0.7) : Color.blue
    }

    var userLiquidGlassBackground: Color {
        (resolvedUserBubbleColorOverride ?? .blue).opacity(0.5)
    }

    var errorLiquidGlassBackground: Color {
        Color.red.opacity(0.5)
    }

    @ViewBuilder
    func errorBubbleFallback<Content: View>(_ content: Content) -> some View {
        content
            .background(enableBackground ? Color.red.opacity(0.7) : Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    func assistantBubbleFallback<Content: View>(
        _ content: Content,
        isError: Bool = false,
        shape: BubbleCornerShape
    ) -> some View {
        content
            .background(
                isError
                    ? Color.red.opacity(0.7)
                    : assistantFallbackBackground
            )
            .clipShape(shape)
    }

    var assistantFallbackBackground: Color {
        if let resolvedAssistantBubbleColorOverride {
            return enableBackground ? resolvedAssistantBubbleColorOverride.opacity(0.7) : resolvedAssistantBubbleColorOverride
        }
        return enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)
    }

    var assistantLiquidGlassBackground: Color {
        resolvedAssistantBubbleColorOverride.map { enableBackground ? $0.opacity(0.5) : $0 } ?? Color.clear
    }

    var standaloneAssistantBubbleShape: BubbleCornerShape {
        BubbleCornerShape(
            topLeft: 12,
            topRight: 12,
            bottomLeft: 12,
            bottomRight: 12
        )
    }

    @ViewBuilder
    func connectedToolBubbleContainer<Content: View>(
        isFirst: Bool,
        isLast: Bool,
        isError: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        assistantBubbleContainer(
            content(),
            isError: isError,
            shapeOverride: connectedAssistantBubbleShape(isFirst: isFirst, isLast: isLast),
            showMergedSeparator: isFirst && shouldShowMergedSeparator
        )
    }

    @ViewBuilder
    func assistantBubbleContainer<Content: View>(
        _ content: Content,
        isError: Bool,
        standalone: Bool = false,
        shapeOverride: BubbleCornerShape? = nil,
        showMergedSeparator: Bool? = nil
    ) -> some View {
        let shape = shapeOverride ?? (standalone ? standaloneAssistantBubbleShape : assistantBubbleShape)
        let shouldShowSeparator = showMergedSeparator ?? (!standalone && shouldShowMergedSeparator)
        let sizedContent = content
            .frame(
                minWidth: shouldForceMergedWidth ? bubbleMaxWidth : nil,
                maxWidth: bubbleMaxWidth,
                alignment: .leading
            )

        if usesNoBubbleStyle {
            sizedContent
        } else {
            Group {
                if enableLiquidGlass {
                    if #available(watchOS 26.0, *) {
                        sizedContent
                            .glassEffect(.clear, in: shape)
                            .background(
                                isError
                                    ? errorLiquidGlassBackground
                                    : assistantLiquidGlassBackground
                            )
                    } else {
                        assistantBubbleFallback(sizedContent, isError: isError, shape: shape)
                    }
                } else {
                    assistantBubbleFallback(sizedContent, isError: isError, shape: shape)
                }
            }
            .overlay(alignment: .top) {
                if shouldShowSeparator {
                    separatorLine
                }
            }
            .clipShape(shape)
        }
    }

    @ViewBuilder
    func reasoningToolTimeline(reasoning: String?, toolCalls: [InternalToolCall]) -> some View {
        let trimmedReasoning = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasReasoning = !(trimmedReasoning ?? "").isEmpty
        let hasVisibleBodyContent = hasNonPlaceholderText && message.role != .tool
        let toolPresentations = timelineToolCallPresentations(for: toolCalls, hasReasoning: hasReasoning)
        let visibleToolStepCount = toolPresentations.filter { $0.stepIndex != nil }.count
        let shouldShowDoneStep = shouldShowTimelineDoneStep(
            hasReasoning: hasReasoning,
            hasVisibleBodyContent: hasVisibleBodyContent,
            isReasoningExpanded: isReasoningExpanded,
            toolPresentations: toolPresentations
        )
        let stepCount = (hasReasoning ? 1 : 0) + visibleToolStepCount + (shouldShowDoneStep ? 1 : 0)
        let doneStepIndex = stepCount - 1
        let usesCompactReasoningTimeline = hasReasoning && toolPresentations.isEmpty
        let timelineVerticalPadding: CGFloat = usesCompactReasoningTimeline ? 0 : 1
        let externalLineBridge = assistantContentInsets.top + timelineVerticalPadding

        if stepCount > 0 || !toolPresentations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let trimmedReasoning, hasReasoning {
                    WatchAssistantTimelineStepShell(
                        iconName: "lightbulb",
                        iconColor: timelineAccentColor,
                        lineColor: timelineLineColor,
                        iconSize: 11,
                        iconFrameSize: 18,
                        iconColumnWidth: 20,
                        contentSpacing: 6,
                        iconTopPadding: 3,
                        contentVerticalPadding: 2,
                        lineTopY: 4,
                        lineBottomY: 18,
                        isFirst: !connectsTimelineFromPrevious,
                        isLast: stepCount == 1 && !connectsTimelineToNext,
                        extendsLineThroughContent: isReasoningExpanded || (!shouldSuppressReasoningContentRender && isReasoningAutoPreview),
                        lineTopExtension: connectsTimelineFromPrevious ? externalLineBridge : 0,
                        lineBottomExtension: stepCount == 1 && connectsTimelineToNext ? externalLineBridge : 0
                    ) {
                        WatchTimelineReasoningStepView(
                            reasoning: trimmedReasoning,
                            preparedReasoningContent: preparedReasoningMarkdownPayload,
                            reasoningThinkingTitle: reasoningThinkingTitle,
                            isExpanded: $isReasoningExpanded,
                            isPreviewing: isReasoningAutoPreview,
                            suppressContentRender: shouldSuppressReasoningContentRender,
                            isShimmering: shouldShimmerReasoningHeader,
                            customTextColor: customTextColorOverride,
                            previewMaxHeight: reasoningPreviewMaxHeight,
                            enableMarkdown: enableMarkdown,
                            enableAdvancedRenderer: enableAdvancedRenderer,
                            enableMathRendering: enableMathRendering,
                            reasoningStartedAt: reasoningStartedAt,
                            reasoningCompletedAt: reasoningCompletedAt,
                            fallbackReasoningDuration: fallbackReasoningDuration,
                            reasoningSummary: reasoningSummaryText
                        )
                    }
                }

                ForEach(toolPresentations) { presentation in
                    if let payload = presentation.widgetPayload {
                        timelineWidgetContent(payload: payload)
                    } else if let stepIndex = presentation.stepIndex {
                        let status = toolCallStatus(for: presentation.call)
                        WatchAssistantTimelineStepShell(
                            iconName: "wrench.and.screwdriver",
                            iconColor: status.accentColor,
                            lineColor: timelineLineColor,
                            isFirst: stepIndex == 0 && !connectsTimelineFromPrevious,
                            isLast: stepIndex == stepCount - 1 && !connectsTimelineToNext,
                            lineTopExtension: stepIndex == 0 && connectsTimelineFromPrevious ? externalLineBridge : 0,
                            lineBottomExtension: stepIndex == stepCount - 1 && connectsTimelineToNext ? externalLineBridge : 0
                        ) {
                            timelineToolCallRow(for: presentation.call, status: status)
                        }
                    }
                }

                if shouldShowDoneStep {
                    WatchAssistantTimelineStepShell(
                        iconName: "checkmark.circle",
                        iconColor: timelineDoneColor,
                        lineColor: timelineLineColor,
                        isFirst: doneStepIndex == 0 && !connectsTimelineFromPrevious,
                        isLast: !connectsTimelineToNext,
                        lineTopExtension: doneStepIndex == 0 && connectsTimelineFromPrevious ? externalLineBridge : 0,
                        lineBottomExtension: connectsTimelineToNext ? externalLineBridge : 0
                    ) {
                        Text("Done")
                            .etFont(.footnote.weight(.semibold))
                            .foregroundStyle(timelineDoneColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, timelineVerticalPadding)
        }
    }

    func shouldShowTimelineDoneStep(
        hasReasoning: Bool,
        hasVisibleBodyContent: Bool,
        isReasoningExpanded: Bool,
        toolPresentations: [TimelineToolCallPresentation]
    ) -> Bool {
        guard hasReasoning,
              hasVisibleBodyContent,
              isReasoningExpanded,
              isReasoningFinishedForTimeline else {
            return false
        }
        return toolPresentations.allSatisfy { presentation in
            guard presentation.stepIndex != nil else { return true }
            let status = toolCallStatus(for: presentation.call)
            return status != .pendingApproval && status != .running
        }
    }

    struct TimelineToolCallPresentation: Identifiable {
        let call: InternalToolCall
        let widgetPayload: ToolWidgetPayload?
        let stepIndex: Int?

        var id: String {
            call.id
        }
    }

    func timelineToolCallPresentations(
        for toolCalls: [InternalToolCall],
        hasReasoning: Bool
    ) -> [TimelineToolCallPresentation] {
        var nextStepIndex = hasReasoning ? 1 : 0
        return toolCalls.map { call in
            if let payload = showWidgetPayload(for: call) {
                return TimelineToolCallPresentation(call: call, widgetPayload: payload, stepIndex: nil)
            }
            let stepIndex = nextStepIndex
            nextStepIndex += 1
            return TimelineToolCallPresentation(call: call, widgetPayload: nil, stepIndex: stepIndex)
        }
    }

    var timelineAccentColor: Color {
        customTextColorOverride?.opacity(0.9)
            ?? (colorScheme == .dark ? Color.white.opacity(0.84) : Color.secondary)
    }

    var timelineLineColor: Color {
        customTextColorOverride?.opacity(0.44)
            ?? (colorScheme == .dark ? Color.white.opacity(0.56) : Color.secondary.opacity(0.38))
    }

    var timelineDoneColor: Color {
        customTextColorOverride?.opacity(0.86)
            ?? (colorScheme == .dark ? Color.white.opacity(0.86) : Color.secondary)
    }

    @ViewBuilder
    func timelineToolCallRow(for call: InternalToolCall, status: ToolCallBubbleStatus) -> some View {
        let label = toolDisplayLabel(for: call.toolName)
        Button {
            showRawToolResultInDetailSheet = false
            selectedToolCallDetailSheetItem = ToolCallDetailSheetItem(
                messageID: message.id,
                toolCallID: call.id,
                fallbackToolCall: call
            )
        } label: {
            WatchTimelineToolCallStepContent(
                label: label,
                statusTitle: status.title,
                statusIconName: status.iconName,
                statusColor: status.accentColor,
                showPendingGuidance: shouldShowPendingGuidance(for: call),
                customTextColor: customTextColorOverride
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func timelineWidgetContent(payload: ToolWidgetPayload) -> some View {
        widgetInlineSummaryView(payload: payload)
            .padding(.vertical, 3)
    }

    @ViewBuilder
    var toolCallsSection: some View {
        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(toolCalls, id: \.id) { call in
                    toolCallBubbleContent(for: call)
                }
            }
        }
    }

    @ViewBuilder
    func toolCallBubbleContent(for call: InternalToolCall) -> some View {
        if let payload = showWidgetPayload(for: call) {
            widgetInlineSummaryView(payload: payload)
        } else {
            toolCallSummaryRow(for: call)
        }
    }

    func toolResultExpansionBinding(for toolCallID: String) -> Binding<Bool> {
        Binding(
            get: { toolCallResultExpandedState[toolCallID, default: isToolCallsExpanded] },
            set: { toolCallResultExpandedState[toolCallID] = $0 }
        )
    }
}

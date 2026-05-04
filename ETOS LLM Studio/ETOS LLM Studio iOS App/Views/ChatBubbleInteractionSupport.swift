// ============================================================================
// ChatBubbleInteractionSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的工具交互、详情面板、附件与音频辅助逻辑。
// ============================================================================

import Foundation
import SwiftUI
import Shared
import UIKit

extension ChatBubble {
    // MARK: - Content

    @ViewBuilder
    var separatedToolCallBubbleStack: some View {
        let toolCalls = message.toolCalls ?? []
        let hasMainBubble = hasMainContentWhenToolCallsSeparated
        let totalBubbleCount = toolCalls.count + (hasMainBubble ? 1 : 0)

        VStack(alignment: .leading, spacing: 0) {
            if hasMainBubble {
                connectedToolBubbleContainer(isFirst: true, isLast: totalBubbleCount == 1) {
                    textContentStack(includeToolCalls: false)
                }
            }

            ForEach(Array(toolCalls.enumerated()), id: \.element.id) { offset, call in
                let position = (hasMainBubble ? 1 : 0) + offset
                let isFirst = position == 0
                let isLast = position == (totalBubbleCount - 1)

                connectedToolBubbleContainer(isFirst: isFirst, isLast: isLast) {
                    toolCallBubbleContent(for: call)
                }
            }
        }
    }

    @ViewBuilder
    func textContentStack(includeToolCalls: Bool) -> some View {
        let toolCalls = message.toolCalls ?? []
        let reasoning = message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canUseTimeline = shouldRenderReasoningToolTimeline && includeToolCalls

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
                ReasoningDisclosureView(
                    reasoning: reasoning,
                    preparedReasoningContent: preparedReasoningMarkdownPayload,
                    isExpanded: $isReasoningExpanded,
                    isPreviewing: isReasoningAutoPreview,
                    isOutgoing: isOutgoing,
                    usesNoBubbleStyle: usesNoBubbleStyle,
                    isShimmering: shouldShimmerReasoningHeader,
                    customTextColor: customTextColorOverride,
                    enableMarkdown: enableMarkdown,
                    enableAdvancedRenderer: enableAdvancedRenderer,
                    enableMathRendering: enableMathRendering,
                    reasoningStartedAt: reasoningStartedAt,
                    reasoningCompletedAt: reasoningCompletedAt,
                    reasoningSummary: message.responseMetrics?.reasoningSummary
                )
            }

            if includeToolCalls && shouldShowToolCallsBeforeContent {
                toolCallsSection
            }
        }

        if let standaloneShowWidgetPayload {
            ToolWidgetRendererCard(payload: standaloneShowWidgetPayload)
        } else if !message.content.isEmpty, message.role != .tool || (message.toolCalls?.isEmpty ?? true) {
            if let audioFileName = message.audioFileName {
                audioPlayerView(fileName: audioFileName)
            } else {
                renderContent(message.content)
                    .etFont(.body)
                    .foregroundStyle(textForegroundColor)
                    .textSelection(.enabled)
            }
        } else if message.role == .assistant,
                  (message.reasoningContent ?? "").isEmpty,
                  (message.toolCalls ?? []).isEmpty {
            if showsStreamingIndicators {
                ShimmeringText(
                    text: NSLocalizedString("正在思考...", comment: ""),
                    font: .subheadline,
                    baseColor: resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75),
                    highlightColor: resolvedTextColor(default: Color.primary.opacity(0.85))
                )
            } else {
                Text(NSLocalizedString("正在思考...", comment: ""))
                    .etFont(.subheadline)
                    .foregroundStyle(resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75))
            }
        }

        if canUseTimeline {
            if shouldShowToolCallsAfterContent {
                reasoningToolTimeline(reasoning: nil, toolCalls: toolCalls)
            }
        } else if includeToolCalls && shouldShowToolCallsAfterContent {
            toolCallsSection
        }
    }

    func reasoningToolTimeline(reasoning: String?, toolCalls: [InternalToolCall]) -> some View {
        let trimmedReasoning = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasReasoning = !(trimmedReasoning ?? "").isEmpty
        let trimmedBodyContent = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVisibleBodyContent = message.role != .tool
            && !trimmedBodyContent.isEmpty
            && !Self.imagePlaceholders.contains(trimmedBodyContent)
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
        let timelineVerticalPadding: CGFloat = usesCompactReasoningTimeline ? 0 : 2
        let externalLineBridge = bubbleContentVerticalPadding + timelineVerticalPadding

        if stepCount > 0 || !toolPresentations.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let trimmedReasoning, hasReasoning {
                    AssistantTimelineStepShell(
                        iconName: "lightbulb",
                        iconColor: timelineAccentColor,
                        lineColor: timelineLineColor,
                        iconSize: 12,
                        iconFrameSize: 22,
                        iconColumnWidth: 24,
                        contentSpacing: 8,
                        iconTopPadding: 3,
                        contentVerticalPadding: 2,
                        lineTopY: 4,
                        lineBottomY: 20,
                        isFirst: !connectsTimelineFromPrevious,
                        isLast: stepCount == 1 && !connectsTimelineToNext,
                        extendsLineThroughContent: isReasoningExpanded || isReasoningAutoPreview,
                        lineTopExtension: connectsTimelineFromPrevious ? externalLineBridge : 0,
                        lineBottomExtension: stepCount == 1 && connectsTimelineToNext ? externalLineBridge : 0
                    ) {
                        TimelineReasoningStepView(
                            reasoning: trimmedReasoning,
                            preparedReasoningContent: preparedReasoningMarkdownPayload,
                            isExpanded: $isReasoningExpanded,
                            isPreviewing: isReasoningAutoPreview,
                            isShimmering: shouldShimmerReasoningHeader,
                            customTextColor: customTextColorOverride,
                            usesNoBubbleStyle: usesNoBubbleStyle,
                            enableMarkdown: enableMarkdown,
                            enableAdvancedRenderer: enableAdvancedRenderer,
                            enableMathRendering: enableMathRendering,
                            reasoningStartedAt: reasoningStartedAt,
                            reasoningCompletedAt: reasoningCompletedAt,
                            reasoningSummary: message.responseMetrics?.reasoningSummary
                        )
                    }
                }

                ForEach(toolPresentations) { presentation in
                    if let payload = presentation.widgetPayload {
                        timelineWidgetContent(payload: payload)
                    } else if let stepIndex = presentation.stepIndex {
                        let status = toolCallStatus(for: presentation.call)
                        AssistantTimelineStepShell(
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
                    AssistantTimelineStepShell(
                        iconName: "checkmark.circle",
                        iconColor: timelineDoneColor,
                        lineColor: timelineLineColor,
                        isFirst: doneStepIndex == 0 && !connectsTimelineFromPrevious,
                        isLast: !connectsTimelineToNext,
                        lineTopExtension: doneStepIndex == 0 && connectsTimelineFromPrevious ? externalLineBridge : 0,
                        lineBottomExtension: connectsTimelineToNext ? externalLineBridge : 0
                    ) {
                        Text("Done")
                            .etFont(.subheadline.weight(.semibold))
                            .foregroundStyle(timelineDoneColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, timelineVerticalPadding)
        }
    }

    private func shouldShowTimelineDoneStep(
        hasReasoning: Bool,
        hasVisibleBodyContent: Bool,
        isReasoningExpanded: Bool,
        toolPresentations: [TimelineToolCallPresentation]
    ) -> Bool {
        guard hasReasoning,
              hasVisibleBodyContent,
              isReasoningExpanded,
              reasoningCompletedAt != nil else {
            return false
        }
        return toolPresentations.allSatisfy { presentation in
            guard presentation.stepIndex != nil else { return true }
            let status = toolCallStatus(for: presentation.call)
            return status != .pendingApproval && status != .running
        }
    }
    private struct TimelineToolCallPresentation: Identifiable {
        let call: InternalToolCall
        let widgetPayload: ToolWidgetPayload?
        let stepIndex: Int?

        var id: String {
            call.id
        }
    }

    private func timelineToolCallPresentations(
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

    private var timelineAccentColor: Color {
        customTextColorOverride?.opacity(0.9) ?? (usesNoBubbleStyle ? Color.primary.opacity(0.82) : Color.secondary)
    }

    private var timelineLineColor: Color {
        customTextColorOverride?.opacity(0.28) ?? Color.secondary.opacity(0.34)
    }

    private var timelineDoneColor: Color {
        customTextColorOverride?.opacity(0.86) ?? Color.secondary
    }

    @ViewBuilder
    private func timelineToolCallRow(for call: InternalToolCall, status: ToolCallBubbleStatus) -> some View {
        let label = toolDisplayLabel(for: call.toolName)
        Button {
            showRawToolResultInDetailSheet = false
            selectedToolCallDetailSheetItem = ToolCallDetailSheetItem(
                messageID: message.id,
                toolCallID: call.id,
                fallbackToolCall: call
            )
        } label: {
            TimelineToolCallStepContent(
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
    private func timelineWidgetContent(payload: ToolWidgetPayload) -> some View {
        ToolWidgetRendererCard(payload: payload)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private var toolCallsSection: some View {
        if let toolCalls = message.toolCalls,
           !toolCalls.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(toolCalls, id: \.id) { call in
                    toolCallBubbleContent(for: call)
                }
            }
        }
    }

    @ViewBuilder
    private func toolCallBubbleContent(for call: InternalToolCall) -> some View {
        if let payload = showWidgetPayload(for: call) {
            ToolWidgetRendererCard(payload: payload)
        } else {
            toolCallSummaryRow(for: call)
        }
    }

    func resolvedToolResultText(for call: InternalToolCall) -> String {
        let fallback = message.role == .tool ? message.content : ""
        return (call.result ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isPendingToolResult(for call: InternalToolCall) -> Bool {
        if showWidgetPayload(for: call) != nil {
            return false
        }
        return hasPendingToolResults && resolvedToolResultText(for: call).isEmpty
    }

    func shouldShowToolResult(for call: InternalToolCall) -> Bool {
        if showWidgetPayload(for: call) != nil {
            return false
        }
        return !resolvedToolResultText(for: call).isEmpty || isPendingToolResult(for: call)
    }

    func activeToolPermissionRequest(for call: InternalToolCall) -> ToolPermissionRequest? {
        guard message.role != .user,
              let request = toolPermissionCenter.activeRequest else {
            return nil
        }
        let trimmedArgs = request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let callArgs = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMatch = call.toolName == request.toolName && callArgs == trimmedArgs
        return isMatch ? request : nil
    }

    var toolCallAutoPresentationSignature: String {
        let callIDs = (message.toolCalls ?? []).map(\.id).joined(separator: "|")
        let activeRequestID = toolPermissionCenter.activeRequest?.id.uuidString ?? ""
        return "\(message.id.uuidString)#\(callIDs)#\(activeRequestID)"
    }

    func autoPresentPendingToolCallIfNeeded() {
        guard selectedToolCallDetailSheetItem == nil else { return }
        guard let pendingCall = pendingToolCallForAutoPresentation else { return }
        markPendingToolCallAutoOpened(pendingCall.id)
        showRawToolResultInDetailSheet = false
        selectedToolCallDetailSheetItem = ToolCallDetailSheetItem(
            messageID: message.id,
            toolCallID: pendingCall.id,
            fallbackToolCall: pendingCall
        )
    }

    func resolvedToolCall(for item: ToolCallDetailSheetItem) -> InternalToolCall {
        message.toolCalls?.first(where: { $0.id == item.toolCallID }) ?? item.fallbackToolCall
    }

    func toolDisplayLabel(for toolName: String) -> String {
        if toolName == "save_memory" {
            return NSLocalizedString("添加记忆", comment: "Tool label for saving memory.")
        }
        if let label = MCPManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = ShortcutToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = SkillManager.shared.displayLabel(for: toolName) {
            return label
        }
        if let label = AppToolManager.shared.displayLabel(for: toolName) {
            return label
        }
        return toolName
    }

    func toolCallStatus(for call: InternalToolCall) -> ToolCallBubbleStatus {
        if activeToolPermissionRequest(for: call) != nil {
            return .pendingApproval
        }
        let resolvedResult = resolvedToolResultText(for: call)
        if resolvedResult.isEmpty {
            return .running
        }
        if isDeniedToolResultText(resolvedResult) {
            return .rejected
        }
        return .finished
    }

    private func isDeniedToolResultText(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("denied")
            || normalized.contains("拒绝")
            || normalized.contains("拒絕")
            || normalized.contains("rejected")
    }

    func shouldShowPendingGuidance(for call: InternalToolCall) -> Bool {
        activeToolPermissionRequest(for: call) != nil
    }

    @ViewBuilder
    func toolCallSummaryRow(for call: InternalToolCall) -> some View {
        let label = toolDisplayLabel(for: call.toolName)
        let status = toolCallStatus(for: call)
        Button {
            showRawToolResultInDetailSheet = false
            selectedToolCallDetailSheetItem = ToolCallDetailSheetItem(
                messageID: message.id,
                toolCallID: call.id,
                fallbackToolCall: call
            )
        } label: {
            ToolCallSummaryBubbleRow(
                label: label,
                statusTitle: status.title,
                statusIconName: status.iconName,
                statusColor: status.accentColor,
                showPendingGuidance: shouldShowPendingGuidance(for: call),
                isOutgoing: isOutgoing,
                customTextColor: customTextColorOverride
            )
        }
        .buttonStyle(.plain)
    }

}

// ============================================================================
// ChatBubble.swift
// ============================================================================
// 聊天气泡 (Telegram 风格)
// - 仿 Telegram 气泡形状与配色
// - 用户消息：蓝色
// - AI 消息：白色/灰色
// - 支持 Markdown 与推理展开
// - 支持语音消息播放
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
extension ChatBubble {

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
            // 思考过程 (Telegram 风格折叠)
            if let reasoning,
               !reasoning.isEmpty {
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
        
        // 消息正文
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
            // 加载指示器
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

    @ViewBuilder
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

    func shouldShowTimelineDoneStep(
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
        customTextColorOverride?.opacity(0.9) ?? (usesNoBubbleStyle ? Color.primary.opacity(0.82) : Color.secondary)
    }

    var timelineLineColor: Color {
        customTextColorOverride?.opacity(0.28) ?? Color.secondary.opacity(0.34)
    }

    var timelineDoneColor: Color {
        customTextColorOverride?.opacity(0.86) ?? Color.secondary
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
    func timelineWidgetContent(payload: ToolWidgetPayload) -> some View {
        // show_widget 必须保持整列宽度，不能放进时间线 step，否则左侧连线会压缩 HTML 卡片。
        ToolWidgetRendererCard(payload: payload)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    var toolCallsSection: some View {
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
    func toolCallBubbleContent(for call: InternalToolCall) -> some View {
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

    func isDeniedToolResultText(_ text: String) -> Bool {
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

    @ViewBuilder
    func toolCallDetailSheet(for item: ToolCallDetailSheetItem) -> some View {
        let call = resolvedToolCall(for: item)
        let displayName = toolDisplayLabel(for: call.toolName)
        let status = toolCallStatus(for: call)
        let argumentText = prettyPrintedJSONOrRaw(call.arguments)
        let resultText = resolvedToolResultText(for: call)
        let displayModel = MCPToolResultFormatter.displayModel(from: resultText)
        let permissionRequest = activeToolPermissionRequest(for: call)

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(status.accentColor)
                        .etFont(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .etFont(.headline)
                        Text(status.title)
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(NSLocalizedString("关闭", comment: "")) {
                        selectedToolCallDetailSheetItem = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                toolDetailSection(title: "工具参数") {
                    CappedScrollableText(
                        text: argumentText,
                        maxHeight: 240,
                        font: .system(.caption, design: .monospaced),
                        foreground: .secondary,
                        enableSelection: true
                    )
                }

                if permissionRequest == nil {
                    toolDetailSection(title: "工具结果") {
                        if resultText.isEmpty {
                            Text(status == .pendingApproval ? NSLocalizedString("等待你的审批后继续执行。", comment: "") : NSLocalizedString("暂无返回结果。", comment: ""))
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                        } else if enableExperimentalToolResultDisplay {
                            let primaryContent = displayModel.primaryContentText?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let hasPrimaryContent = !(primaryContent ?? "").isEmpty
                            let canToggleRaw = hasPrimaryContent && displayModel.shouldShowRawSection
                            let showRaw = canToggleRaw && showRawToolResultInDetailSheet

                            if showRaw || !hasPrimaryContent {
                                CappedScrollableText(
                                    text: displayModel.rawDisplayText,
                                    maxHeight: 240,
                                    font: .system(.caption, design: .monospaced),
                                    foreground: .secondary,
                                    enableSelection: true
                                )
                            } else if let primaryContent {
                                CappedScrollableText(
                                    text: primaryContent,
                                    maxHeight: 240,
                                    font: .footnote,
                                    foreground: .secondary,
                                    enableSelection: true
                                )
                            }

                            if canToggleRaw {
                                Divider()
                                HStack {
                                    Button(showRawToolResultInDetailSheet ? NSLocalizedString("显示整理结果", comment: "") : NSLocalizedString("显示原文", comment: "")) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            showRawToolResultInDetailSheet.toggle()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    Spacer(minLength: 0)
                                }
                            }
                        } else {
                            CappedScrollableText(
                                text: resultText,
                                maxHeight: 240,
                                font: .system(.caption, design: .monospaced),
                                foreground: .secondary,
                                enableSelection: true
                            )
                        }
                    }
                }

                if let permissionRequest {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("审批操作", comment: ""))
                            .etFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ToolPermissionInlineView(
                            request: permissionRequest,
                            onDecision: { decision in
                                toolPermissionCenter.resolveActiveRequest(with: decision)
                                selectedToolCallDetailSheetItem = nil
                            }
                        )
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.clear)
    }

    @ViewBuilder
    func toolDetailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "工具详情小节标题"))
                .etFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    func prettyPrintedJSONOrRaw(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let prettyText = String(data: prettyData, encoding: .utf8) else {
            return trimmed
        }
        return prettyText
    }
    
    @ViewBuilder
    func imageAttachmentsView(fileNames: [String]) -> some View {
        HStack(spacing: 0) {
            if isOutgoing {
                Spacer(minLength: 0)
            }
            
            // 根据图片数量决定布局
            let columns: [GridItem] = fileNames.count == 1
                ? [GridItem(.flexible(minimum: 150, maximum: 220))]
                : [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 4)]
            let minWidth = fileNames.count == 1 ? 150.0 : 80.0
            let maxWidth = fileNames.count == 1 ? 220.0 : 140.0
            let itemHeight = fileNames.count == 1 ? 180.0 : 100.0
            
            LazyVGrid(columns: columns, alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                ForEach(fileNames, id: \.self) { fileName in
                    AttachmentImageView(
                        fileName: fileName,
                        minWidth: minWidth,
                        maxWidth: maxWidth,
                        height: itemHeight,
                        cornerRadius: 16
                    ) { image in
                        imagePreview = ImagePreviewPayload(image: image)
                    }
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.65, alignment: isOutgoing ? .trailing : .leading)
            
            if !isOutgoing {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func fileAttachmentsView(fileNames: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fileNames, id: \.self) { fileName in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .etFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            usesNoBubbleStyle
                                ? resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8)
                                : (isOutgoing
                                    ? resolvedSecondaryTextColor(default: Color.white.opacity(0.85), customOpacity: 0.85)
                                    : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.8))
                        )
                    Text(fileName)
                        .etFont(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(
                            usesNoBubbleStyle
                                ? resolvedTextColor(default: Color.primary)
                                : resolvedTextColor(default: isOutgoing ? Color.white : Color.primary)
                        )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            usesNoBubbleStyle
                                ? Color.clear
                                : (isOutgoing
                                    ? resolvedUserBubbleEndColor
                                    : (resolvedAssistantBubbleColor ?? Color(uiColor: .secondarySystemBackground)))
                        )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
    
    @ViewBuilder
    func renderContent(_ content: String) -> some View {
        let shouldRenderAsOutgoing = isOutgoing || isError
        ETAdvancedMarkdownRenderer(
            content: content,
            preparedContent: preparedMarkdownPayload,
            enableMarkdown: enableMarkdown,
            isOutgoing: shouldRenderAsOutgoing,
            enableAdvancedRenderer: enableAdvancedRenderer,
            enableMathRendering: enableMathRendering,
            customTextColor: customTextColorOverride
        )
    }
    
    @ViewBuilder
    func audioPlayerView(fileName: String) -> some View {
        let foregroundColor = usesNoBubbleStyle
            ? resolvedTextColor(default: Color.primary)
            : resolvedTextColor(default: isOutgoing ? Color.white : Color.primary)
        let secondaryColor = usesNoBubbleStyle
            ? resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75)
            : (isOutgoing
                ? resolvedSecondaryTextColor(default: Color.white.opacity(0.7), customOpacity: 0.7)
                : resolvedSecondaryTextColor(default: Color.secondary, customOpacity: 0.75))
        
        HStack(spacing: 12) {
            // 播放按钮
            Button {
                audioPlayer.togglePlayback(fileName: fileName)
            } label: {
                ZStack {
                    Circle()
                        .fill(usesNoBubbleStyle ? Color.secondary.opacity(0.15) : (isOutgoing ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15)))
                        .frame(width: 44, height: 44)
                    Image(systemName: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName ? "stop.fill" : "play.fill")
                        .etFont(.system(size: 16, weight: .semibold))
                        .foregroundStyle(foregroundColor)
                }
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 4) {
                // 波形动画 / 进度条
                TelegramWaveformView(
                    progress: audioPlayer.currentFileName == fileName ? audioPlayer.progress : 0,
                    isPlaying: audioPlayer.isPlaying && audioPlayer.currentFileName == fileName,
                    foregroundColor: foregroundColor,
                    backgroundColor: secondaryColor.opacity(0.4)
                )
                .frame(height: 20)
                
                // 时长
                if audioPlayer.currentFileName == fileName && audioPlayer.duration > 0 {
                    Text(audioPlayer.timeString)
                        .etFont(.caption2)
                        .foregroundStyle(secondaryColor)
                        .monospacedDigit()
                } else {
                    Text(fileName)
                        .etFont(.caption2)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: 180)
    }
}

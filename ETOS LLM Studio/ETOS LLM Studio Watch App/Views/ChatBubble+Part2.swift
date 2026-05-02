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
                        extendsLineThroughContent: isReasoningExpanded || isReasoningAutoPreview,
                        lineTopExtension: connectsTimelineFromPrevious ? externalLineBridge : 0,
                        lineBottomExtension: stepCount == 1 && connectsTimelineToNext ? externalLineBridge : 0
                    ) {
                        WatchTimelineReasoningStepView(
                            reasoning: trimmedReasoning,
                            preparedReasoningContent: preparedReasoningMarkdownPayload,
                            isExpanded: $isReasoningExpanded,
                            isPreviewing: isReasoningAutoPreview,
                            isShimmering: shouldShimmerReasoningHeader,
                            customTextColor: customTextColorOverride,
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
        // watchOS 不直接渲染 HTML，但 show_widget 也不能放进时间线 step，避免轻量提示被连线压缩。
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
            WatchToolCallSummaryBubbleRow(
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
    func toolCallDetailSheet(for item: ToolCallDetailSheetItem) -> some View {
        let call = resolvedToolCall(for: item)
        let displayName = toolDisplayLabel(for: call.toolName)
        let status = toolCallStatus(for: call)
        let argumentText = prettyPrintedJSONOrRaw(call.arguments)
        let resultText = resolvedToolResultText(for: call)
        let displayModel = MCPToolResultFormatter.displayModel(from: resultText)
        let permissionRequest = activeToolPermissionRequest(for: call)

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .foregroundStyle(status.accentColor)
                        .etFont(.system(size: 13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeText(
                            content: displayName,
                            uiFont: .preferredFont(forTextStyle: .footnote),
                            font: .footnote.weight(.semibold)
                        )
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(status.title)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                toolDetailSection(title: "工具参数") {
                    CappedScrollableText(
                        text: argumentText,
                        maxHeight: 120,
                        font: .system(.caption2, design: .monospaced),
                        foreground: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.85)
                    )
                }

                if permissionRequest == nil {
                    toolDetailSection(title: "工具结果") {
                        if resultText.isEmpty {
                            Text(status == .pendingApproval ? NSLocalizedString("等待你的审批后继续执行。", comment: "") : NSLocalizedString("暂无返回结果。", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        } else if enableExperimentalToolResultDisplay {
                            let primaryContent = displayModel.primaryContentText?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let hasPrimaryContent = !(primaryContent ?? "").isEmpty
                            let canToggleRaw = hasPrimaryContent && displayModel.shouldShowRawSection
                            let showRaw = canToggleRaw && showRawToolResultInDetailSheet

                            VStack(alignment: .leading, spacing: 6) {
                                if showRaw || !hasPrimaryContent {
                                    CappedScrollableText(
                                        text: displayModel.rawDisplayText,
                                        maxHeight: 120,
                                        font: .system(.caption2, design: .monospaced),
                                        foreground: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.82)
                                    )
                                } else if let primaryContent {
                                    CappedScrollableText(
                                        text: primaryContent,
                                        maxHeight: 120,
                                        font: .caption2,
                                        foreground: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.85)
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
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        } else {
                            CappedScrollableText(
                                text: resultText,
                                maxHeight: 120,
                                font: .system(.caption2, design: .monospaced),
                                foreground: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.85)
                            )
                        }
                    }
                }

                if let permissionRequest {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(NSLocalizedString("审批操作", comment: ""))
                            .etFont(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        toolPermissionInlineView(
                            request: permissionRequest,
                            onDecision: { decision in
                                toolPermissionCenter.resolveActiveRequest(with: decision)
                                selectedToolCallDetailSheetItem = nil
                            }
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    func toolDetailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(title, comment: "工具详情小节标题"))
                .etFont(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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

    var shouldShowUserBubble: Bool {
        message.audioFileName != nil || hasNonPlaceholderText
    }

    var shouldShowAssistantBubble: Bool {
        let hasReasoning = message.reasoningContent != nil && !(message.reasoningContent ?? "").isEmpty
        if message.role == .tool {
            return hasToolCalls || hasNonPlaceholderText
        }
        return hasToolCalls || hasReasoning || hasNonPlaceholderText || shouldShowThinkingIndicator
    }

    var shouldPlaceAssistantImagesAfterText: Bool {
        message.role != .user && message.role != .error && shouldShowAssistantBubble
    }

    // MARK: - 辅助视图
    
    @ViewBuilder
    func renderContent(_ content: String) -> some View {
        let shouldRenderAsOutgoing = message.role == .user
            || message.role == .error
            || (message.role == .assistant && message.content.hasPrefix("重试失败"))
        ETAdvancedMarkdownRenderer(
            content: content,
            preparedContent: preparedMarkdownPayload,
            enableMarkdown: enableMarkdown,
            isOutgoing: shouldRenderAsOutgoing,
            enableAdvancedRenderer: enableAdvancedRenderer,
            enableMathRendering: enableMathRendering,
            customTextColor: customTextColorOverride,
            onCodeBlockHeaderTap: onCodeBlockHeaderTap
        )
    }
    
    @ViewBuilder
    func audioPlayerView(fileName: String, isUser: Bool) -> some View {
        let foregroundColor = resolvedTextColor(default: (isUser && !usesNoBubbleStyle) ? Color.white : Color.primary)
        let secondaryColor = resolvedSecondaryTextColor(
            default: (isUser && !usesNoBubbleStyle) ? Color.white.opacity(0.7) : Color.secondary,
            customOpacity: 0.75
        )
        let isCurrentFile = audioPlayer.currentFileName == fileName
        
        VStack(alignment: .leading, spacing: 4) {
            // 播放按钮 + 文件名
            HStack(spacing: 6) {
                Button {
                    audioPlayer.togglePlayback(fileName: fileName)
                } label: {
                    Image(systemName: audioPlayer.isPlaying && isCurrentFile ? "stop.circle.fill" : "play.circle.fill")
                        .etFont(.system(size: 22))
                        .foregroundStyle(foregroundColor)
                }
                .buttonStyle(.plain)
                
                Text(fileName)
                    .etFont(.system(size: 9))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            
            // 进度条 + 时间
            if isCurrentFile && audioPlayer.duration > 0 {
                ProgressView(value: audioPlayer.progress)
                    .progressViewStyle(.linear)
                    .tint(foregroundColor)
                
                HStack {
                    Text(formatTime(audioPlayer.currentTime))
                    Spacer()
                    Text(formatTime(audioPlayer.duration))
                }
                .etFont(.system(size: 9))
                .foregroundStyle(secondaryColor)
            }
        }
    }
    
    func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    @ViewBuilder
    func widgetInlineSummaryView(payload: ToolWidgetPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("可视化 Widget", comment: ""))
                .etFont(.caption2.weight(.semibold))
                .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.9))
            if let title = payload.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .etFont(.caption2)
                    .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.85))
            }
            Text(NSLocalizedString("已生成 HTML 卡片，请在 iPhone 端查看完整渲染。", comment: ""))
                .etFont(.caption2)
                .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8))
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    func imageAttachmentsView(fileNames: [String], isOutgoing: Bool) -> some View {
        let columns: [GridItem] = fileNames.count == 1
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
        let itemHeight: CGFloat = fileNames.count == 1 ? 120 : 70

        LazyVGrid(columns: columns, alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
            ForEach(fileNames, id: \.self) { fileName in
                AttachmentImageView(
                    fileName: fileName,
                    height: itemHeight
                ) { image in
                    imagePreview = ImagePreviewPayload(image: image)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
    
    @ViewBuilder
    func reasoningView(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: {
                withAnimation {
                    if isReasoningAutoPreview {
                        isReasoningExpanded = true
                    } else {
                        isReasoningExpanded.toggle()
                    }
                }
            }) {
                HStack(alignment: .top, spacing: 6) {
                    Group {
                        if shouldShimmerReasoningHeader {
                            reasoningHeaderTitleView(
                                baseColor: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.75),
                                highlightColor: resolvedTextColor(default: .primary.opacity(0.85))
                            )
                        } else {
                            reasoningHeaderTitleView(
                                baseColor: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8),
                                highlightColor: resolvedTextColor(default: .primary.opacity(0.85))
                            )
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 4)
                    Image(systemName: isReasoningExpanded && !isReasoningAutoPreview ? "chevron.down" : "chevron.right")
                        .etFont(.caption)
                        .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8))
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if isReasoningExpanded || isReasoningAutoPreview {
                let contentColor = resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8)
                WatchReasoningPreviewContent(
                    isPreviewing: isReasoningAutoPreview,
                    maxHeight: 86,
                    contentID: reasoning
                ) {
                    WatchReasoningMarkdownContentView(
                        reasoning: reasoning,
                        preparedReasoningContent: preparedReasoningMarkdownPayload,
                        enableMarkdown: enableMarkdown,
                        enableAdvancedRenderer: enableAdvancedRenderer,
                        enableMathRendering: enableMathRendering,
                        textColor: contentColor,
                        font: .footnote,
                        onCodeBlockHeaderTap: onCodeBlockHeaderTap
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, (isReasoningExpanded || isReasoningAutoPreview) ? 5 : 0)
    }

    @ViewBuilder
    func reasoningHeaderTitleView(baseColor: Color, highlightColor: Color) -> some View {
        if let reasoningStartedAt, reasoningCompletedAt == nil {
            TimelineView(.periodic(from: reasoningStartedAt, by: 1)) { context in
                reasoningHeaderTitleLabel(
                    title: reasoningHeaderTitle(referenceDate: context.date),
                    baseColor: baseColor,
                    highlightColor: highlightColor
                )
            }
        } else {
            reasoningHeaderTitleLabel(
                title: reasoningHeaderTitle(referenceDate: reasoningCompletedAt ?? Date()),
                baseColor: baseColor,
                highlightColor: highlightColor
            )
        }
    }

    @ViewBuilder
    func reasoningHeaderTitleLabel(title: String, baseColor: Color, highlightColor: Color) -> some View {
        if shouldShimmerReasoningHeader {
            ShimmeringText(
                text: title,
                font: .footnote,
                baseColor: baseColor,
                highlightColor: highlightColor
            )
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(title)
                .etFont(.footnote)
                .foregroundColor(baseColor)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func reasoningHeaderTitle(referenceDate: Date) -> String {
        if isReasoningAutoPreview,
           reasoningCompletedAt == nil,
           let thinkingTitle = preparedReasoningMarkdownPayload?.thinkingTitle,
           !thinkingTitle.isEmpty {
            return thinkingTitle
        }

        let baseTitle: String
        if let elapsedSeconds = reasoningElapsedSeconds(referenceDate: referenceDate) {
            baseTitle = String(format: NSLocalizedString("已经思考%d秒", comment: ""), elapsedSeconds)
        } else {
            baseTitle = NSLocalizedString("思考过程", comment: "")
        }

        guard let reasoningSummaryText else { return baseTitle }
        return String(format: NSLocalizedString("%@：%@", comment: ""), baseTitle, reasoningSummaryText)
    }
}

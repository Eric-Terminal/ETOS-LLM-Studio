// ============================================================================
// WatchChatBubbleContentSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡的正文、附件与思考区渲染逻辑。
// ============================================================================

import Foundation
import MarkdownUI
import Shared
import SwiftUI
import AVFoundation

extension ChatBubble {
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
        let progressBinding = Binding<Double>(
            get: { isCurrentFile ? audioPlayer.progress : 0 },
            set: { audioPlayer.seek(toProgress: $0, fileName: fileName) }
        )

        VStack(alignment: .leading, spacing: 4) {
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

            if isCurrentFile && audioPlayer.duration > 0 {
                ProgressView(value: audioPlayer.progress)
                    .progressViewStyle(.linear)
                    .tint(foregroundColor)
                    .focusable(true)
                    .digitalCrownRotation(progressBinding, from: 0, through: 1, by: 0.01, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)

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
    func fileAttachmentsView(fileNames: [String], isOutgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(fileNames, id: \.self) { fileName in
                Button {
                    loadFilePreview(fileName)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                            .etFont(.system(size: 13, weight: .semibold))
                            .foregroundStyle(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8))

                        Text(fileName)
                            .etFont(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(resolvedTextColor(default: .primary))

                        Spacer(minLength: 4)

                        Image(systemName: "eye")
                            .etFont(.system(size: 9, weight: .semibold))
                            .foregroundStyle(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("预览", comment: ""))
            }
        }
        .frame(maxWidth: bubbleMaxWidth, alignment: isOutgoing ? .trailing : .leading)
    }

    func loadFilePreview(_ fileName: String) {
        Task {
            let payload = await Task.detached(priority: .userInitiated) {
                FileAttachmentPreviewLoader.load(fileName: fileName)
            }.value
            await MainActor.run {
                filePreview = payload
            }
        }
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

    func reasoningElapsedSeconds(referenceDate: Date) -> Int? {
        let elapsed: TimeInterval
        if let reasoningStartedAt {
            let finishedAt = reasoningCompletedAt ?? referenceDate
            elapsed = max(0, finishedAt.timeIntervalSince(reasoningStartedAt))
        } else if let fallbackReasoningDuration {
            elapsed = max(0, fallbackReasoningDuration)
        } else {
            return nil
        }
        if elapsed == 0 {
            return 0
        }
        return max(1, Int(elapsed.rounded(.down)))
    }

    @ViewBuilder
    func toolCallsInlineView(_ toolCalls: [InternalToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(toolCalls, id: \.id) { toolCall in
                let label = toolDisplayLabel(for: toolCall.toolName)
                ToolCallDisclosureRow(
                    label: label,
                    arguments: toolCall.arguments,
                    customTextColor: customTextColorOverride
                )
            }
        }
        .padding(.bottom, 5)
    }

    private struct ToolCallDisclosureRow: View {
        let label: String
        let arguments: String
        let customTextColor: Color?
        @State private var isExpanded = true

        private var trimmedArguments: String {
            WatchToolArgumentFormatter.normalized(arguments)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                if trimmedArguments.isEmpty {
                    toolHeader
                } else {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        toolHeader
                    }
                    .buttonStyle(.plain)
                }

                if !trimmedArguments.isEmpty, isExpanded {
                    CappedScrollableText(
                        text: trimmedArguments,
                        maxHeight: 120,
                        font: .caption2,
                        foreground: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8)
                    )
                }
            }
            .padding(.leading, 4)
        }

        private var toolHeader: some View {
            HStack(spacing: 4) {
                Text(String(format: NSLocalizedString("调用：%@", comment: ""), label))
                    .etFont(.footnote)
                    .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.9))
                    .lineLimit(1)
                if !trimmedArguments.isEmpty {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .etFont(.caption)
                        .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.9))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
        }

        private func resolvedSecondaryTextColor(default defaultColor: Color, customOpacity: Double) -> Color {
            guard let customTextColor else {
                return defaultColor
            }
            return customTextColor.opacity(customOpacity)
        }
    }

    @ViewBuilder
    func toolResultsDisclosureView(
        _ toolCalls: [InternalToolCall],
        resultText: String,
        isPending: Bool,
        expanded: Binding<Bool>? = nil
    ) -> some View {
        let toolNames = toolCalls.map { toolDisplayLabel(for: $0.toolName) }
        let expansion = expanded ?? $isToolCallsExpanded
        let summaries: [String] = enableExperimentalToolResultDisplay
            ? toolCalls
                .map { call -> String in
                    if let payload = toolWidgetPayload(for: call, resultText: resultText) {
                        if let title = payload.title,
                           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return String(format: NSLocalizedString("可视化 Widget · %@", comment: ""), title)
                    }
                    return NSLocalizedString("可视化 Widget", comment: "")
                    }
                    return toolResultDisplayModel(for: (call.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)).summaryText
                }
                .filter { !$0.isEmpty }
            : []
        VStack(alignment: .leading, spacing: 5) {
            if isPending {
                HStack {
                    ShimmeringText(
                        text: String(format: NSLocalizedString("结果：%@", comment: ""), toolNames.joined(separator: ", ")),
                        font: .footnote,
                        baseColor: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8),
                        highlightColor: resolvedTextColor(default: .primary.opacity(0.85))
                    )
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .etFont(.caption)
                        .foregroundColor(resolvedSecondaryTextColor(default: .secondary.opacity(0.6), customOpacity: 0.6))
                }
                .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8))
            } else {
                Button(action: {
                    withAnimation {
                        expansion.wrappedValue.toggle()
                    }
                }) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(String(format: NSLocalizedString("结果：%@", comment: ""), toolNames.joined(separator: ", ")))
                                .etFont(.footnote)
                                .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.9))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: expansion.wrappedValue ? "chevron.down" : "chevron.right")
                                .etFont(.caption)
                        }
                        if !summaries.isEmpty {
                            Text(summaries.joined(separator: " · "))
                                .etFont(.caption2)
                                .foregroundColor(resolvedSecondaryTextColor(default: .secondary.opacity(0.9), customOpacity: 0.9))
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.9))
                }
                .buttonStyle(.plain)
            }

            if expansion.wrappedValue && !isPending {
                ForEach(toolCalls, id: \.id) { toolCall in
                    toolResultContent(for: toolCall, resultText: resultText)
                }
            }
        }
        .padding(.bottom, 5)
    }

    @ViewBuilder
    func toolResultContent(for toolCall: InternalToolCall, resultText: String) -> some View {
        if let payload = toolWidgetPayload(for: toolCall, resultText: resultText) {
            widgetToolResultContent(for: toolCall, payload: payload, resultText: resultText)
        } else if enableExperimentalToolResultDisplay {
            experimentalToolResultContent(for: toolCall, resultText: resultText)
        } else {
            legacyToolResultContent(for: toolCall, resultText: resultText)
        }
    }

    func toolWidgetPayload(for toolCall: InternalToolCall, resultText: String) -> ToolWidgetPayload? {
        if let payload = ToolWidgetPayloadParser.parse(from: toolCall.arguments) {
            return payload
        }

        let rawResult = (toolCall.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)
        if let payload = ToolWidgetPayloadParser.parse(from: rawResult) {
            return payload
        }

        return ToolWidgetPayloadParser.parse(from: resultText)
    }

    func widgetToolResultContent(
        for toolCall: InternalToolCall,
        payload: ToolWidgetPayload,
        resultText: String
    ) -> some View {
        let display = toolResultDisplayModel(for: (toolCall.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines))
        let label = toolDisplayLabel(for: toolCall.toolName)
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .etFont(.caption2.weight(.semibold))
                .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.85))
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("检测到可视化 Widget", comment: ""))
                    .etFont(.caption2.weight(.medium))
                if let title = payload.title,
                   !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(String(format: NSLocalizedString("标题：%@", comment: ""), title))
                        .etFont(.caption2)
                }
                Text(NSLocalizedString("请在 iPhone 端查看完整渲染效果。", comment: ""))
                    .etFont(.caption2)
            }
            .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.82))
            .padding(.vertical, 2)

            if display.shouldShowRawSection {
                toolResultSection(
                    title: "原始返回",
                    text: display.rawDisplayText,
                    font: .system(.caption2, design: .monospaced),
                    maxHeight: 90
                )
            }
        }
        .padding(.leading, 4)
    }

    func experimentalToolResultContent(for toolCall: InternalToolCall, resultText: String) -> some View {
        let display = toolResultDisplayModel(for: (toolCall.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines))
        let label = toolDisplayLabel(for: toolCall.toolName)
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .etFont(.caption2.weight(.semibold))
                .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.85))
            if display.shouldShowRawSection {
                toolResultSection(
                    title: "原始返回",
                    text: display.rawDisplayText,
                    font: .system(.caption2, design: .monospaced),
                    maxHeight: 90
                )
            } else if let primaryContentText = display.primaryContentText,
                      !primaryContentText.isEmpty {
                toolResultSection(
                    title: "结果内容",
                    text: primaryContentText,
                    font: .caption2,
                    maxHeight: 110
                )
            }
        }
        .padding(.leading, 4)
    }

    func legacyToolResultContent(for toolCall: InternalToolCall, resultText: String) -> some View {
        let result = (toolCall.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)
        let label = toolDisplayLabel(for: toolCall.toolName)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .etFont(.caption2.weight(.semibold))
                .foregroundColor(resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.85))
            if !result.isEmpty {
                CappedScrollableText(
                    text: result,
                    maxHeight: 120,
                    font: .caption2,
                    foreground: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8)
                )
            }
        }
        .padding(.leading, 4)
    }

    func toolResultDisplayModel(for rawResult: String) -> MCPToolResultDisplayModel {
        MCPToolResultFormatter.displayModel(from: rawResult)
    }

    func toolResultSection(
        title: String,
        text: String,
        font: Font,
        maxHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NSLocalizedString(title, comment: "工具结果小节标题"))
                .etFont(.caption2.weight(.semibold))
                .foregroundColor(resolvedSecondaryTextColor(default: .secondary.opacity(0.9), customOpacity: 0.9))
            CappedScrollableText(
                text: text,
                maxHeight: maxHeight,
                font: font,
                foreground: resolvedSecondaryTextColor(default: .secondary, customOpacity: 0.8)
            )
        }
    }

    private struct CappedScrollableText: View {
        let text: String
        let maxHeight: CGFloat
        let font: Font
        let foreground: Color
        @State private var measuredHeight: CGFloat = 0

        var body: some View {
            ScrollView {
                Text(text)
                    .etFont(font)
                    .foregroundColor(foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TextHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            .frame(height: resolvedHeight)
            .onPreferenceChange(TextHeightKey.self) { measuredHeight = $0 }
        }

        private var resolvedHeight: CGFloat {
            guard measuredHeight > 0 else { return maxHeight }
            return min(measuredHeight, maxHeight)
        }
    }

    private struct TextHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
}

struct WatchFileAttachmentPreviewSheet: View {
    let payload: FileAttachmentPreviewPayload

    var body: some View {
        NavigationStack {
            Group {
                if let text = payload.text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(payload.fileName)
                                    .etFont(.caption2.weight(.semibold))
                                    .lineLimit(2)

                                Text(StorageUtility.formatSize(payload.fileSize))
                                    .etFont(.system(size: 9))
                                    .foregroundStyle(.secondary)

                                Text(String(format: NSLocalizedString("%d 行", comment: "Watch file preview line count"), payload.lineCount))
                                    .etFont(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }

                            Text(text)
                                .etFont(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.questionmark")
                            .etFont(.title3)
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("无法预览", comment: ""))
                            .etFont(.caption.weight(.semibold))
                        Text(payload.errorMessage ?? NSLocalizedString("无法读取此文件的内容。", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("文件预览", comment: "Watch file attachment preview title"))
        }
    }
}

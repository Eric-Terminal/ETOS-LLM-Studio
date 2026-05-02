// ============================================================================
// ChatBubble+ToolResultsAndContainers.swift
// ============================================================================
// watchOS 聊天气泡的工具结果展示、权限提示与容器背景样式。
// ============================================================================

import SwiftUI
import WatchKit
import Foundation
import MarkdownUI
import Shared
import AVFoundation
import Combine

extension ChatBubble {

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

    struct ToolCallDisclosureRow: View {
        let label: String
        let arguments: String
        let customTextColor: Color?
        @State var isExpanded = true

        var trimmedArguments: String {
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

        var toolHeader: some View {
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

        func resolvedSecondaryTextColor(default defaultColor: Color, customOpacity: Double) -> Color {
            guard let customTextColor else {
                return defaultColor
            }
            return customTextColor.opacity(customOpacity)
        }
    }

    func toolPermissionInlineView(
        request: ToolPermissionRequest,
        onDecision: @escaping (ToolPermissionDecision) -> Void
    ) -> some View {
        ToolPermissionBubble(
            request: request,
            enableBackground: enableBackground,
            enableLiquidGlass: enableLiquidGlass,
            onDecision: onDecision
        )
            .padding(.bottom, 5)
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

    struct CappedScrollableText: View {
        let text: String
        let maxHeight: CGFloat
        let font: Font
        let foreground: Color
        @State var measuredHeight: CGFloat = 0

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

        var resolvedHeight: CGFloat {
            guard measuredHeight > 0 else { return maxHeight }
            return min(measuredHeight, maxHeight)
        }
    }

    struct TextHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
    
    // MARK: - 回退样式
    
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
                                    ? Color.red.opacity(0.5)
                                    : resolvedAssistantBubbleColorOverride.map {
                                        enableBackground ? $0.opacity(0.5) : $0
                                    }
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
}

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
// MARK: - 思考过程折叠视图（性能优化）

/// 独立的思考过程视图，避免长文本导致父视图重复布局
/// 使用 Equatable 优化：只有在 reasoning 或 isExpanded 变化时才重新渲染
struct ReasoningDisclosureView: View, Equatable {
    let reasoning: String
    let preparedReasoningContent: ETPreparedMarkdownRenderPayload?
    @Binding var isExpanded: Bool
    let isPreviewing: Bool
    let isOutgoing: Bool
    let usesNoBubbleStyle: Bool
    let isShimmering: Bool
    let customTextColor: Color?
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool
    let enableMathRendering: Bool
    let reasoningStartedAt: Date?
    let reasoningCompletedAt: Date?
    let reasoningSummary: String?
    
    static func == (lhs: ReasoningDisclosureView, rhs: ReasoningDisclosureView) -> Bool {
        lhs.reasoning == rhs.reasoning
            && lhs.preparedReasoningContent == rhs.preparedReasoningContent
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isPreviewing == rhs.isPreviewing
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.usesNoBubbleStyle == rhs.usesNoBubbleStyle
            && lhs.isShimmering == rhs.isShimmering
            && Self.colorSignature(lhs.customTextColor) == Self.colorSignature(rhs.customTextColor)
            && lhs.enableMarkdown == rhs.enableMarkdown
            && lhs.enableAdvancedRenderer == rhs.enableAdvancedRenderer
            && lhs.enableMathRendering == rhs.enableMathRendering
            && lhs.reasoningStartedAt == rhs.reasoningStartedAt
            && lhs.reasoningCompletedAt == rhs.reasoningCompletedAt
            && lhs.reasoningSummary == rhs.reasoningSummary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let baseColor: Color = resolvedSecondaryTextColor(
                default: usesNoBubbleStyle
                    ? .secondary
                    : (isOutgoing ? Color.white.opacity(0.9) : Color.secondary),
                customTextColor: customTextColor,
                customOpacity: 0.9
            )
            let highlightColor: Color = resolvedTextColor(
                default: usesNoBubbleStyle
                    ? .primary.opacity(0.85)
                    : (isOutgoing ? Color.white : Color.primary.opacity(0.85)),
                customTextColor: customTextColor,
                customOpacity: 0.92
            )
            // 点击区域：标题行
            Button {
                if isPreviewing {
                    isExpanded = true
                } else {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .etFont(.system(size: 12))
                        .foregroundStyle(baseColor)
                        .padding(.top, 2)
                    headerTitleView(baseColor: baseColor, highlightColor: highlightColor)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .etFont(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isFullyExpanded ? 90 : 0))
                        .foregroundStyle(baseColor)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if shouldShowContent {
                let contentColor = resolvedSecondaryTextColor(
                    default: usesNoBubbleStyle
                        ? Color.secondary
                        : (isOutgoing ? Color.white.opacity(0.85) : Color.secondary),
                    customTextColor: customTextColor,
                    customOpacity: 0.85
                )
                ReasoningPreviewContent(
                    isPreviewing: isPreviewing,
                    maxHeight: 118,
                    contentID: reasoning
                ) {
                    ReasoningMarkdownContentView(
                        reasoning: reasoning,
                        preparedReasoningContent: preparedReasoningContent,
                        enableMarkdown: enableMarkdown,
                        enableAdvancedRenderer: enableAdvancedRenderer,
                        enableMathRendering: enableMathRendering,
                        isOutgoing: isOutgoing,
                        textColor: contentColor,
                        font: .subheadline
                    )
                    .padding(.top, 8)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: isFullyExpanded)
        .animation(.easeInOut(duration: 0.2), value: isPreviewing)
    }

    var isFullyExpanded: Bool {
        isExpanded && !isPreviewing
    }

    var shouldShowContent: Bool {
        isExpanded || isPreviewing
    }

    func resolvedTextColor(default defaultColor: Color, customTextColor: Color?, customOpacity: Double) -> Color {
        if let customTextColor {
            return customTextColor.opacity(customOpacity)
        }
        return defaultColor
    }

    func resolvedSecondaryTextColor(default defaultColor: Color, customTextColor: Color?, customOpacity: Double) -> Color {
        resolvedTextColor(default: defaultColor, customTextColor: customTextColor, customOpacity: customOpacity)
    }

    @ViewBuilder
    func headerTitleView(baseColor: Color, highlightColor: Color) -> some View {
        if let reasoningStartedAt, reasoningCompletedAt == nil {
            TimelineView(.periodic(from: reasoningStartedAt, by: 1)) { context in
                headerTitleLabel(
                    title: reasoningHeaderTitle(referenceDate: context.date),
                    baseColor: baseColor,
                    highlightColor: highlightColor
                )
            }
        } else {
            headerTitleLabel(
                title: reasoningHeaderTitle(referenceDate: reasoningCompletedAt ?? Date()),
                baseColor: baseColor,
                highlightColor: highlightColor
            )
        }
    }

    @ViewBuilder
    func headerTitleLabel(title: String, baseColor: Color, highlightColor: Color) -> some View {
        if isShimmering {
            ShimmeringText(
                text: title,
                font: .subheadline.weight(.medium),
                baseColor: baseColor,
                highlightColor: highlightColor
            )
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(title)
                .etFont(.subheadline.weight(.medium))
                .foregroundStyle(baseColor)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func reasoningHeaderTitle(referenceDate: Date) -> String {
        if isPreviewing,
           reasoningCompletedAt == nil,
           let thinkingTitle = preparedReasoningContent?.thinkingTitle,
           !thinkingTitle.isEmpty {
            return thinkingTitle
        }

        let baseTitle: String
        if let elapsedSeconds = reasoningElapsedSeconds(referenceDate: referenceDate) {
            baseTitle = String(format: NSLocalizedString("已经思考%d秒", comment: ""), elapsedSeconds)
        } else {
            baseTitle = NSLocalizedString("思考过程", comment: "")
        }

        guard let summary = reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return baseTitle
        }
        return String(format: NSLocalizedString("%@：%@", comment: ""), baseTitle, summary)
    }

    func reasoningElapsedSeconds(referenceDate: Date) -> Int? {
        guard let reasoningStartedAt else { return nil }
        let finishedAt = reasoningCompletedAt ?? referenceDate
        let elapsed = max(0, finishedAt.timeIntervalSince(reasoningStartedAt))
        if elapsed == 0 {
            return 0
        }
        return max(1, Int(elapsed.rounded(.down)))
    }

    static func colorSignature(_ color: Color?) -> String? {
        guard let color else { return nil }
        return ChatAppearanceColorCodec.hexRGBA(from: color)
    }
}


// MARK: - 工具调用摘要行
struct ToolCallSummaryBubbleRow: View {
    let label: String
    let statusTitle: String
    let statusIconName: String
    let statusColor: Color
    let showPendingGuidance: Bool
    let isOutgoing: Bool
    let customTextColor: Color?

    var baseForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.92)
        }
        return isOutgoing ? Color.white.opacity(0.92) : Color.secondary
    }

    var secondaryForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return isOutgoing ? Color.white.opacity(0.78) : Color.secondary.opacity(0.9)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .etFont(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                if showPendingGuidance {
                    ToolCallPendingGuidanceLabel(text: label, color: baseForegroundColor)
                } else {
                    Text(label)
                        .etFont(.subheadline.weight(.medium))
                        .foregroundStyle(baseForegroundColor)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: statusIconName)
                        .etFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text(statusTitle)
                        .etFont(.caption)
                        .foregroundStyle(secondaryForegroundColor)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .etFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(secondaryForegroundColor)
        }
        .contentShape(Rectangle())
    }
}


struct ToolPermissionInlineView: View {
    let request: ToolPermissionRequest
    let onDecision: (ToolPermissionDecision) -> Void
    @ObservedObject var permissionCenter = ToolPermissionCenter.shared

    var countdownText: String? {
        guard let remaining = permissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return String(format: NSLocalizedString("将在 %ds 后自动允许", comment: ""), remaining)
    }

    var autoApproveToggleLabel: String {
        permissionCenter.isAutoApproveDisabled(for: request.toolName)
            ? NSLocalizedString("恢复该工具自动批准", comment: "")
            : NSLocalizedString("关闭该工具自动批准", comment: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(NSLocalizedString("允许", comment: "")) {
                    onDecision(.allowOnce)
                }
                .buttonStyle(.borderedProminent)

                Button(NSLocalizedString("拒绝", comment: ""), role: .destructive) {
                    onDecision(.deny)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button(NSLocalizedString("补充提示", comment: "")) {
                    onDecision(.supplement)
                }
                .buttonStyle(.bordered)

                Button(NSLocalizedString("保持允许", comment: "")) {
                    onDecision(.allowForTool)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button(NSLocalizedString("完全权限", comment: "")) {
                    onDecision(.allowAll)
                }
                .buttonStyle(.bordered)

                if permissionCenter.autoApproveEnabled {
                    Button(autoApproveToggleLabel) {
                        let shouldDisable = !permissionCenter.isAutoApproveDisabled(for: request.toolName)
                        permissionCenter.setAutoApproveDisabled(shouldDisable, for: request.toolName)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let countdownText {
                Text(countdownText)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }
}


struct ToolResultsDisclosureView: View, Equatable {
    let toolCalls: [InternalToolCall]
    let resultText: String
    @Binding var isExpanded: Bool
    let isOutgoing: Bool
    let isPending: Bool
    let enableExperimentalToolResultDisplay: Bool
    let customTextColor: Color?
    
    static func == (lhs: ToolResultsDisclosureView, rhs: ToolResultsDisclosureView) -> Bool {
        lhs.toolCalls.map(\.id) == rhs.toolCalls.map(\.id)
            && lhs.isExpanded == rhs.isExpanded
            && lhs.isOutgoing == rhs.isOutgoing
            && lhs.resultText == rhs.resultText
            && lhs.isPending == rhs.isPending
            && lhs.enableExperimentalToolResultDisplay == rhs.enableExperimentalToolResultDisplay
            && Self.colorSignature(lhs.customTextColor) == Self.colorSignature(rhs.customTextColor)
    }

    func displayName(for toolName: String) -> String {
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

    var headerForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.9)
        }
        return isOutgoing ? Color.white.opacity(0.9) : Color.secondary
    }

    var summaryForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.72)
        }
        return isOutgoing ? Color.white.opacity(0.72) : Color.secondary.opacity(0.9)
    }

    var sectionForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return isOutgoing ? Color.white.opacity(0.78) : Color.secondary
    }

    var sectionBackgroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(isOutgoing ? 0.15 : 0.1)
        }
        return isOutgoing ? Color.white.opacity(0.15) : Color.secondary.opacity(0.1)
    }

    func resolvedResult(for call: InternalToolCall) -> String {
        (call.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func displayModel(for call: InternalToolCall) -> MCPToolResultDisplayModel {
        MCPToolResultFormatter.displayModel(from: resolvedResult(for: call))
    }

    var disclosureSummaryText: String? {
        guard enableExperimentalToolResultDisplay else { return nil }
        let summaries = toolCalls
            .map { call -> String in
                if let payload = widgetPayload(for: call) {
                    if let title = payload.title,
                       !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return String(format: NSLocalizedString("可视化 Widget · %@", comment: ""), title)
                    }
                    return NSLocalizedString("可视化 Widget", comment: "")
                }
                return displayModel(for: call).summaryText
            }
            .filter { !$0.isEmpty }

        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: " · ")
    }
    
    var body: some View {
        let toolNames = toolCalls.map { displayName(for: $0.toolName) }
        VStack(alignment: .leading, spacing: 0) {
            if isPending {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .etFont(.system(size: 12))
                    ShimmeringText(
                        text: String(format: NSLocalizedString("结果：%@", comment: ""), toolNames.joined(separator: ", ")),
                        font: .subheadline.weight(.medium),
                        baseColor: headerForegroundColor,
                        highlightColor: customTextColor?.opacity(0.95) ?? (isOutgoing ? Color.white : Color.primary.opacity(0.85))
                    )
                    .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .etFont(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOutgoing ? Color.white.opacity(0.4) : Color.secondary.opacity(0.6))
                }
                .foregroundStyle(headerForegroundColor)
                .contentShape(Rectangle())
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver")
                                .etFont(.system(size: 12))
                            Text(String(format: NSLocalizedString("结果：%@", comment: ""), toolNames.joined(separator: ", ")))
                                .etFont(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .etFont(.system(size: 12, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        if let disclosureSummaryText {
                            Text(disclosureSummaryText)
                                .etFont(.caption)
                                .foregroundStyle(summaryForegroundColor)
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .foregroundStyle(headerForegroundColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            
            if isExpanded && !isPending {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(toolCalls, id: \.id) { call in
                        toolResultContent(for: call)
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    @ViewBuilder
    func toolResultContent(for call: InternalToolCall) -> some View {
        if let payload = widgetPayload(for: call) {
            widgetToolResultContent(for: call, payload: payload)
        } else if enableExperimentalToolResultDisplay {
            experimentalToolResultContent(for: call)
        } else {
            legacyToolResultContent(for: call)
        }
    }

    func widgetPayload(for call: InternalToolCall) -> ToolWidgetPayload? {
        if let payload = ToolWidgetPayloadParser.parse(from: call.arguments) {
            return payload
        }

        let resolved = resolvedResult(for: call)
        if let payload = ToolWidgetPayloadParser.parse(from: resolved) {
            return payload
        }

        if let payload = ToolWidgetPayloadParser.parse(from: resultText) {
            return payload
        }

        return nil
    }

    @ViewBuilder
    func widgetToolResultContent(for call: InternalToolCall, payload: ToolWidgetPayload) -> some View {
        if call.toolName == AppToolKind.showWidget.toolName {
            ToolWidgetRendererCard(payload: payload)
        } else {
        let display = displayModel(for: call)
        let label = displayName(for: call.toolName)
            VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .etFont(.caption.weight(.semibold))
            ToolWidgetRendererCard(payload: payload)
            if display.shouldShowRawSection {
                Divider()
                    .background(sectionBackgroundColor.opacity(0.7))
                toolResultSection(
                    title: "原始返回",
                    text: display.rawDisplayText,
                    font: .system(.caption, design: .monospaced),
                    enableSelection: true
                )
            }
        }
        .foregroundStyle(sectionForegroundColor)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionBackgroundColor)
        )
        }
    }

    func experimentalToolResultContent(for call: InternalToolCall) -> some View {
        let display = displayModel(for: call)
        let label = displayName(for: call.toolName)
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .etFont(.caption.weight(.semibold))
            if let primaryContentText = display.primaryContentText,
               !primaryContentText.isEmpty {
                toolResultSection(
                    title: display.shouldShowRawSection ? "主要内容" : "结果内容",
                    text: primaryContentText,
                    font: .caption,
                    enableSelection: true
                )
            }
            if display.shouldShowRawSection {
                if display.primaryContentText != nil {
                    Divider()
                        .background(sectionBackgroundColor.opacity(0.7))
                }
                toolResultSection(
                    title: "原始返回",
                    text: display.rawDisplayText,
                    font: .system(.caption, design: .monospaced),
                    enableSelection: true
                )
            }
        }
        .foregroundStyle(sectionForegroundColor)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionBackgroundColor)
        )
    }

    func legacyToolResultContent(for call: InternalToolCall) -> some View {
        let result = resolvedResult(for: call)
        let label = displayName(for: call.toolName)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .etFont(.caption.weight(.semibold))
            if !result.isEmpty {
                CappedScrollableText(
                    text: result,
                    maxHeight: 200,
                    font: .caption,
                    foreground: sectionForegroundColor,
                    enableSelection: true
                )
            }
        }
        .foregroundStyle(sectionForegroundColor)
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(sectionBackgroundColor)
        )
    }

    func toolResultSection(
        title: String,
        text: String,
        font: Font,
        enableSelection: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString(title, comment: "工具结果小节标题"))
                .etFont(.caption2.weight(.semibold))
                .foregroundStyle(sectionForegroundColor.opacity(0.85))
            CappedScrollableText(
                text: text,
                maxHeight: 200,
                font: font,
                foreground: sectionForegroundColor,
                enableSelection: enableSelection
            )
        }
    }

    static func colorSignature(_ color: Color?) -> String? {
        guard let color else { return nil }
        return ChatAppearanceColorCodec.hexRGBA(from: color)
    }
}


struct ToolWidgetRendererCard: View {
    let payload: ToolWidgetPayload

    @Environment(\.colorScheme) var colorScheme
    @State var renderedHeight: CGFloat = 180
    @State var hasRendered = false

    var loadingText: String {
        payload.loadingMessages.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (payload.loadingMessages.first ?? NSLocalizedString("正在渲染 Widget…", comment: ""))
            : NSLocalizedString("正在渲染 Widget…", comment: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = payload.title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ToolWidgetWebView(
                    widgetCode: payload.widgetCode,
                    colorScheme: colorScheme,
                    availableWidth: max(1, floor(proxy.size.width)),
                    renderedHeight: $renderedHeight,
                    hasRendered: $hasRendered
                )
            }
            .frame(height: max(120, renderedHeight))
            .overlay {
                if !hasRendered {
                    ProgressView(loadingText)
                        .progressViewStyle(.circular)
                        .tint(.secondary)
                        .etFont(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            )
        }
    }
}

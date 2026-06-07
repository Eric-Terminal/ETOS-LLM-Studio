// ============================================================================
// ChatBubbleToolResults.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的工具结果详情、Widget 渲染与文本展开视图。
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

struct ToolPermissionInlineView: View {
    let request: ToolPermissionRequest
    let onDecision: (ToolPermissionDecision) -> Void
    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    private var countdownText: String? {
        guard let remaining = permissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return String(format: NSLocalizedString("将在 %ds 后自动允许", comment: ""), remaining)
    }

    private var autoApproveBinding: Binding<Bool> {
        Binding(
            get: { !permissionCenter.isAutoApproveDisabled(for: request.toolName) },
            set: { isEnabled in
                permissionCenter.setAutoApproveDisabled(!isEnabled, for: request.toolName)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let countdownText {
                Label(countdownText, systemImage: "timer")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                onDecision(.allowOnce)
            } label: {
                Label(NSLocalizedString("允许一次", comment: ""), systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button(role: .destructive) {
                onDecision(.deny)
            } label: {
                Label(NSLocalizedString("拒绝", comment: ""), systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)

            toolDecisionButton(
                title: NSLocalizedString("补充提示", comment: ""),
                systemImage: "text.badge.plus",
                tint: .blue,
                decision: .supplement
            )
            toolDecisionButton(
                title: NSLocalizedString("保持允许", comment: ""),
                systemImage: "checkmark.shield.fill",
                tint: .teal,
                decision: .allowForTool
            )
            toolDecisionButton(
                title: NSLocalizedString("完全权限", comment: ""),
                systemImage: "shield.fill",
                tint: .purple,
                decision: .allowAll
            )

            if permissionCenter.autoApproveEnabled {
                Toggle(NSLocalizedString("允许该工具自动批准", comment: ""), isOn: autoApproveBinding)

                if permissionCenter.isAutoApproveDisabled(for: request.toolName) {
                    Text(NSLocalizedString("该工具已从自动批准名单中排除。", comment: ""))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    private func toolDecisionButton(
        title: String,
        systemImage: String,
        tint: Color,
        decision: ToolPermissionDecision
    ) -> some View {
        Button {
            onDecision(decision)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(tint)
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

    private func displayName(for toolName: String) -> String {
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

    private var headerForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.9)
        }
        return isOutgoing ? Color.white.opacity(0.9) : Color.secondary
    }

    private var summaryForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.72)
        }
        return isOutgoing ? Color.white.opacity(0.72) : Color.secondary.opacity(0.9)
    }

    private var sectionForegroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(0.78)
        }
        return isOutgoing ? Color.white.opacity(0.78) : Color.secondary
    }

    private var sectionBackgroundColor: Color {
        if let customTextColor {
            return customTextColor.opacity(isOutgoing ? 0.15 : 0.1)
        }
        return isOutgoing ? Color.white.opacity(0.15) : Color.secondary.opacity(0.1)
    }

    private func resolvedResult(for call: InternalToolCall) -> String {
        (call.result ?? resultText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func displayModel(for call: InternalToolCall) -> MCPToolResultDisplayModel {
        MCPToolResultFormatter.displayModel(from: resolvedResult(for: call))
    }

    private var disclosureSummaryText: String? {
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
    private func toolResultContent(for call: InternalToolCall) -> some View {
        if let payload = widgetPayload(for: call) {
            widgetToolResultContent(for: call, payload: payload)
        } else if enableExperimentalToolResultDisplay {
            experimentalToolResultContent(for: call)
        } else {
            legacyToolResultContent(for: call)
        }
    }

    private func widgetPayload(for call: InternalToolCall) -> ToolWidgetPayload? {
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
    private func widgetToolResultContent(for call: InternalToolCall, payload: ToolWidgetPayload) -> some View {
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

    private func experimentalToolResultContent(for call: InternalToolCall) -> some View {
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

    private func legacyToolResultContent(for call: InternalToolCall) -> some View {
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

    private func toolResultSection(
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

    private static func colorSignature(_ color: Color?) -> String? {
        guard let color else { return nil }
        return ChatAppearanceColorCodec.hexRGBA(from: color)
    }
}

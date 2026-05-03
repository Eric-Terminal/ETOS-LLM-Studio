// ============================================================================
// WatchChatBubbleDetailSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡的工具调用状态、详情面板与操作辅助逻辑。
// ============================================================================

import Foundation
import Shared
import SwiftUI

struct ToolCallDetailSheetItem: Identifiable, Equatable {
    let messageID: UUID
    let toolCallID: String
    let fallbackToolCall: InternalToolCall

    var id: String {
        "\(messageID.uuidString)-\(toolCallID)"
    }
}

enum ToolCallBubbleStatus: Equatable {
    case pendingApproval
    case running
    case finished
    case rejected

    var title: String {
        switch self {
        case .pendingApproval:
            return NSLocalizedString("等待审批", comment: "")
        case .running:
            return NSLocalizedString("执行中", comment: "")
        case .finished:
            return NSLocalizedString("已完成", comment: "")
        case .rejected:
            return NSLocalizedString("已拒绝", comment: "")
        }
    }

    var iconName: String {
        switch self {
        case .pendingApproval:
            return "hourglass"
        case .running:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .finished:
            return "checkmark.circle.fill"
        case .rejected:
            return "xmark.circle.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .pendingApproval:
            return .orange
        case .running:
            return .blue
        case .finished:
            return .green
        case .rejected:
            return .red
        }
    }
}

extension ChatBubble {
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

    func resolvedToolResultText(for call: InternalToolCall) -> String {
        let fallback = message.role == .tool ? message.content : ""
        return (call.result ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
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

    func shouldShowPendingGuidance(for call: InternalToolCall) -> Bool {
        activeToolPermissionRequest(for: call) != nil
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

    var toolCallAutoPresentationSignature: String {
        let callIDs = (message.toolCalls ?? []).map(\.id).joined(separator: "|")
        let activeRequestID = toolPermissionCenter.activeRequest?.id.uuidString ?? ""
        return "\(message.id.uuidString)#\(callIDs)#\(activeRequestID)"
    }

    func isDeniedToolResultText(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("denied")
            || normalized.contains("拒绝")
            || normalized.contains("拒絕")
            || normalized.contains("rejected")
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
}

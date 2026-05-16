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

        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundStyle(status.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName)
                                .etFont(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(status.title)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            if permissionRequest != nil {
                                Text(NSLocalizedString("等待你的审批后继续执行。", comment: ""))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Section(NSLocalizedString("工具参数", comment: "工具详情小节标题")) {
                    Text(argumentText)
                        .etFont(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if permissionRequest == nil {
                    Section(NSLocalizedString("工具结果", comment: "工具详情小节标题")) {
                        toolResultSheetContent(
                            status: status,
                            resultText: resultText,
                            displayModel: displayModel
                        )
                    }
                }

                if let permissionRequest {
                    Section(NSLocalizedString("审批操作", comment: "")) {
                        toolPermissionDecisionButton(
                            title: NSLocalizedString("允许一次", comment: ""),
                            systemImage: "checkmark.circle.fill",
                            tint: .green,
                            decision: .allowOnce
                        )
                        toolPermissionDecisionButton(
                            title: NSLocalizedString("拒绝", comment: ""),
                            systemImage: "xmark.circle.fill",
                            tint: .red,
                            role: .destructive,
                            decision: .deny
                        )
                        toolPermissionDecisionButton(
                            title: NSLocalizedString("补充提示", comment: ""),
                            systemImage: "text.badge.plus",
                            tint: .blue,
                            decision: .supplement
                        )
                        toolPermissionDecisionButton(
                            title: NSLocalizedString("保持允许", comment: ""),
                            systemImage: "checkmark.shield.fill",
                            tint: .teal,
                            decision: .allowForTool
                        )
                        toolPermissionDecisionButton(
                            title: NSLocalizedString("完全权限", comment: ""),
                            systemImage: "shield.fill",
                            tint: .purple,
                            decision: .allowAll
                        )
                    }

                    Section(NSLocalizedString("自动批准", comment: "")) {
                        Toggle(
                            NSLocalizedString("允许该工具自动批准", comment: ""),
                            isOn: toolAutoApproveBinding(for: permissionRequest)
                        )
                        .disabled(!toolPermissionCenter.autoApproveEnabled)

                        if let countdownText = toolPermissionCountdownText(for: permissionRequest) {
                            Label(countdownText, systemImage: "timer")
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if !toolPermissionCenter.autoApproveEnabled {
                            Text(NSLocalizedString("全局自动批准当前未开启。", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        } else if toolPermissionCenter.isAutoApproveDisabled(for: permissionRequest.toolName) {
                            Text(NSLocalizedString("该工具已从自动批准名单中排除。", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("调用工具", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "")) {
                        selectedToolCallDetailSheetItem = nil
                    }
                }
            }
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

    @ViewBuilder
    private func toolResultSheetContent(
        status: ToolCallBubbleStatus,
        resultText: String,
        displayModel: MCPToolResultDisplayModel
    ) -> some View {
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
                    Text(displayModel.rawDisplayText)
                        .etFont(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let primaryContent {
                    Text(primaryContent)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if canToggleRaw {
                    Button(showRawToolResultInDetailSheet ? NSLocalizedString("显示整理结果", comment: "") : NSLocalizedString("显示原文", comment: "")) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showRawToolResultInDetailSheet.toggle()
                        }
                    }
                }
            }
        } else {
            Text(resultText)
                .etFont(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func toolPermissionDecisionButton(
        title: String,
        systemImage: String,
        tint: Color,
        role: ButtonRole? = nil,
        decision: ToolPermissionDecision
    ) -> some View {
        Button(role: role) {
            resolveToolPermission(decision)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
        }
    }

    private func resolveToolPermission(_ decision: ToolPermissionDecision) {
        toolPermissionCenter.resolveActiveRequest(with: decision)
        selectedToolCallDetailSheetItem = nil
    }

    private func toolAutoApproveBinding(for request: ToolPermissionRequest) -> Binding<Bool> {
        Binding(
            get: { !toolPermissionCenter.isAutoApproveDisabled(for: request.toolName) },
            set: { isEnabled in
                toolPermissionCenter.setAutoApproveDisabled(!isEnabled, for: request.toolName)
            }
        )
    }

    private func toolPermissionCountdownText(for request: ToolPermissionRequest) -> String? {
        guard let remaining = toolPermissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return String(format: NSLocalizedString("将在 %ds 后自动允许", comment: ""), remaining)
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

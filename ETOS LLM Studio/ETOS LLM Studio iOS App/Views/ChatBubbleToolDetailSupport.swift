// ============================================================================
// ChatBubbleToolDetailSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡中的工具详情面板与详情文本处理逻辑。
// ============================================================================

import Foundation
import SwiftUI
import Shared

extension ChatBubble {
    struct ToolCallDetailSheetItem: Identifiable, Equatable {
        let messageID: UUID
        let toolCallID: String
        let fallbackToolCall: InternalToolCall

        var id: String {
            "\(messageID.uuidString)-\(toolCallID)"
        }
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
                toolDetailTopBar(
                    displayName: displayName,
                    status: status,
                    permissionRequest: permissionRequest
                )

                toolDetailSection(title: "工具参数") {
                    Text(argumentText)
                        .etFont(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if permissionRequest == nil {
                    toolDetailSection(title: "工具结果") {
                        toolResultSheetContent(
                            status: status,
                            resultText: resultText,
                            displayModel: displayModel
                        )
                    }
                }

                if let permissionRequest {
                    toolApprovalSection(for: permissionRequest)
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

    private func toolDetailTopBar(
        displayName: String,
        status: ToolCallBubbleStatus,
        permissionRequest: ToolPermissionRequest?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Spacer(minLength: 6)
                Button(NSLocalizedString("关闭", comment: "")) {
                    selectedToolCallDetailSheetItem = nil
                }
                .etFont(.footnote)
                .buttonStyle(.bordered)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(status.accentColor)
                    .etFont(.system(size: 15, weight: .semibold))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("调用工具", comment: ""))
                        .etFont(.headline)
                    Text(displayName)
                        .etFont(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status.title)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    if permissionRequest != nil {
                        Text(NSLocalizedString("等待你的审批后继续执行。", comment: ""))
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let permissionRequest,
                       let countdownText = toolPermissionCountdownText(for: permissionRequest) {
                        Label(countdownText, systemImage: "timer")
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func toolApprovalSection(for permissionRequest: ToolPermissionRequest) -> some View {
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
        .padding(.vertical, 2)
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

    @ViewBuilder
    private func toolResultSheetContent(
        status: ToolCallBubbleStatus,
        resultText: String,
        displayModel: MCPToolResultDisplayModel
    ) -> some View {
        if resultText.isEmpty {
            Text(status == .pendingApproval ? NSLocalizedString("等待你的审批后继续执行。", comment: "") : NSLocalizedString("暂无返回结果。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        } else if enableExperimentalToolResultDisplay {
            let primaryContent = displayModel.primaryContentText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasPrimaryContent = !(primaryContent ?? "").isEmpty
            let canToggleRaw = hasPrimaryContent && displayModel.shouldShowRawSection
            let showRaw = canToggleRaw && showRawToolResultInDetailSheet

            VStack(alignment: .leading, spacing: 8) {
                if showRaw || !hasPrimaryContent {
                    Text(displayModel.rawDisplayText)
                        .etFont(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let primaryContent {
                    Text(primaryContent)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if canToggleRaw {
                    Button(showRawToolResultInDetailSheet ? NSLocalizedString("显示整理结果", comment: "") : NSLocalizedString("显示原文", comment: "")) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showRawToolResultInDetailSheet.toggle()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            Text(resultText)
                .etFont(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
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
}

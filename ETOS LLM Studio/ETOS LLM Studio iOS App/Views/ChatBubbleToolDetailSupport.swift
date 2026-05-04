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

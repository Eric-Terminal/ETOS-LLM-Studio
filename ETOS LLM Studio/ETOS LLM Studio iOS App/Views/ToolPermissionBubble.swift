// ============================================================================
// ToolPermissionBubble.swift
// ============================================================================
// MCP 工具权限请求气泡
// - 显示工具名称与参数
// - 提供允许与更多操作
// ============================================================================

import SwiftUI
import ETOSCore
import UIKit

struct ToolPermissionBubble: View {
    let request: ToolPermissionRequest
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let onDecision: (ToolPermissionDecision) -> Void

    private var toolName: String {
        request.displayName ?? request.toolName
    }

    private var trimmedArguments: String {
        request.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bubbleShape: TelegramBubbleShape {
        TelegramBubbleShape(isOutgoing: false)
    }

    private var decisionRows: [(decision: ToolPermissionDecision, label: String, iconName: String, tint: Color)] {
        [
            (.allowOnce,    NSLocalizedString("允许",     comment: ""), "checkmark.circle.fill", .green),
            (.deny,         NSLocalizedString("拒绝",     comment: ""), "xmark.circle.fill",     .red),
            (.supplement,   NSLocalizedString("补充提示", comment: ""), "text.badge.plus",       .blue),
            (.allowForTool, NSLocalizedString("保持允许", comment: ""), "checkmark.shield.fill", .teal),
            (.allowAll,     NSLocalizedString("完全权限", comment: ""), "shield.fill",            .purple),
        ]
    }

    private var bubbleGradient: some ShapeStyle {
        let assistantOpacity = enableBackground ? 0.75 : 1.0
        let baseColor = enableBackground
            ? Color(uiColor: .secondarySystemBackground).opacity(assistantOpacity)
            : Color(uiColor: .systemBackground)
        return AnyShapeStyle(baseColor)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // 头部：工具名称与参数预览
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised.circle.fill")
                            .foregroundStyle(.orange)
                        Text(toolName)
                            .etFont(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    if !trimmedArguments.isEmpty {
                        Text(trimmedArguments)
                            .etFont(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Divider()
                    .padding(.horizontal, 4)

                // 决策选项行（仿 AskUserInput 逐行排列）
                ForEach(Array(decisionRows.enumerated()), id: \.offset) { index, row in
                    Button {
                        onDecision(row.decision)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: row.iconName)
                                .foregroundStyle(row.tint)
                                .frame(width: 22, alignment: .center)
                            Text(row.label)
                                .etFont(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < decisionRows.count - 1 {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
            .background(bubbleBackground)
            .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if enableLiquidGlass {
            if #available(iOS 26.0, *) {
                bubbleShape
                    .fill(bubbleGradient)
                    .glassEffect(.clear, in: bubbleShape)
                    .clipShape(bubbleShape)
            } else {
                bubbleShape
                    .fill(bubbleGradient)
            }
        } else {
            bubbleShape
                .fill(bubbleGradient)
        }
    }
}

struct GlobalToolPermissionSheet: View {
    let request: ToolPermissionRequest
    let onDecision: (ToolPermissionDecision) -> Void

    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    private var toolName: String {
        request.displayName ?? request.toolName
    }

    private var argumentText: String {
        prettyPrintedJSONOrRaw(request.arguments)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(toolName)
                                .font(.headline)
                            Text(NSLocalizedString("等待你的审批后继续执行。", comment: ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let countdownText {
                                Text(countdownText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "hand.raised.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section(NSLocalizedString("工具参数", comment: "Tool detail arguments section title")) {
                    Text(argumentText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section(NSLocalizedString("审批操作", comment: "")) {
                    ToolPermissionInlineView(request: request, onDecision: onDecision)
                }
            }
            .navigationTitle(NSLocalizedString("调用工具", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var countdownText: String? {
        guard let remaining = permissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return String(format: NSLocalizedString("将在 %ds 后自动允许", comment: ""), remaining)
    }

    private func prettyPrintedJSONOrRaw(_ raw: String) -> String {
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

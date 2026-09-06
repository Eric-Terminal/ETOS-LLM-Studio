// ============================================================================
// ToolPermissionBubble.swift
// ============================================================================
// watchOS 工具审批卡片
// - 主卡片平铺全部审批动作
// - 参数预览会优先做 JSON 格式化与常见实体反转义
// ============================================================================

import SwiftUI
import ETOSCore
import Foundation

enum WatchToolArgumentFormatter {
    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let prettyPrinted = prettyPrintedJSON(from: trimmed) ?? trimmed
        return decodeCommonEntities(in: prettyPrinted)
    }

    static func preview(_ raw: String, maxLength: Int = 72) -> String? {
        let normalized = normalized(raw)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maxLength else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<endIndex]) + "…"
    }

    private static func prettyPrintedJSON(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any] else {
            return nil
        }
        guard let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: formatted, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func decodeCommonEntities(in text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
    }
}

struct ToolPermissionBubble: View {
    let request: ToolPermissionRequest
    let enableBackground: Bool
    let enableLiquidGlass: Bool
    let onDecision: (ToolPermissionDecision) -> Void

    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    private var toolName: String {
        request.displayName ?? request.toolName
    }

    private var argumentPreview: String? {
        WatchToolArgumentFormatter.preview(request.arguments)
    }

    private var bubbleFill: Color {
        enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)
    }

    private var countdownText: String? {
        guard let remaining = permissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return String(format: NSLocalizedString("将在 %ds 后自动允许", comment: ""), remaining)
    }

    private var autoApproveToggleLabel: String {
        permissionCenter.isAutoApproveDisabled(for: request.toolName)
            ? NSLocalizedString("恢复该工具自动批准", comment: "")
            : NSLocalizedString("关闭该工具自动批准", comment: "")
    }

    private var decisionItems: [(decision: ToolPermissionDecision, label: String, iconName: String, tint: Color)] {
        [
            (.allowOnce, NSLocalizedString("允许一次", comment: ""), "checkmark.circle.fill", .green),
            (.deny,      NSLocalizedString("拒绝",   comment: ""), "xmark.circle.fill",     .red),
            (.supplement,  NSLocalizedString("补充提示", comment: ""), "text.badge.plus",       .blue),
            (.allowForTool, NSLocalizedString("保持允许", comment: ""), "checkmark.shield.fill", .teal),
            (.allowAll,     NSLocalizedString("完全权限", comment: ""), "shield.fill",            .purple),
        ]
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                // 头部信息区域
                header
                    .padding(.horizontal, 8)
                    .padding(.top, 7)
                    .padding(.bottom, 6)

                Divider()

                // 决策选项行（逐行排列，仿 AskUserInput 风格）
                ForEach(Array(decisionItems.enumerated()), id: \.offset) { index, item in
                    Button {
                        onDecision(item.decision)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.iconName)
                                .foregroundStyle(item.tint)
                                .frame(width: 16, alignment: .center)
                            Text(item.label)
                                .etFont(.footnote)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < decisionItems.count - 1 {
                        Divider()
                            .padding(.leading, 32)
                    }
                }

                // 自动批准开关行
                if permissionCenter.autoApproveEnabled {
                    Divider()
                    Button {
                        let shouldDisable = !permissionCenter.isAutoApproveDisabled(for: request.toolName)
                        permissionCenter.setAutoApproveDisabled(shouldDisable, for: request.toolName)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: permissionCenter.isAutoApproveDisabled(for: request.toolName) ? "arrow.circlepath" : "circle.slash")
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .center)
                            Text(autoApproveToggleLabel)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(bubbleBackground)

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "hand.raised.circle")
                    .etFont(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("工具审批", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text(toolName)
                        .etFont(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if let argumentPreview {
                Text(argumentPreview)
                    .etFont(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let countdownText {
                Label(countdownText, systemImage: "timer")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if enableLiquidGlass {
            if #available(watchOS 26.0, *) {
                shape
                    .fill(bubbleFill)
                    .glassEffect(.clear, in: shape)
                    .clipShape(shape)
            } else {
                shape
                    .fill(bubbleFill)
            }
        } else {
            shape
                .fill(bubbleFill)
        }
    }
}

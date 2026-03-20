// ============================================================================
// ToolPermissionBubble.swift
// ============================================================================
// watchOS 工具审批卡片
// - 主卡片只保留快速批准动作
// - 详细权限与完整参数下沉到二级页
// - 参数显示会优先做 JSON 格式化与常见实体反转义
// ============================================================================

import SwiftUI
import Shared
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

    @State private var isPresentingDetails = false
    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    private var toolName: String {
        request.displayName ?? request.toolName
    }

    private var displayArguments: String {
        WatchToolArgumentFormatter.normalized(request.arguments)
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
        return "将在 \(remaining)s 后自动允许"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                header

                if let argumentPreview {
                    Text(argumentPreview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let countdownText {
                    Label(countdownText, systemImage: "timer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button("允许一次") {
                    onDecision(.allowOnce)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                Button {
                    isPresentingDetails = true
                } label: {
                    Label(argumentPreview == nil ? "更多权限" : "查看详情与更多", systemImage: "ellipsis.circle")
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(bubbleBackground)

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .sheet(isPresented: $isPresentingDetails) {
            ToolPermissionDetailSheet(
                request: request,
                displayArguments: displayArguments,
                onDecision: { decision in
                    isPresentingDetails = false
                    onDecision(decision)
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "hand.raised.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("工具审批")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(toolName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
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

private struct ToolPermissionDetailSheet: View {
    let request: ToolPermissionRequest
    let displayArguments: String
    let onDecision: (ToolPermissionDecision) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var permissionCenter = ToolPermissionCenter.shared

    private var toolName: String {
        request.displayName ?? request.toolName
    }

    private var countdownText: String? {
        guard let remaining = permissionCenter.autoApproveRemainingSeconds(for: request) else {
            return nil
        }
        return "将在 \(remaining)s 后自动允许"
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                detailSection(title: "工具") {
                    Text(toolName)
                        .font(.headline)
                    if let countdownText {
                        Text(countdownText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !displayArguments.isEmpty {
                    detailSection(title: "参数") {
                        ScrollView {
                            Text(displayArguments)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 88, maxHeight: 150)
                    }
                }

                detailSection(title: "更多权限") {
                    VStack(spacing: 8) {
                        Button("拒绝", role: .destructive) {
                            resolve(.deny)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button("保持允许") {
                            resolve(.allowForTool)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)

                        Button("完全权限") {
                            resolve(.allowAll)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button("补充提示") {
                            resolve(.supplement)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                }

                detailSection(title: "自动批准") {
                    Toggle("允许该工具自动批准", isOn: autoApproveBinding)
                        .disabled(!permissionCenter.autoApproveEnabled)

                    if !permissionCenter.autoApproveEnabled {
                        Text("全局自动批准当前未开启。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if permissionCenter.isAutoApproveDisabled(for: request.toolName) {
                        Text("该工具已从自动批准名单中排除。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func detailSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    private func resolve(_ decision: ToolPermissionDecision) {
        dismiss()
        onDecision(decision)
    }
}

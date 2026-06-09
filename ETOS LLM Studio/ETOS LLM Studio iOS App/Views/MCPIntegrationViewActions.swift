// ============================================================================
// MCPIntegrationViewActions.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP 工具箱的状态图标和 Schema 摘要辅助。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

extension MCPIntegrationView {
    func logLevelIcon(_ level: MCPLogLevel) -> some View {
        let (icon, color): (String, Color) = {
            switch level {
            case .debug:
                return ("ant", .gray)
            case .info:
                return ("info.circle", .blue)
            case .notice:
                return ("bell", .cyan)
            case .warning:
                return ("exclamationmark.triangle", .yellow)
            case .error:
                return ("xmark.circle", .red)
            case .critical, .alert, .emergency:
                return ("exclamationmark.octagon", .red)
            @unknown default:
                return ("questionmark.circle", .gray)
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(color)
    }

    func governanceCategoryIcon(_ category: MCPGovernanceLogCategory) -> some View {
        let icon: String = {
            switch category {
            case .lifecycle:
                return "link"
            case .cache:
                return "externaldrive"
            case .routing:
                return "arrow.triangle.branch"
            case .toolCall:
                return "hammer"
            case .notification:
                return "bell"
            case .serverLog:
                return "doc.text"
            case .progress:
                return "gauge.with.dots.needle.67percent"
            @unknown default:
                return "questionmark.circle"
            }
        }()
        return Image(systemName: icon)
            .foregroundStyle(.secondary)
    }

    func statusDescription(for server: MCPServerConfiguration) -> String {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .idle:
            return NSLocalizedString("未连接", comment: "")
        case .connecting:
            return NSLocalizedString("正在连接...", comment: "")
        case .reconnecting(let attempt, let scheduledAt, _):
            let remaining = max(0, Int(ceil(scheduledAt.timeIntervalSinceNow)))
            return String(format: NSLocalizedString("重连中（第%d次，约 %ds）", comment: ""), attempt, remaining)
        case .ready:
            return status.isSelectedForChat
                ? NSLocalizedString("已连接并参与聊天", comment: "")
                : NSLocalizedString("已连接", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        @unknown default:
            return NSLocalizedString("未知状态", comment: "")
        }
    }

    func statusIcon(for server: MCPServerConfiguration) -> String? {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .reconnecting:
            return "arrow.clockwise"
        case .ready:
            return status.isSelectedForChat ? "checkmark.circle.fill" : "checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return status.isSelectedForChat ? "checkmark.circle.fill" : nil
        @unknown default:
            return "questionmark.circle"
        }
    }

    func statusColor(for server: MCPServerConfiguration) -> Color {
        let status = manager.status(for: server)
        switch status.connectionState {
        case .ready:
            return .green
        case .connecting:
            return .blue
        case .reconnecting:
            return .orange
        case .failed:
            return .red
        case .idle:
            return status.isSelectedForChat ? .green : .secondary
        @unknown default:
            return .secondary
        }
    }

    func toolCallStateText(_ state: MCPToolCallState) -> String {
        switch state {
        case .running:
            return NSLocalizedString("运行中", comment: "")
        case .cancelling:
            return NSLocalizedString("取消中", comment: "")
        case .succeeded:
            return NSLocalizedString("成功", comment: "")
        case .failed(let reason):
            return String(format: NSLocalizedString("失败：%@", comment: ""), reason)
        case .cancelled(let reason):
            if let reason, !reason.isEmpty {
                return String(format: NSLocalizedString("已取消：%@", comment: ""), reason)
            }
            return NSLocalizedString("已取消", comment: "")
        @unknown default:
            return NSLocalizedString("未知状态", comment: "")
        }
    }

    func schemaSummary(for schema: JSONValue?) -> String? {
        guard let schema else { return nil }
        guard case .dictionary(let schemaDict) = schema else {
            return schema.prettyPrintedCompact()
        }
        let typeLabel: String
        if let typeValue = schemaDict["type"], case .string(let typeString) = typeValue {
            typeLabel = typeString
        } else {
            typeLabel = "unknown"
        }
        var segments: [String] = ["type=\(typeLabel)"]
        if let propertiesValue = schemaDict["properties"],
           case .dictionary(let properties) = propertiesValue,
           !properties.isEmpty {
            segments.append("fields=\(properties.keys.sorted().prefix(6).joined(separator: ", "))")
        }
        if let requiredValue = schemaDict["required"],
           case .array(let requiredItems) = requiredValue {
            let requiredKeys = requiredItems.compactMap { item -> String? in
                if case .string(let key) = item { return key }
                return nil
            }
            if !requiredKeys.isEmpty {
                segments.append("required=\(requiredKeys.joined(separator: ", "))")
            }
        }
        return segments.joined(separator: " · ")
    }
}

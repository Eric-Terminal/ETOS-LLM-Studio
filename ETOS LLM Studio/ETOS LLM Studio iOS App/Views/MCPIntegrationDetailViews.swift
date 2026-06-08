// ============================================================================
// MCPIntegrationDetailViews.swift
// ============================================================================
// ETOS LLM Studio
//
// MCP 工具箱的服务器详情页与工具设置页。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct MCPServerDetailView: View {
    let server: MCPServerConfiguration
    @ObservedObject private var manager = MCPManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var showingDeleteConfirmation = false

    private var status: MCPServerStatus {
        manager.status(for: server)
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("服务器信息", comment: "")) {
                LabeledContent(NSLocalizedString("名称", comment: ""), value: server.displayName)
                LabeledContent("Endpoint", value: server.humanReadableEndpoint)
                if let notes = server.notes {
                    LabeledContent(NSLocalizedString("备注", comment: ""), value: notes)
                }
            }

            Section(NSLocalizedString("连接控制", comment: "")) {
                Button(connectionActionTitle(for: status.connectionState)) {
                    performConnectionAction(for: status.connectionState)
                }

                Toggle(NSLocalizedString("用于聊天", comment: ""), isOn: bindingForSelection())
                    .disabled(status.connectionState == .connecting || isReconnecting(status.connectionState))
            }

            if let info = status.info {
                Section(NSLocalizedString("服务器能力", comment: "")) {
                    Text(info.name + (info.version.map { " \($0)" } ?? ""))
                    if let capabilities = info.capabilities, !capabilities.isEmpty {
                        Text("Capabilities: \(capabilities.keys.joined(separator: ", "))")
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !status.tools.isEmpty {
                Section(
                    String(format: NSLocalizedString("工具 (%d)", comment: ""), status.tools.count)
                ) {
                    ForEach(status.tools) { tool in
                        HStack(alignment: .center, spacing: 12) {
                            NavigationLink {
                                MCPToolSettingsDetailView(serverID: server.id, tool: tool)
                            } label: {
                                toolListSummary(tool)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: toolEnabledBinding(serverID: server.id, toolId: tool.toolId))
                                .labelsHidden()
                        }
                    }
                }
            }

            if !status.resources.isEmpty {
                Section(
                    String(format: NSLocalizedString("资源 (%d)", comment: ""), status.resources.count)
                ) {
                    ForEach(status.resources) { resource in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resource.resourceId)
                            if let desc = resource.description {
                                Text(desc)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(server.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(NSLocalizedString("编辑", comment: "")) {
                    isEditing = true
                }
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                MCPServerEditor(existingServer: server) { updated in
                    manager.save(server: updated)
                }
            }
        }
        .confirmationDialog(NSLocalizedString("确定要删除此服务器？", comment: ""), isPresented: $showingDeleteConfirmation) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                manager.delete(server: server)
                dismiss()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { }
        }
    }

    private func bindingForSelection() -> Binding<Bool> {
        Binding {
            manager.status(for: server).isSelectedForChat
        } set: { newValue in
            let current = manager.status(for: server).isSelectedForChat
            if newValue != current {
                manager.toggleSelection(for: server)
            }
        }
    }

    private func connectionActionTitle(for state: MCPManager.ConnectionState) -> String {
        isConnectedOrConnecting(state)
            ? NSLocalizedString("断开连接", comment: "")
            : NSLocalizedString("连接", comment: "")
    }

    private func performConnectionAction(for state: MCPManager.ConnectionState) {
        if isConnectedOrConnecting(state) {
            manager.disconnect(server: server)
        } else {
            manager.connect(to: server)
        }
    }

    private func isConnectedOrConnecting(_ state: MCPManager.ConnectionState) -> Bool {
        switch state {
        case .connecting, .reconnecting, .ready:
            return true
        case .idle, .failed:
            return false
        @unknown default:
            return false
        }
    }

    private func toolListSummary(_ tool: MCPToolDescription) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tool.toolId)
            if let desc = tool.description, !desc.isEmpty {
                Text(desc)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toolEnabledBinding(serverID: UUID, toolId: String) -> Binding<Bool> {
        Binding {
            manager.isToolEnabled(serverID: serverID, toolId: toolId)
        } set: { newValue in
            manager.setToolEnabled(serverID: serverID, toolId: toolId, isEnabled: newValue)
        }
    }

    private func isReconnecting(_ state: MCPManager.ConnectionState) -> Bool {
        if case .reconnecting = state {
            return true
        }
        return false
    }
}

struct MCPBuiltInServerRestoreView: View {
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("内置工具", comment: "Built-in tools section title")) {
                if manager.restorableBuiltInServers.isEmpty {
                    Text(NSLocalizedString("所有内置 MCP 服务器都已添加。", comment: "All built-in MCP servers restored"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.restorableBuiltInServers) { item in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayName)
                                    .etFont(.headline)
                                if let notes = item.notes, !notes.isEmpty {
                                    Text(notes)
                                        .etFont(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button {
                                manager.restoreBuiltInServer(id: item.id)
                            } label: {
                                Label(NSLocalizedString("恢复", comment: ""), systemImage: "arrow.clockwise")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(
                                String(
                                    format: NSLocalizedString("恢复%@", comment: "Restore built-in MCP server accessibility label"),
                                    item.displayName
                                )
                            )
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("内置工具", comment: "Built-in tools section title"))
    }
}

struct MCPToolSettingsDetailView: View {
    let serverID: UUID
    let tool: MCPToolDescription
    @ObservedObject private var manager = MCPManager.shared

    var body: some View {
        List {
            Section(NSLocalizedString("工具信息", comment: "")) {
                Text(tool.toolId)
                    .etFont(.headline)
                if let desc = tool.description, !desc.isEmpty {
                    Text(desc)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let schemaSummary = schemaSummary(for: tool.inputSchema) {
                    Text(String(format: NSLocalizedString("输入 Schema：%@", comment: ""), schemaSummary))
                        .etFont(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: toolBinding)
            }

            Section(
                header: Text(NSLocalizedString("审批策略", comment: "")),
                footer: Text(NSLocalizedString("默认“每次询问”，可按工具单独设置。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Picker(NSLocalizedString("审批策略", comment: ""), selection: toolApprovalPolicyBinding) {
                    ForEach(MCPToolApprovalPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具设置", comment: ""))
    }

    private var toolBinding: Binding<Bool> {
        Binding {
            manager.isToolEnabled(serverID: serverID, toolId: tool.toolId)
        } set: { newValue in
            manager.setToolEnabled(serverID: serverID, toolId: tool.toolId, isEnabled: newValue)
        }
    }

    private var toolApprovalPolicyBinding: Binding<MCPToolApprovalPolicy> {
        Binding {
            manager.approvalPolicy(serverID: serverID, toolId: tool.toolId)
        } set: { newValue in
            manager.setToolApprovalPolicy(serverID: serverID, toolId: tool.toolId, policy: newValue)
        }
    }

    private func schemaSummary(for schema: JSONValue?) -> String? {
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

import AppKit
import ETOSCore
import SwiftUI

struct MacMCPReadView: View {
    @StateObject private var model: MacMCPReadModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = MCPManager.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var pageID = GuidePageID(rawValue: "mac-mcp-read-\(UUID().uuidString)")

    private var canEditDraft: Bool {
        model.isPrepared && !model.isReading && !workspace.isRestoringData && appLock.state != .locked
    }

    private var draftTool: InternalToolDefinition {
        var properties: [String: JSONValue] = ["parameters": .dictionary(["type": .string("string")])]
        if model.target.isTemplate { properties["resource_uri"] = .dictionary(["type": .string("string")]) }
        return InternalToolDefinition(name: "propose_mac_mcp_read_draft", description: NSLocalizedString("参数保留在当前页面，点击读取后发送给服务器。", comment: ""),
                                      parameters: .dictionary(["type": .string("object"), "properties": .dictionary(properties), "additionalProperties": .bool(false)]))
    }

    init(server: MCPServerConfiguration, target: MacMCPReadTarget) {
        _model = StateObject(wrappedValue: MacMCPReadModel(server: server, target: target))
    }

    var body: some View {
        Form {
            Section {
                Text(model.target.name).textSelection(.enabled)
                if !model.target.description.isEmpty {
                    Text(model.target.description).font(.footnote).foregroundStyle(.secondary)
                }
                MacSettingsIntroCard(id: "mcp-reading", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac MCP 读取说明", comment: ""), documentID: "mcp-tools")
            }
            if model.target.isTemplate {
                Section {
                    Text(model.target.resourceID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    TextField(NSLocalizedString("资源 ID", comment: ""), text: $model.resourceID)
                        .disabled(model.isReading || !model.isPrepared)
                } header: { Text(NSLocalizedString("资源模板", comment: "")) }
            }
            Section {
                TextEditor(text: $model.parameters).font(.system(.body, design: .monospaced)).frame(minHeight: 120)
                    .accessibilityLabel(NSLocalizedString("参数 JSON", comment: ""))
                    .disabled(model.isReading || !model.isPrepared)
                if !model.schema.isEmpty {
                    DisclosureGroup(NSLocalizedString("参数说明", comment: "")) {
                        Text(model.schema).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } header: { Text(NSLocalizedString("参数 JSON", comment: "")) }
            footer: { Text(NSLocalizedString("参数保留在当前页面，点击读取后发送给服务器。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
            Section {
                Button(model.target.isPrompt ? NSLocalizedString("获取提示词", comment: "") : NSLocalizedString("读取资源", comment: "")) { model.read() }
                    .disabled(!model.isPrepared || model.isReading || workspace.isRestoringData || appLock.state == .locked)
                if model.isReading {
                    ProgressView(NSLocalizedString("正在加载…", comment: ""))
                    Button(NSLocalizedString("取消", comment: "")) { model.cancel() }
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if !model.output.isEmpty {
                Section {
                    Text(model.output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button(NSLocalizedString("复制", comment: "")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.output, forType: .string)
                    }
                } header: { Text(NSLocalizedString("最新响应", comment: "")) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.target.name)
        .task { await model.prepare() }
        .onDisappear { model.cancel() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { model.cancel(); dismiss() } }
        .onChange(of: appLock.state) { _, state in if state == .locked { model.cancel() } }
        .onReceive(manager.$servers) { servers in
            if !servers.contains(model.server) { model.cancel(); dismiss() }
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: pageID, title: NSLocalizedString("MCP 读取", comment: ""),
                documents: [GuideDocumentReference(id: "mcp-tools", title: "MCP Tools"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                tools: canEditDraft ? [GuidePageTool(definition: draftTool, access: .proposeChange)] : []
            ),
            snapshot: { guideSnapshot },
            buildProposal: { call, _ in
                guard canEditDraft, call.toolName == draftTool.name else { throw GuideError.invalidToolArguments }
                var arguments = try await Task.detached { try GuideToolArguments.decode(call.arguments) }.value
                try GuideToolArguments.requireOnlyKeys(model.target.isTemplate ? ["parameters", "resource_uri"] : ["parameters"], in: arguments)
                guard !arguments.isEmpty, arguments.values.allSatisfy({ if case .string = $0 { true } else { false } }) else { throw GuideError.invalidToolArguments }
                let revision = model.draftRevision
                let target = model.target
                let parameters = try GuideToolArguments.optionalString("parameters", in: arguments) ?? model.parameters
                let uri = try GuideToolArguments.optionalString("resource_uri", in: arguments) ?? model.resourceID
                _ = try await Task.detached { try target.request(parameters: parameters, resourceID: uri) }.value
                guard canEditDraft, model.draftRevision == revision else { throw GuideError.invalidToolArguments }
                let mutations = arguments.keys.sorted().map { path in
                    GuideSettingMutation(path: path, label: path == "parameters" ? NSLocalizedString("参数 JSON", comment: "") : NSLocalizedString("资源 ID", comment: ""),
                                         oldValue: nil, newValue: arguments[path]!, isSensitive: true)
                }
                arguments["draft_revision"] = .string(revision.uuidString)
                return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName,
                                           summary: NSLocalizedString("填写读取草稿", comment: ""), mutations: mutations, arguments: arguments)
            },
            execute: { proposal in
                guard canEditDraft, try GuideToolArguments.string("draft_revision", in: proposal.arguments) == model.draftRevision.uuidString else { throw GuideError.invalidToolArguments }
                if let value = try GuideToolArguments.optionalString("parameters", in: proposal.arguments) { model.parameters = value }
                if let value = try GuideToolArguments.optionalString("resource_uri", in: proposal.arguments) { model.resourceID = value }
                return GuideActionExecution(message: NSLocalizedString("已更新草稿，请手动读取。", comment: ""))
            }
        )
    }

    private var guideSnapshot: GuidePageSnapshot {
        var fields: [String: GuideSnapshotField] = [
            "server": GuideSnapshotField(label: NSLocalizedString("显示名称", comment: ""), value: .string(model.server.displayName), access: .readOnly),
            "reading": GuideSnapshotField(label: NSLocalizedString("状态", comment: ""), value: .bool(model.isReading), access: .readOnly),
            "manual_submission": GuideSnapshotField(label: NSLocalizedString("读取资源", comment: ""), value: .bool(true), access: .readOnly),
            "has_result": GuideSnapshotField(label: NSLocalizedString("最新响应", comment: ""), value: .bool(!model.output.isEmpty), access: .readOnly),
            "parameter_schema": GuideSnapshotField(label: NSLocalizedString("参数说明", comment: ""), value: .string(model.schema), access: .readOnly),
            "draft_revision": GuideSnapshotField(label: NSLocalizedString("状态", comment: ""), value: .string(model.draftRevision.uuidString), access: .readOnly)
        ]
        if canEditDraft {
            // 资源 URI 和参数可能携带凭据；向导只能填写草稿，不能回读或执行服务器请求。
            fields["parameters"] = GuideSnapshotField(label: NSLocalizedString("参数 JSON", comment: ""), value: .null, access: .writeOnly)
            if model.target.isTemplate {
                fields["resource_uri"] = GuideSnapshotField(label: NSLocalizedString("资源 ID", comment: ""), value: .null, access: .writeOnly)
            }
        }
        return GuidePageSnapshot(fields: fields)
    }
}

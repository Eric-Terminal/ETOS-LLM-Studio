import ETOSCore
import SwiftUI

struct MacBuiltInToolsView: View {
    let isActive: Bool
    @ObservedObject var model: MacBuiltInToolsModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    private var active: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "built-in-tools", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 内置工具使用说明", comment: ""), documentID: "settings-tools", isActive: active)
                Toggle(NSLocalizedString("仅显示已启用", comment: ""), isOn: $model.enabledOnly)
                if !model.isLoaded || model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            }
            Section {
                ForEach(model.rows) { row in
                    NavigationLink {
                        MacBuiltInToolDetail(kind: row.id, isActive: active, model: model)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(row.title)
                            Text(row.description).font(.caption).foregroundStyle(.secondary)
                            Text(row.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.isLoaded && model.rows.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("内置工具", comment: ""))
        .searchable(text: $model.query, prompt: Text(NSLocalizedString("搜索工具", comment: "")))
        .disabled(!active)
        .task { await model.start(); updateIsolation() }
        .onChange(of: workspace.currentSession?.isMemoryContextIsolationActive) { _, _ in updateIsolation() }
        .onChange(of: workspace.currentSession?.isToolContextIsolationActive) { _, _ in updateIsolation() }
        .onChange(of: workspace.temporaryChatMemoryMode) { _, _ in updateIsolation() }
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: GuidePageID(rawValue: "mac-built-in-tools-\(model.epoch)"),
                title: NSLocalizedString("内置工具", comment: ""), documents: [GuideDocumentReference(id: "settings-tools", title: "Tool Center")]),
            isActive: active,
            snapshot: { GuidePageSnapshot(fields: [
                "tools": GuideSnapshotField(label: NSLocalizedString("工具", comment: ""), value: model.guideRows, access: .readOnly)
            ]) }
        )
    }

    private func updateIsolation() {
        model.setIsolation(memory: (workspace.currentSession?.isMemoryContextIsolationActive ?? false) || workspace.temporaryChatMemoryMode == .isolated,
                           tools: workspace.currentSession?.isToolContextIsolationActive ?? false)
    }
}

private struct MacBuiltInToolDetail: View {
    let kind: ToolCatalogBuiltInToolKind
    let isActive: Bool
    @ObservedObject var model: MacBuiltInToolsModel
    @ObservedObject private var config = AppConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private var row: MacBuiltInToolPresentation? { model.allRows[kind] }
    private var title: String { row?.title ?? NSLocalizedString("内置工具", comment: "") }
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-built-in-\(kind.rawValue)-\(model.epoch)") }
    private var active: Bool { isActive && model.canWrite }
    private var tool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_built_in_enabled", description: title, parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary(["enabled": .dictionary(["type": .string("boolean")])]),
            "required": .array([.string("enabled")]), "additionalProperties": .bool(false)
        ]))
    }

    var body: some View {
        Group {
            if let appKind = kind.appToolKind {
                form.guidePageContext(
                    descriptor: GuidePageDescriptor(id: pageID, title: title,
                        documents: [GuideDocumentReference(id: "settings-tools", title: "Tool Center")],
                        tools: [GuidePageTool(definition: tool, access: .proposeChange)]),
                    isActive: active,
                    snapshot: { GuidePageSnapshot(fields: [
                        "enabled": GuideSnapshotField(label: NSLocalizedString("启用", comment: ""), value: .bool(model.isEnabled(appKind))),
                        "available_in_session": GuideSnapshotField(label: NSLocalizedString("当前状态", comment: ""), value: .bool(row?.state.isAvailableInCurrentSession ?? false), access: .readOnly)
                    ]) },
                    buildProposal: { call, _ in
                        guard call.toolName == tool.name else { throw GuideError.unsupportedTool(call.toolName) }
                        let arguments = try GuideToolArguments.decode(call.arguments)
                        try GuideToolArguments.requireOnlyKeys(["enabled"], in: arguments)
                        guard case .bool(let enabled)? = arguments["enabled"], enabled != model.isEnabled(appKind) else { throw GuideError.invalidToolArguments }
                        return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName, summary: title,
                            mutations: [GuideSettingMutation(path: "enabled", label: NSLocalizedString("启用", comment: ""), oldValue: .bool(model.isEnabled(appKind)), newValue: .bool(enabled))], arguments: arguments)
                    },
                    execute: { proposal in
                        guard active, proposal.pageID == pageID, proposal.mutations.first?.oldValue == .bool(model.isEnabled(appKind)),
                              case .bool(let value)? = proposal.arguments["enabled"] else { throw GuideError.invalidToolArguments }
                        try await model.setEnabled(value, kind: appKind, expectedEpoch: model.epoch)
                        return GuideActionExecution(message: NSLocalizedString("已保存配置。", comment: ""))
                    }
                )
            } else {
                form.guideSettingsPageContext(id: pageID, title: title,
                    documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System"), GuideDocumentReference(id: "settings-tools", title: "Tool Center")],
                    isActive: active, settings: memorySettings)
            }
        }
        .onChange(of: model.epoch) { _, _ in dismiss() }
    }

    private var form: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "built-in-\(kind.rawValue)", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 内置工具使用说明", comment: ""), documentID: "settings-tools", isActive: isActive && !model.isSuspended)
                if let row {
                    Text(row.description).font(.footnote).foregroundStyle(.secondary)
                    Text(row.status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                if let appKind = kind.appToolKind {
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: Binding(get: { model.isEnabled(appKind) }, set: { value in
                        let token = model.epoch
                        Task {
                            do { try await model.setEnabled(value, kind: appKind, expectedEpoch: token) }
                            catch { if token == model.epoch { self.error = error.localizedDescription } }
                        }
                    }))
                } else {
                    Toggle(NSLocalizedString("启用记忆系统", comment: ""), isOn: $config.enableMemory)
                    if kind == .memoryWrite {
                        Toggle(NSLocalizedString("允许写入新的记忆", comment: ""), isOn: $config.enableMemoryWrite).disabled(!config.enableMemory)
                    } else if kind == .memorySearch {
                        Toggle(NSLocalizedString("主动检索", comment: ""), isOn: $config.enableMemoryActiveRetrieval).disabled(!config.enableMemory)
                        Stepper(value: $config.memoryTopK, in: 0...Int.max) {
                            LabeledContent(NSLocalizedString("检索数量 (Top K)", comment: ""), value: String(config.memoryTopK))
                        }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text(NSLocalizedString("启用状态", comment: "")) }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .disabled(!active)
    }

    private var memorySettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .bool("memory_enabled", label: NSLocalizedString("启用记忆系统", comment: ""), get: { config.enableMemory }, set: { config.enableMemory = $0 }),
            .readOnly("available_in_session", label: NSLocalizedString("当前状态", comment: ""), value: { .bool(row?.state.isAvailableInCurrentSession ?? false) })
        ]
        if kind == .memoryWrite {
            fields.append(.bool("memory_write", label: NSLocalizedString("允许写入新的记忆", comment: ""), get: { config.enableMemoryWrite }, set: { config.enableMemoryWrite = $0 }))
        } else if kind == .memorySearch {
            fields.append(.bool("active_retrieval", label: NSLocalizedString("主动检索", comment: ""), get: { config.enableMemoryActiveRetrieval }, set: { config.enableMemoryActiveRetrieval = $0 }))
            fields.append(.integer("top_k", label: NSLocalizedString("检索数量 (Top K)", comment: ""), range: 0...Int.max, get: { config.memoryTopK }, set: { config.memoryTopK = $0 }))
        }
        return fields
    }
}

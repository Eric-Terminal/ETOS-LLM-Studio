import ETOSCore
import SwiftUI

struct MacShortcutToolsView: View {
    let isActive: Bool
    @ObservedObject var model: MacShortcutToolsModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var editor: MacShortcutToolRow?
    @State private var isVisible = false

    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-shortcuts-\(model.epoch)") }
    private var active: Bool { isActive && isVisible && workspace.canManageLocalModels && !model.isSuspended }
    private var preferenceTool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_shortcuts_enabled", description: NSLocalizedString("向模型暴露快捷指令工具", comment: ""), parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary(["enabled": .dictionary(["type": .string("boolean")])]),
            "required": .array([.string("enabled")]), "additionalProperties": .bool(false)
        ]))
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "shortcuts", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 快捷指令工具使用说明", comment: ""), documentID: "shortcut-tools", isActive: isActive && !model.isSuspended)
                Toggle(NSLocalizedString("向模型暴露快捷指令工具", comment: ""), isOn: Binding(
                    get: { model.chatToolsEnabled }, set: { value in
                        let token = model.epoch
                        Task {
                            do { try await model.setEnabled(value, expectedEpoch: token) }
                            catch { if token == model.epoch { model.error = error.localizedDescription } }
                        }
                    }
                )).disabled(!model.canWrite)
                Toggle(NSLocalizedString("仅显示已启用", comment: ""), isOn: $model.enabledOnly)
                if model.isWorking || !model.isLoaded { ProgressView(NSLocalizedString("处理中", comment: "")) }
            }
            Section {
                ForEach(model.rows) { row in
                    Button { editor = row } label: {
                        VStack(alignment: .leading) {
                            Text(row.title)
                            Text(row.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(row.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).disabled(!model.canWrite)
                }
                if model.isLoaded && model.rows.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text(NSLocalizedString("已导入工具", comment: "")) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("快捷指令工具", comment: ""))
        .searchable(text: $model.query, prompt: Text(NSLocalizedString("搜索工具", comment: "")))
        .disabled(!active)
        .task { await model.start(); model.setSessionIsolation(workspace.currentSession?.isToolContextIsolationActive ?? false) }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; editor = nil }
        .onChange(of: model.epoch) { _, _ in editor = nil; model.error = nil }
        .onChange(of: isActive) { _, value in if !value { editor = nil } }
        .onChange(of: configuration.appLanguage) { _, _ in model.refresh() }
        .onChange(of: workspace.currentSession?.isToolContextIsolationActive) { _, value in model.setSessionIsolation(value ?? false) }
        .sheet(item: $editor) { row in MacShortcutToolEditor(row: row, model: model, isActive: active) }
        .alert(NSLocalizedString("快捷指令工具", comment: ""), isPresented: Binding(get: { editor == nil && model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: pageID, title: NSLocalizedString("快捷指令工具", comment: ""),
                documents: [GuideDocumentReference(id: "shortcut-tools", title: "Shortcuts"), GuideDocumentReference(id: "settings-tools", title: "Tool Center")],
                tools: [GuidePageTool(definition: preferenceTool, access: .proposeChange)]),
            isActive: active && editor == nil && model.canWrite,
            snapshot: { GuidePageSnapshot(fields: [
                "enabled": GuideSnapshotField(label: NSLocalizedString("启用", comment: ""), value: .bool(model.chatToolsEnabled)),
                "tools": GuideSnapshotField(label: NSLocalizedString("已导入工具", comment: ""), value: model.guideRows, access: .readOnly),
                "session_tool_isolation": GuideSnapshotField(label: NSLocalizedString("当前会话工具隔离", comment: ""), value: .bool(workspace.currentSession?.isToolContextIsolationActive ?? false), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard call.toolName == preferenceTool.name else { throw GuideError.unsupportedTool(call.toolName) }
                let arguments = try GuideToolArguments.decode(call.arguments)
                try GuideToolArguments.requireOnlyKeys(["enabled"], in: arguments)
                guard case .bool(let enabled)? = arguments["enabled"], enabled != model.chatToolsEnabled else { throw GuideError.invalidToolArguments }
                return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName,
                    summary: NSLocalizedString("向模型暴露快捷指令工具", comment: ""), mutations: [
                        GuideSettingMutation(path: "enabled", label: NSLocalizedString("启用", comment: ""), oldValue: .bool(model.chatToolsEnabled), newValue: .bool(enabled))
                    ], arguments: arguments)
            },
            execute: { proposal in
                guard active, proposal.pageID == pageID,
                      proposal.mutations.first?.oldValue == .bool(model.chatToolsEnabled),
                      case .bool(let enabled)? = proposal.arguments["enabled"] else { throw GuideError.invalidToolArguments }
                try await model.setEnabled(enabled, expectedEpoch: model.epoch)
                return GuideActionExecution(message: NSLocalizedString("已保存配置。", comment: ""))
            }
        )
    }
}

struct MacShortcutToolEditor: View {
    let row: MacShortcutToolRow
    let isActive: Bool
    @ObservedObject var model: MacShortcutToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var runMode: ShortcutRunModeHint
    @State private var description: String
    @State private var epoch: UUID
    @State private var error: String?

    init(row: MacShortcutToolRow, model: MacShortcutToolsModel, isActive: Bool) {
        self.row = row; self.model = model; self.isActive = isActive
        _enabled = State(initialValue: row.tool.isEnabled); _runMode = State(initialValue: row.tool.runModeHint)
        _description = State(initialValue: row.tool.userDescription ?? ""); _epoch = State(initialValue: model.epoch)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "shortcut-detail", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 快捷指令工具使用说明", comment: ""), documentID: "shortcut-tools", isActive: isActive && epoch == model.epoch && !model.isSuspended)
                    LabeledContent(NSLocalizedString("快捷指令名称", comment: ""), value: row.tool.name)
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $enabled)
                    Picker(NSLocalizedString("运行模式", comment: ""), selection: $runMode) {
                        Text(NSLocalizedString("直连优先", comment: "")).tag(ShortcutRunModeHint.direct)
                        Text(NSLocalizedString("桥接优先", comment: "")).tag(ShortcutRunModeHint.bridge)
                    }
                    TextField(NSLocalizedString("自定义描述", comment: ""), text: $description, axis: .vertical).lineLimit(3...10)
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let generated = row.tool.generatedDescription {
                    Section { Text(generated).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                    header: { Text(NSLocalizedString("自动生成描述", comment: "")) }
                }
                if let schema = row.schema {
                    Section { Text(schema).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                    header: { Text(NSLocalizedString("参数说明", comment: "")) }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .disabled(!isActive || !model.canWrite || epoch != model.epoch)
            .navigationTitle(row.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        Task {
                            do {
                                try await model.save(row.tool, enabled: enabled, runMode: runMode, description: description, expectedEpoch: epoch)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(!isActive || !model.canWrite || epoch != model.epoch)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-shortcut-draft-\(row.id)-\(epoch)"), title: row.title,
                documents: [GuideDocumentReference(id: "shortcut-tools", title: "Shortcuts")],
                isActive: isActive && model.canWrite && epoch == model.epoch,
                settings: [
                    .readOnly("shortcut_name", label: NSLocalizedString("快捷指令名称", comment: ""), value: { .string(row.tool.name) }),
                    .readOnly("requires_save", label: NSLocalizedString("保存", comment: ""), value: { .bool(true) }),
                    .readOnly("has_generated_description", label: NSLocalizedString("自动生成描述", comment: ""), value: { .bool(row.tool.generatedDescription != nil) }),
                    .readOnly("has_input_schema", label: NSLocalizedString("参数说明", comment: ""), value: { .bool(row.schema != nil) }),
                    .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { enabled }, set: { enabled = $0 }),
                    .string("run_mode", label: NSLocalizedString("运行模式", comment: ""), allowedValues: ShortcutRunModeHint.allCases.map(\.rawValue), get: { runMode.rawValue }, set: { if let value = ShortcutRunModeHint(rawValue: $0) { runMode = value } }),
                    .string("user_description", label: NSLocalizedString("自定义描述", comment: ""), get: { description }, set: { description = $0 })
                ]
            )
        }
        .frame(minWidth: 520, minHeight: 420)
        .interactiveDismissDisabled(model.isWorking)
        .onChange(of: model.epoch) { _, _ in dismiss() }
    }
}

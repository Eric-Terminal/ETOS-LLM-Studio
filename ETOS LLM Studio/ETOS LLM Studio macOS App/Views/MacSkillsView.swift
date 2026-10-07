import ETOSCore
import SwiftUI

struct MacSkillsView: View {
    let isActive: Bool
    @ObservedObject var model: MacSkillsModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var selected: MacSkillRow?
    @State private var editor: MacSkillEditorTarget?
    @State private var importing = false
    @State private var visible = false
    private var active: Bool { isActive && visible && workspace.canManageLocalModels && !model.isSuspended }
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-skills-\(model.epoch)") }
    private var tool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_skills_enabled", description: NSLocalizedString("向模型暴露 Agent Skills", comment: ""), parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary(["enabled": .dictionary(["type": .string("boolean")])]),
            "required": .array([.string("enabled")]), "additionalProperties": .bool(false)
        ]))
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "skills", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac Skills 使用说明", comment: ""), documentID: "agent-skills", isActive: isActive && !model.isSuspended)
                Toggle(NSLocalizedString("向模型暴露 Agent Skills（use_skill）", comment: ""), isOn: Binding(
                    get: { model.chatToolsEnabled }, set: { update(.groupEnabled($0)) }
                )).disabled(!model.canWrite)
                Toggle(NSLocalizedString("仅显示已启用", comment: ""), isOn: $model.enabledOnly)
            } footer: {
                Text(NSLocalizedString("关闭后不会向模型提供 use_skill 工具，技能文件仍会保留。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(NSLocalizedString("新增技能（粘贴 SKILL.md）", comment: "")) { editor = .manifest(nil) }.disabled(!model.canWrite)
                Button(NSLocalizedString("导入", comment: "")) { importing = true }.disabled(!model.canWrite)
                Button(NSLocalizedString("刷新", comment: "")) { model.reload() }.disabled(model.isWorking || model.isPreparingImport)
            }
            Section {
                if !model.isLoaded || model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
                ForEach(model.rows) { row in
                    Button { selected = row } label: {
                        VStack(alignment: .leading) {
                            Text(row.id)
                            Text(row.metadata.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(row.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).disabled(!model.canWrite)
                }
                if model.isLoaded && model.rows.isEmpty {
                    Text(NSLocalizedString("当前没有匹配的工具。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text(String(format: NSLocalizedString("已安装技能 (%d)", comment: ""), model.rows.count)) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("Agent Skills", comment: ""))
        .searchable(text: $model.query, prompt: Text(NSLocalizedString("搜索工具", comment: "")))
        .disabled(!active)
        .task { await model.start(); model.setSessionIsolation(workspace.currentSession?.isToolContextIsolationActive ?? false); model.reload() }
        .onAppear { visible = true }
        .onDisappear { visible = false; closeSheets() }
        .onChange(of: isActive) { _, value in if !value { closeSheets() } }
        .onChange(of: model.epoch) { _, _ in closeSheets() }
        .onChange(of: configuration.appLanguage) { _, _ in model.refreshLanguage() }
        .onChange(of: workspace.currentSession?.isToolContextIsolationActive) { _, value in model.setSessionIsolation(value ?? false) }
        .sheet(item: $selected, onDismiss: { model.closeDetail() }) { row in
            MacSkillDetailView(name: row.id, isActive: active, model: model)
        }
        .sheet(item: $editor) { target in MacSkillEditor(target: target, isActive: active, model: model) { _ in } }
        .sheet(isPresented: $importing, onDismiss: { model.cancelImport() }) { MacSkillImportView(isActive: active, model: model) }
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: pageID, title: NSLocalizedString("Agent Skills", comment: ""),
                documents: [GuideDocumentReference(id: "agent-skills", title: "Agent Skills")],
                tools: [GuidePageTool(definition: tool, access: .proposeChange)]),
            isActive: active && model.canWrite && selected == nil && editor == nil && !importing,
            snapshot: { GuidePageSnapshot(fields: [
                "enabled": GuideSnapshotField(label: NSLocalizedString("向模型暴露 Agent Skills", comment: ""), value: .bool(model.chatToolsEnabled)),
                "skills": GuideSnapshotField(label: NSLocalizedString("Agent Skills", comment: ""), value: model.guideRows, access: .readOnly),
                "tool_isolation": GuideSnapshotField(label: NSLocalizedString("当前会话工具隔离", comment: ""), value: .bool(workspace.currentSession?.isToolContextIsolationActive ?? false), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard call.toolName == tool.name else { throw GuideError.unsupportedTool(call.toolName) }
                let arguments = try GuideToolArguments.decode(call.arguments)
                try GuideToolArguments.requireOnlyKeys(["enabled"], in: arguments)
                guard case .bool(let enabled)? = arguments["enabled"], enabled != model.chatToolsEnabled else { throw GuideError.invalidToolArguments }
                return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName,
                    summary: NSLocalizedString("向模型暴露 Agent Skills", comment: ""), mutations: [
                        GuideSettingMutation(path: "enabled", label: NSLocalizedString("启用", comment: ""), oldValue: .bool(model.chatToolsEnabled), newValue: .bool(enabled))
                    ], arguments: arguments)
            },
            execute: { proposal in
                guard active, proposal.pageID == pageID, proposal.mutations.first?.oldValue == .bool(model.chatToolsEnabled),
                      case .bool(let enabled)? = proposal.arguments["enabled"] else { throw GuideError.pageChanged }
                try await model.mutate(.groupEnabled(enabled), expectedEpoch: model.epoch)
                return GuideActionExecution(message: NSLocalizedString("已保存配置。", comment: ""))
            }
        )
    }

    private func closeSheets() { selected = nil; editor = nil; importing = false; model.cancelImport() }
    private func update(_ mutation: SkillLibraryMutation) {
        let epoch = model.epoch
        Task {
            guard active else { return }
            do { try await model.mutate(mutation, expectedEpoch: epoch) }
            catch { if epoch == model.epoch { model.error = error.localizedDescription } }
        }
    }
}

import ETOSCore
import SwiftUI

struct MacAgentPromptsView: View {
    let isActive: Bool
    @ObservedObject var model: MacAgentPromptModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    @State private var editor: MacAgentPromptEditorTarget?
    @State private var deleting: MacAgentPromptRow?
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !model.isSuspended }
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-agent-prompts-\(model.epoch)-\(model.revision)") }
    private var selectionTool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_agent_prompt_selection", description: NSLocalizedString("选用提示词", comment: ""), parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary(["profile_id": .dictionary(["type": .string("string")])]),
            "required": .array([.string("profile_id")]), "additionalProperties": .bool(false)
        ]))
    }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "agent-prompts", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Agent 提示词使用说明", comment: ""), documentID: "local-linux",
                    isActive: isActive && workspace.canManageLocalModels && !model.isSuspended && editor == nil && deleting == nil)
                Button(NSLocalizedString("新增提示词", comment: "")) { editor = MacAgentPromptEditorTarget(original: nil) }.disabled(!model.canWrite)
                Button(NSLocalizedString("刷新", comment: "")) { model.reload() }.disabled(model.isWorking || model.isLoading)
            }
            Section {
                ForEach(model.rows) { row in
                    HStack {
                        Button { editor = MacAgentPromptEditorTarget(original: row.profile) } label: {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(row.title)
                                    if row.isSelected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                    if !row.profile.isEnabled { Text(NSLocalizedString("已停用", comment: "")).font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(row.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Button(NSLocalizedString("选用提示词", comment: "")) { select(row.profile) }
                            .disabled(row.isSelected || !row.profile.isEnabled)
                        if !row.profile.isBuiltIn {
                            Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deleting = row }
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canWrite)
                }
                if model.isLoading || model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text(NSLocalizedString("提示词列表", comment: "")) }
            footer: { Text(NSLocalizedString("仅用于 Agent 的 Linux 操作说明，不替代会话提示词。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(NSLocalizedString("Agent 提示词", comment: ""))
        .disabled(!active)
        .onAppear { visible = true; model.reload() }
        .onDisappear { visible = false; closeSheets() }
        .onChange(of: isActive) { _, value in if !value { closeSheets() } }
        .onChange(of: model.epoch) { _, _ in closeSheets() }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .sheet(item: $editor) { target in MacAgentPromptEditor(target: target, isActive: active, model: model) }
        .confirmationDialog(NSLocalizedString("删除提示词？", comment: ""), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible, presenting: deleting) { row in
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) { delete(row.profile) }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deleting = nil }
        } message: { _ in Text(NSLocalizedString("删除后无法撤销；选用项被删除时恢复默认提示词。", comment: "")) }
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: pageID, title: NSLocalizedString("Agent 提示词", comment: ""),
                documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux")],
                tools: [GuidePageTool(definition: selectionTool, access: .proposeChange)]),
            isActive: active && model.canWrite && editor == nil && deleting == nil,
            snapshot: { GuidePageSnapshot(fields: [
                "profiles": GuideSnapshotField(label: NSLocalizedString("提示词列表", comment: ""), value: model.guideRows, access: .readOnly),
                "profile_id": GuideSnapshotField(label: NSLocalizedString("选用提示词", comment: ""), value: .string(model.selection)),
                "effective_profile_id": GuideSnapshotField(label: NSLocalizedString("默认本地 Agent", comment: ""), value: .string(model.effectiveSelection), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard call.toolName == selectionTool.name else { throw GuideError.unsupportedTool(call.toolName) }
                let arguments = try GuideToolArguments.decode(call.arguments)
                try GuideToolArguments.requireOnlyKeys(["profile_id"], in: arguments)
                guard case .string(let rawID)? = arguments["profile_id"], let id = UUID(uuidString: rawID),
                      let row = model.rows.first(where: { $0.id == id && $0.profile.isEnabled }) else { throw GuideError.invalidToolArguments }
                return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName,
                    summary: row.title, mutations: [GuideSettingMutation(path: "profile_id", label: NSLocalizedString("选用提示词", comment: ""),
                        oldValue: .string(model.selection), newValue: .string(id.uuidString))], arguments: arguments)
            },
            execute: { proposal in
                guard active, editor == nil, deleting == nil, proposal.pageID == pageID,
                      proposal.toolName == selectionTool.name,
                      proposal.mutations.first?.oldValue == .string(model.selection),
                      case .string(let rawID)? = proposal.arguments["profile_id"], let id = UUID(uuidString: rawID),
                      let row = model.rows.first(where: { $0.id == id && $0.profile.isEnabled }) else { throw GuideError.pageChanged }
                try await model.select(row.profile, expectedSelection: model.selection, expectedEpoch: model.epoch)
                return GuideActionExecution(message: NSLocalizedString("已保存配置。", comment: ""))
            }
        )
    }

    private func closeSheets() { editor = nil; deleting = nil }
    private func select(_ profile: LocalAgentPromptProfile) {
        let epoch = model.epoch, selection = model.selection
        Task {
            guard active else { return }
            do { try await model.select(profile, expectedSelection: selection, expectedEpoch: epoch) }
            catch { if model.epoch == epoch { model.error = error.localizedDescription } }
        }
    }
    private func delete(_ profile: LocalAgentPromptProfile) {
        let epoch = model.epoch
        deleting = nil
        Task {
            guard active else { return }
            do { try await model.delete(profile, expectedEpoch: epoch) }
            catch { if model.epoch == epoch { model.error = error.localizedDescription } }
        }
    }
}

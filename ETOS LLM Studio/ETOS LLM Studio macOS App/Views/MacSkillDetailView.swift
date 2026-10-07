import ETOSCore
import SwiftUI

struct MacSkillDetailView: View {
    @State var name: String
    let isActive: Bool
    @ObservedObject var model: MacSkillsModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: MacSkillEditorTarget?
    @State private var deleting = false
    @State private var deletingFile: SkillLibraryFile?
    @State private var visible = false
    private var active: Bool { isActive && visible && !model.isSuspended }
    private var detail: MacSkillDetailPresentation? { model.detail?.source.metadata.name == name ? model.detail : nil }
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-skill-\(name)-\(model.epoch)") }
    private var settingTool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_skill_setting", description: NSLocalizedString("编辑技能", comment: ""), parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary([
                "enabled": .dictionary(["type": .string("boolean")]),
                "execution_policy": .dictionary(["type": .string("string"), "enum": .array(SkillExecutionPolicy.allCases.map { .string($0.rawValue) })])
            ]), "minProperties": .int(1), "maxProperties": .int(1), "additionalProperties": .bool(false)
        ]))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let detail {
                    Section {
                        MacSettingsIntroCard(id: "skill-detail-\(name)", title: NSLocalizedString("使用说明", comment: ""),
                                             details: NSLocalizedString("Mac Skills 使用说明", comment: ""), documentID: "agent-skills", isActive: isActive && !model.isSuspended)
                        Toggle(NSLocalizedString("在聊天中启用该技能", comment: ""), isOn: Binding(
                            get: { model.enabledNames.contains(name) }, set: { update(.skillEnabled(name: name, enabled: $0)) }
                        ))
                        Button(NSLocalizedString("编辑技能", comment: "")) { editor = .manifest(detail.source) }
                    }
                    Section {
                        Picker(NSLocalizedString("脚本执行策略", comment: ""), selection: Binding(
                            get: { detail.source.executionPolicy.record.policy }, set: { policy in
                                update(.executionPolicy(name: name, expectedVersion: detail.source.versionDigest,
                                                        original: detail.source.executionPolicy.record, policy: policy))
                            }
                        )) { ForEach(SkillExecutionPolicy.allCases, id: \.self) { policy in Text(policy.displayName).tag(policy) } }
                        if detail.source.executionPolicy.record.policy == .allowCurrentVersion && !detail.source.executionPolicy.isCurrentVersionApproved {
                            Button(NSLocalizedString("允许当前版本", comment: "")) {
                                update(.executionPolicy(name: name, expectedVersion: detail.source.versionDigest,
                                                        original: detail.source.executionPolicy.record, policy: .allowCurrentVersion))
                            }
                        }
                    } footer: { Text(detail.policyFooter).font(.footnote).foregroundStyle(.secondary) }
                    Section {
                        LabeledContent(NSLocalizedString("名称", comment: ""), value: name)
                        Text(detail.source.metadata.description).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                        if let compatibility = detail.source.metadata.compatibility {
                            LabeledContent(NSLocalizedString("兼容性", comment: ""), value: compatibility)
                        }
                        if !detail.allowedTools.isEmpty { LabeledContent(NSLocalizedString("允许工具", comment: ""), value: detail.allowedTools) }
                    } header: { Text(NSLocalizedString("基本信息", comment: "")) }
                    Section {
                        Text(detail.source.body.isEmpty ? NSLocalizedString("无正文内容。", comment: "") : detail.source.body)
                            .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    } header: { Text(NSLocalizedString("正文预览", comment: "")) }
                    Section {
                        Button(NSLocalizedString("新建文件", comment: "")) { editor = .resource(detail.source, file: nil) }
                        ForEach(detail.source.files) { file in
                            HStack {
                                if file.id == "SKILL.md" {
                                    Button(file.id) { editor = .manifest(detail.source) }
                                } else if file.editableContent != nil {
                                    Button(file.id) { editor = .resource(detail.source, file: file) }
                                } else {
                                    VStack(alignment: .leading) {
                                        Text(file.id).textSelection(.enabled)
                                        Text(file.reference.readOnlyReason ?? NSLocalizedString("仅列出", comment: "")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(detail.fileSizes[file.id] ?? "").font(.caption).foregroundStyle(.secondary)
                                if file.id != "SKILL.md" {
                                    Button(role: .destructive) { deletingFile = file } label: {
                                        Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                                    }.labelStyle(.iconOnly)
                                }
                            }.buttonStyle(.borderless)
                        }
                    } header: { Text(String(format: NSLocalizedString("文件 (%d)", comment: ""), detail.source.files.count)) }
                    Section { Button(NSLocalizedString("删除技能", comment: ""), role: .destructive) { deleting = true } }
                }
                if model.isLoadingDetail || model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                Button(NSLocalizedString("刷新", comment: "")) { model.openDetail(name) }
            }
            .formStyle(.grouped)
            .disabled(!active || !model.canWrite || model.isLoadingDetail)
            .navigationTitle(name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("关闭", comment: "")) { dismiss() }.disabled(model.isWorking) } }
            .guidePageContext(
                descriptor: GuidePageDescriptor(id: pageID, title: name,
                    documents: [GuideDocumentReference(id: "agent-skills", title: "Agent Skills")],
                    tools: [GuidePageTool(definition: settingTool, access: .proposeChange)]),
                isActive: active && model.canWrite && detail != nil && !model.isLoadingDetail && editor == nil && !deleting && deletingFile == nil,
                snapshot: { guideSnapshot() }, buildProposal: { call, snapshot in try buildProposal(call, snapshot) },
                execute: { proposal in try await execute(proposal) }
            )
        }
        .frame(minWidth: 580, minHeight: 520)
        .interactiveDismissDisabled(model.isWorking)
        .onAppear { visible = true; model.openDetail(name) }
        .onDisappear { visible = false }
        .onChange(of: model.epoch) { _, _ in dismiss() }
        .sheet(item: $editor) { target in
            MacSkillEditor(target: target, isActive: active, model: model) { newName in
                if let newName { name = newName; model.openDetail(newName) }
            }
        }
        .confirmationDialog(NSLocalizedString("删除技能", comment: ""), isPresented: $deleting) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let detail { update(.delete(name: name, expectedVersion: detail.source.versionDigest), close: true) }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: { Text(String(format: NSLocalizedString("确认删除“%@”？此操作不可撤销。", comment: ""), name)) }
        .confirmationDialog(NSLocalizedString("删除文件", comment: ""), isPresented: Binding(
            get: { deletingFile != nil }, set: { if !$0 { deletingFile = nil } }
        )) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let detail, let file = deletingFile {
                    update(.file(name: name, expectedVersion: detail.source.versionDigest, path: file.id, creating: false, content: nil))
                }
                deletingFile = nil
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deletingFile = nil }
        } message: { Text(String(format: NSLocalizedString("确认删除“%@”？", comment: ""), deletingFile?.id ?? "")) }
    }

    private func guideSnapshot() -> GuidePageSnapshot {
        guard let detail else { return GuidePageSnapshot(fields: [:]) }
        return GuidePageSnapshot(fields: [
            "name": GuideSnapshotField(label: NSLocalizedString("名称", comment: ""), value: .string(name), access: .readOnly),
            "description": GuideSnapshotField(label: NSLocalizedString("描述", comment: ""), value: .string(detail.source.metadata.description), access: .readOnly),
            "compatibility": GuideSnapshotField(label: NSLocalizedString("兼容性", comment: ""), value: .string(detail.source.metadata.compatibility ?? ""), access: .readOnly),
            "allowed_tools": GuideSnapshotField(label: NSLocalizedString("允许工具", comment: ""), value: .string(detail.allowedTools), access: .readOnly),
            "enabled": GuideSnapshotField(label: NSLocalizedString("启用", comment: ""), value: .bool(model.enabledNames.contains(name))),
            "execution_policy": GuideSnapshotField(label: NSLocalizedString("脚本执行策略", comment: ""), value: .string(detail.source.executionPolicy.record.policy.rawValue)),
            "version_approved": GuideSnapshotField(label: NSLocalizedString("允许当前版本", comment: ""), value: .bool(detail.source.executionPolicy.isCurrentVersionApproved), access: .readOnly),
            "files": GuideSnapshotField(label: NSLocalizedString("技能文件", comment: ""), value: detail.guideFiles, access: .readOnly),
            "body_characters": GuideSnapshotField(label: NSLocalizedString("SKILL.md 正文字符数", comment: ""), value: .int(detail.bodyCharacterCount), access: .readOnly)
        ])
    }

    private func buildProposal(_ call: InternalToolCall, _ snapshot: GuidePageSnapshot) throws -> GuideActionProposal {
        guard call.toolName == settingTool.name, let detail else { throw GuideError.invalidToolArguments }
        let arguments = try GuideToolArguments.decode(call.arguments)
        try GuideToolArguments.requireOnlyKeys(["enabled", "execution_policy"], in: arguments)
        guard arguments.count == 1 else { throw GuideError.invalidToolArguments }
        let mutation: GuideSettingMutation
        if case .bool(let enabled)? = arguments["enabled"] {
            guard enabled != model.enabledNames.contains(name) else { throw GuideError.invalidToolArguments }
            mutation = GuideSettingMutation(path: "enabled", label: NSLocalizedString("启用", comment: ""), oldValue: .bool(!enabled), newValue: .bool(enabled))
        } else if case .string(let raw)? = arguments["execution_policy"], let policy = SkillExecutionPolicy(rawValue: raw) {
            guard policy != detail.source.executionPolicy.record.policy || (policy == .allowCurrentVersion && !detail.source.executionPolicy.isCurrentVersionApproved) else { throw GuideError.invalidToolArguments }
            mutation = GuideSettingMutation(path: "execution_policy", label: NSLocalizedString("脚本执行策略", comment: ""),
                                            oldValue: .string(detail.source.executionPolicy.record.policy.rawValue), newValue: .string(raw))
        } else { throw GuideError.invalidToolArguments }
        var proposalArguments = arguments
        proposalArguments["version"] = .string(detail.source.versionDigest)
        return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName,
                                   summary: NSLocalizedString("编辑技能", comment: ""), mutations: [mutation], arguments: proposalArguments)
    }

    private func execute(_ proposal: GuideActionProposal) async throws -> GuideActionExecution {
        guard active, proposal.pageID == pageID, let detail, let change = proposal.mutations.first,
              proposal.arguments["version"] == .string(detail.source.versionDigest) else { throw GuideError.pageChanged }
        let mutation: SkillLibraryMutation
        switch (change.path, change.newValue) {
        case ("enabled", .bool(let enabled)):
            guard change.oldValue == .bool(model.enabledNames.contains(name)) else { throw GuideError.invalidToolArguments }
            mutation = .skillEnabled(name: name, enabled: enabled)
        case ("execution_policy", .string(let raw)):
            guard let policy = SkillExecutionPolicy(rawValue: raw), change.oldValue == .string(detail.source.executionPolicy.record.policy.rawValue) else { throw GuideError.invalidToolArguments }
            mutation = .executionPolicy(name: name, expectedVersion: detail.source.versionDigest, original: detail.source.executionPolicy.record, policy: policy)
        default: throw GuideError.invalidToolArguments
        }
        try await model.mutate(mutation, expectedEpoch: model.epoch)
        model.openDetail(name)
        return GuideActionExecution(message: NSLocalizedString("已保存配置。", comment: ""))
    }

    private func update(_ mutation: SkillLibraryMutation, close: Bool = false) {
        guard active else { return }
        let token = model.epoch
        Task {
            guard active else { return }
            do {
                try await model.mutate(mutation, expectedEpoch: token)
                guard token == model.epoch, active else { return }
                if close { dismiss() } else { model.openDetail(name) }
            } catch { if token == model.epoch { model.error = error.localizedDescription } }
        }
    }
}

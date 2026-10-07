import ETOSCore
import SwiftUI

struct MacRoleplayDataView: View {
    let session: ChatSession
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        Form {
            Section {
                LabeledContent(NSLocalizedString("当前会话", comment: ""), value: session.name)
                MacSettingsIntroCard(id: "roleplay-data", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 宏与变量使用说明", comment: ""), documentID: "roleplay")
            }
            Section {
                NavigationLink(NSLocalizedString("自定义宏", comment: "")) { MacRoleplayDataEditor(session: session, section: .macros) }
            }
            Section(NSLocalizedString("分层变量", comment: "")) {
                ForEach(RoleplayVariableScope.allCases, id: \.self) { scope in
                    NavigationLink(scope.macLabel) { MacRoleplayDataEditor(session: session, section: .variables(scope)) }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(workspace.isRestoringData)
        .navigationTitle(NSLocalizedString("宏与变量", comment: ""))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-roleplay-data-\(session.id)"), title: NSLocalizedString("宏与变量", comment: ""),
            documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")], settings: [
                .readOnly("session_id", label: NSLocalizedString("当前会话", comment: ""), value: { .string(session.id.uuidString) }),
                .readOnly("requires_navigation", label: NSLocalizedString("分层变量", comment: ""), value: { .bool(true) })
            ]
        )
    }
}

@MainActor
private struct MacRoleplayDataEditor: View {
    let session: ChatSession
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @StateObject private var model: MacRoleplayDataModel

    init(session: ChatSession, section: MacRoleplayDataSection) {
        self.session = session
        _model = StateObject(wrappedValue: MacRoleplayDataModel(sessionID: session.id, section: section))
    }

    private var updateTool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_roleplay_data", description: model.section.title, parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary([
                "values": model.section == .macros ? GuideRoleplayDataSettingsSupport.macrosSchema : GuideRoleplayDataSettingsSupport.variablesSchema
            ]), "required": .array([.string("values")]), "additionalProperties": .bool(false)
        ]))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(NSLocalizedString("当前会话", comment: ""), value: session.name)
                if let name = model.subjectName {
                    LabeledContent(model.section == .variables(.character) ? NSLocalizedString("角色卡", comment: "") : NSLocalizedString("用户身份", comment: ""), value: name)
                }
                if let message = model.message {
                    LabeledContent(NSLocalizedString("消息 ID", comment: ""), value: message.id.uuidString)
                    LabeledContent(NSLocalizedString("版本", comment: ""), value: (message.getCurrentVersionIndex() + 1).formatted())
                }
            }
            if model.loading { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            else if model.source != nil {
                if model.section == .macros {
                    ForEach($model.macros) { $macro in
                        Section {
                            TextField(NSLocalizedString("宏名称", comment: ""), text: $macro.name)
                            TextField(NSLocalizedString("宏值", comment: ""), text: $macro.value, axis: .vertical).lineLimit(2...8)
                            Button(NSLocalizedString("删除此宏", comment: ""), role: .destructive) {
                                let id = macro.id
                                model.macros.removeAll { $0.id == id }
                            }
                        }
                    }
                    Section { Button(NSLocalizedString("新增宏", comment: "")) { model.macros.append(MacRoleplayMacroRow()) } }
                } else {
                    Section {
                        TextEditor(text: $model.text).font(.system(.body, design: .monospaced)).frame(minHeight: 300)
                            .accessibilityLabel(model.section.title)
                    }
                }
                Section {
                    Button(model.section == .macros ? NSLocalizedString("保存自定义宏", comment: "") : NSLocalizedString("保存此作用域", comment: "")) {
                        Task { await model.save() }
                    }
                    .disabled(!model.canSave)
                } footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                MacSettingsIntroCard(id: "roleplay-data-\(model.section.id)", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 宏与变量使用说明", comment: ""), documentID: "roleplay")
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if let status = model.status { Text(status).font(.footnote).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .disabled(model.saving || workspace.isRestoringData)
        .navigationTitle(model.section.title)
        .task { await model.load(workspace: workspace) }
        .onDisappear { model.cancelPreparation() }
        .onReceive(AppConfigStore.shared.$appLanguage.dropFirst()) { _ in model.prepare() }
        .guidePageContext(
            descriptor: GuidePageDescriptor(id: model.pageID, title: model.section.title,
                                            documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
                                            tools: model.editable ? [GuidePageTool(definition: updateTool, access: .proposeChange)] : []),
            snapshot: { GuidePageSnapshot(fields: [
                "values": model.prepared?.field ?? GuideSnapshotField(label: model.section.title, value: .null),
                "session_id": GuideSnapshotField(label: NSLocalizedString("当前会话", comment: ""), value: .string(session.id.uuidString), access: .readOnly),
                "scope": GuideSnapshotField(label: NSLocalizedString("变量作用域", comment: ""), value: .string(model.section.id), access: .readOnly),
                "subject_id": GuideSnapshotField(label: NSLocalizedString("角色与用户身份", comment: ""), value: .string(model.source?.subjectID?.uuidString ?? ""), access: .readOnly),
                "message_id": GuideSnapshotField(label: NSLocalizedString("消息 ID", comment: ""), value: .string(model.message?.id.uuidString ?? ""), access: .readOnly),
                "version_index": GuideSnapshotField(label: NSLocalizedString("版本", comment: ""), value: .int(model.message?.getCurrentVersionIndex() ?? 0), access: .readOnly),
                "valid": GuideSnapshotField(label: NSLocalizedString("配置有效", comment: ""), value: .bool(model.prepared != nil), access: .readOnly),
                "requires_save": GuideSnapshotField(label: NSLocalizedString("修改后需要保存", comment: ""), value: .bool(true), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard call.toolName == updateTool.name else { throw GuideError.invalidToolArguments }
                return try await model.buildProposal(call)
            },
            execute: { proposal in
                guard proposal.toolName == updateTool.name else { throw GuideError.invalidToolArguments }
                return try await model.execute(proposal)
            }
        )
    }
}

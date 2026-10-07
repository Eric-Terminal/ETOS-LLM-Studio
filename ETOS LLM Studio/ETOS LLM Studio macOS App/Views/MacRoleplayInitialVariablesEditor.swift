import ETOSCore
import SwiftUI

struct MacRoleplayInitialVariablesEditor: View {
    let characterID: UUID
    @Binding var text: String
    let isSaving: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var variablesField: GuideSnapshotField?
    @State private var isValid = false
    @State private var revision = UUID()
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-roleplay-initial-variables-\(characterID)") }
    private static let updateTool = InternalToolDefinition(
        name: "propose_mac_roleplay_initial_variables", description: NSLocalizedString("初始变量", comment: ""),
        parameters: .dictionary([
            "type": .string("object"), "properties": .dictionary(["variables": GuideRoleplayDataSettingsSupport.variablesSchema]),
            "required": .array([.string("variables")]), "additionalProperties": .bool(false)
        ])
    )

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 300)
                    .accessibilityLabel(NSLocalizedString("初始变量", comment: ""))
                if !isValid { Text(NSLocalizedString("初始变量必须是有效的 JSON 对象。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text(NSLocalizedString("初始变量必须填写为 JSON 对象，并会在绑定角色卡时注入角色变量作用域。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving || workspace.isRestoringData)
        .navigationTitle(NSLocalizedString("初始变量", comment: ""))
        .onChange(of: text) { _, _ in revision = UUID(); isValid = false; variablesField = nil }
        .task(id: text) {
            isValid = false
            let source = text
            let result = await Task.detached { () -> GuideSnapshotField? in
                guard let variables = try? JSONDecoder().decode([String: JSONValue].self, from: Data(source.utf8)) else { return nil }
                return GuideSnapshotField(label: NSLocalizedString("初始变量", comment: ""), value: .dictionary(variables))
            }.value
            guard !Task.isCancelled else { return }
            variablesField = result
            isValid = result != nil
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: pageID, title: NSLocalizedString("初始变量", comment: ""), documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
                tools: isSaving || workspace.isRestoringData ? [] : [GuidePageTool(definition: Self.updateTool, access: .proposeChange)]
            ),
            snapshot: { GuidePageSnapshot(fields: [
                "variables": variablesField ?? GuideSnapshotField(label: NSLocalizedString("初始变量", comment: ""), value: .null),
                "valid": GuideSnapshotField(label: NSLocalizedString("配置有效", comment: ""), value: .bool(isValid), access: .readOnly),
                "requires_parent_save": GuideSnapshotField(label: NSLocalizedString("修改后需要保存", comment: ""), value: .bool(true), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard !isSaving, !workspace.isRestoringData, call.toolName == Self.updateTool.name else { throw GuideError.invalidToolArguments }
                let revision = revision
                let prepared = try await Task.detached {
                    let arguments = try GuideToolArguments.decode(call.arguments)
                    try GuideToolArguments.requireOnlyKeys(["variables"], in: arguments)
                    guard let value = arguments["variables"] else { throw GuideError.invalidToolArguments }
                    let normalized = try GuideRoleplayDataSettingsSupport.normalizeVariables(value)
                    return (normalized, GuideSecretRedactor.containsSensitiveField(normalized))
                }.value
                guard !isSaving, !workspace.isRestoringData, self.revision == revision else { throw GuideError.invalidToolArguments }
                let value = prepared.0
                let arguments: [String: JSONValue] = ["variables": value, "revision": .string(revision.uuidString)]
                return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName,
                                           summary: NSLocalizedString("初始变量", comment: ""),
                                           mutations: [GuideSettingMutation(path: "variables", label: NSLocalizedString("初始变量", comment: ""), oldValue: nil, newValue: value,
                                                                           isSensitive: prepared.1)], arguments: arguments)
            },
            execute: { proposal in
                guard !isSaving, !workspace.isRestoringData, try GuideToolArguments.string("revision", in: proposal.arguments) == revision.uuidString,
                      let value = proposal.arguments["variables"] else { throw GuideError.invalidToolArguments }
                let expectedRevision = revision
                let formatted = await Task.detached {
                    (value.prettyPrinted(), GuideSnapshotField(label: NSLocalizedString("初始变量", comment: ""), value: value))
                }.value
                guard !isSaving, !workspace.isRestoringData, revision == expectedRevision else { throw GuideError.invalidToolArguments }
                text = formatted.0
                variablesField = formatted.1
                isValid = true
                return GuideActionExecution(message: NSLocalizedString("已更新草稿，请保存配置以生效。", comment: ""))
            }
        )
    }
}

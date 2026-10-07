import ETOSCore
import SwiftUI

/// 请求头和请求体各自拥有上下文；向导只能提交新对象，不能读取已有凭据。
struct MacJSONDraftEditor: View {
    enum ValueKind: Equatable, Sendable { case object, stringDictionary }

    let pageID: GuidePageID
    let title: String
    let kind: ValueKind
    @Binding var text: String
    @State private var error: String?

    private static let tool = InternalToolDefinition(
        name: "propose_desktop_json_draft",
        description: NSLocalizedString("只替换当前 JSON 草稿，保存父页面后生效。", comment: ""),
        parameters: .dictionary([
            "type": .string("object"),
            "properties": .dictionary(["json": .dictionary(["type": .string("object")])]),
            "required": .array([.string("json")]),
            "additionalProperties": .bool(false)
        ])
    )
    private static let restoreToolName = "restore_desktop_json_draft"

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 300)
                    .accessibilityLabel(title)
            } footer: {
                Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .task(id: text) {
            let source = text
            let kind = kind
            do {
                try await Task.detached {
                    switch kind {
                    case .object: _ = try JSONDecoder().decode([String: JSONValue].self, from: Data(source.utf8))
                    case .stringDictionary: _ = try JSONDecoder().decode([String: String].self, from: Data(source.utf8))
                    }
                }.value
                guard !Task.isCancelled, source == text else { return }
                error = nil
            } catch {
                guard !Task.isCancelled, source == text else { return }
                self.error = error.localizedDescription
            }
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: pageID, title: title,
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                tools: [GuidePageTool(definition: Self.tool, access: .proposeChange)]
            ),
            snapshot: { GuidePageSnapshot(fields: [
                "json": GuideSnapshotField(label: title, value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly),
                "valid": GuideSnapshotField(label: NSLocalizedString("配置有效", comment: ""), value: .bool(error == nil), access: .readOnly),
                "editing_mode": GuideSnapshotField(label: NSLocalizedString("编辑方式", comment: ""), value: .string("parent_draft_until_save"), access: .readOnly),
                "value_type": GuideSnapshotField(label: NSLocalizedString("格式", comment: ""), value: .string(kind == .stringDictionary ? "string_dictionary" : "json_object"), access: .readOnly)
            ]) },
            buildProposal: { call, _ in
                guard call.toolName == Self.tool.name else { throw GuideError.unsupportedTool(call.toolName) }
                let arguments = try GuideToolArguments.decode(call.arguments)
                try GuideToolArguments.requireOnlyKeys(["json"], in: arguments)
                guard case .dictionary(let object)? = arguments["json"] else { throw GuideError.invalidToolArguments }
                if kind == .stringDictionary {
                    guard object.values.allSatisfy({ if case .string = $0 { true } else { false } }) else { throw GuideError.invalidToolArguments }
                }
                return GuideActionProposal(
                    pageID: pageID, toolCallID: call.id, toolName: Self.tool.name,
                    summary: NSLocalizedString("替换 JSON 草稿", comment: ""),
                    mutations: [GuideSettingMutation(path: "json", label: title, oldValue: .string(GuideSnapshotField.hiddenValue), newValue: GuideSecretRedactor.redact(.dictionary(object)))],
                    arguments: ["json": .dictionary(object), "expected_text": .string(text)]
                )
            },
            execute: { proposal in
                guard case .string(let expected)? = proposal.arguments["expected_text"], expected == text else { throw GuideError.pageChanged }
                let replacement: String
                if proposal.toolName == Self.restoreToolName,
                   case .string(let restored)? = proposal.arguments["text"] {
                    replacement = restored
                } else if proposal.toolName == Self.tool.name,
                          case .dictionary(let object)? = proposal.arguments["json"] {
                    replacement = await Task.detached { JSONValue.dictionary(object).prettyPrintedCompact() }.value
                } else { throw GuideError.invalidToolArguments }
                try Task.checkCancellation()
                guard text == expected else { throw GuideError.pageChanged }
                let old = text
                text = replacement
                return GuideActionExecution(
                    message: NSLocalizedString("已更新草稿，请保存配置以生效。", comment: ""),
                    undoProposal: proposal.toolName == Self.restoreToolName ? nil : GuideActionProposal(
                        pageID: pageID, toolCallID: "undo-\(proposal.toolCallID)", toolName: Self.restoreToolName,
                        summary: NSLocalizedString("撤销修改", comment: ""), mutations: [],
                        arguments: ["text": .string(old), "expected_text": .string(replacement)]
                    )
                )
            }
        )
    }
}

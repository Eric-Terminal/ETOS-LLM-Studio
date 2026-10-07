import ETOSCore
import SwiftUI

struct MacRequestParameterEditor: View {
    let pageID: GuidePageID
    let parameters: [String: JSONValue]
    let mode: Model.RequestBodyOverrideMode
    var rawJSON: String? = nil
    let onSave: ([String: JSONValue], Model.RequestBodyOverrideMode, String) -> Void
    @StateObject private var model = MacRequestParameterModel()
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    private static var tool: InternalToolDefinition { InternalToolDefinition(name: "propose_mac_request_parameters",
        description: NSLocalizedString("只替换当前请求参数草稿，不发送网络请求。", comment: ""),
        parameters: .dictionary(["type": .string("object"), "properties": .dictionary([
            "parameters": GuideRequestBodyControlSettingsSupport.payloadSchema,
            "edit_mode": .dictionary(["type": .string("string"), "enum": .array(["keyValue", "expression", "rawJSON"].map(JSONValue.string))])
        ]), "additionalProperties": .bool(false)])) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(NSLocalizedString("编辑方式", comment: ""), selection: Binding(get: { model.draft.mode }, set: { mode in
                        Task { await model.changeMode(mode) }
                    })) {
                        Text(NSLocalizedString("键值对", comment: "")).tag(Model.RequestBodyOverrideMode.keyValue)
                        Text(NSLocalizedString("参数表达式", comment: "")).tag(Model.RequestBodyOverrideMode.expression)
                        Text(NSLocalizedString("原始 JSON", comment: "")).tag(Model.RequestBodyOverrideMode.rawJSON)
                    }.disabled(model.busy)
                }
                if model.draft.mode == .rawJSON {
                    Section {
                        TextEditor(text: $model.draft.text).font(.system(.body, design: .monospaced)).frame(minHeight: 240)
                            .accessibilityLabel(NSLocalizedString("原始 JSON", comment: ""))
                    }
                } else {
                    ForEach($model.draft.rows) { $row in
                        Section {
                            if model.draft.mode == .keyValue { TextField(NSLocalizedString("键", comment: ""), text: $row.key) }
                            TextField(model.draft.mode == .keyValue ? NSLocalizedString("值", comment: "") : NSLocalizedString("参数表达式", comment: ""), text: $row.value, axis: .vertical)
                                .font(.system(.body, design: .monospaced)).lineLimit(2...6)
                            Button(NSLocalizedString("删除", comment: ""), role: .destructive) { model.draft.rows.removeAll { $0.id == row.id } }
                        }
                    }
                    Section { Button(NSLocalizedString("添加", comment: "")) { model.draft.rows.append(.init()) } }
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                Section {
                    MacSettingsIntroCard(id: pageID.rawValue, title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 请求参数草稿使用说明", comment: ""), documentID: "model-request-body")
                }
            }
            .formStyle(.grouped)
            .disabled(!model.ready || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("请求体参数", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        guard let values = model.parameters, !model.busy, !workspace.isRestoringData else { return }
                        onSave(values, model.draft.mode, model.preview)
                        dismiss()
                    }.disabled(model.busy || model.parameters == nil || workspace.isRestoringData)
                }
            }
            .guidePageContext(descriptor: GuidePageDescriptor(id: pageID, title: NSLocalizedString("请求体参数", comment: ""),
                documents: [GuideDocumentReference(id: "model-request-body", title: "Request Body Controls")],
                tools: model.ready && !model.busy ? [GuidePageTool(definition: Self.tool, access: .proposeChange)] : []),
                snapshot: { GuidePageSnapshot(fields: [
                    "parameters": GuideSnapshotField(label: NSLocalizedString("请求体参数", comment: ""), value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly),
                    "edit_mode": GuideSnapshotField(label: NSLocalizedString("编辑方式", comment: ""), value: .string(model.draft.mode.rawValue)),
                    "editing_mode": GuideSnapshotField(label: NSLocalizedString("应用方式", comment: ""), value: .string("parent_draft_until_save"), access: .readOnly),
                    "valid": GuideSnapshotField(label: NSLocalizedString("配置有效", comment: ""), value: .bool(model.parameters != nil), access: .readOnly),
                    "revision": GuideSnapshotField(label: NSLocalizedString("版本", comment: ""), value: .string(model.revision.uuidString), access: .readOnly)
                ]) }, buildProposal: { call, _ in
                    guard call.toolName == Self.tool.name else { throw GuideError.unsupportedTool(call.toolName) }
                    let revision = model.revision
                    let prepared = try await Task.detached {
                        let args = try GuideToolArguments.decode(call.arguments)
                        try GuideToolArguments.requireOnlyKeys(["parameters", "edit_mode"], in: args)
                        guard !args.isEmpty else { throw GuideError.invalidToolArguments }
                        if let values = args["parameters"] {
                            guard case .dictionary = values else { throw GuideError.invalidToolArguments }
                        }
                        if let mode = args["edit_mode"] {
                            guard case .string(let raw) = mode, Model.RequestBodyOverrideMode(rawValue: raw) != nil else { throw GuideError.invalidToolArguments }
                        }
                        return (args, GuideSecretRedactor.redact(args["parameters"] ?? .null))
                    }.value
                    guard revision == model.revision else { throw GuideError.pageChanged }
                    var args = prepared.0
                    var mutations: [GuideSettingMutation] = []
                    if args["parameters"] != nil {
                        mutations.append(GuideSettingMutation(path: "parameters", label: NSLocalizedString("请求体参数", comment: ""),
                            oldValue: .string(GuideSnapshotField.hiddenValue), newValue: prepared.1))
                    }
                    if let mode = args["edit_mode"] {
                        mutations.append(GuideSettingMutation(path: "edit_mode", label: NSLocalizedString("编辑方式", comment: ""),
                                                             oldValue: .string(model.draft.mode.rawValue), newValue: mode))
                    }
                    args["revision"] = .string(revision.uuidString)
                    return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: Self.tool.name,
                        summary: NSLocalizedString("替换 JSON 草稿", comment: ""),
                        mutations: mutations, arguments: args)
                }, execute: { proposal in
                    guard proposal.toolName == Self.tool.name,
                          case .string(let raw)? = proposal.arguments["revision"], let revision = UUID(uuidString: raw),
                          !workspace.isRestoringData else { throw GuideError.invalidToolArguments }
                    let values: [String: JSONValue]?
                    if case .dictionary(let value)? = proposal.arguments["parameters"] { values = value } else { values = nil }
                    let mode: Model.RequestBodyOverrideMode?
                    if case .string(let value)? = proposal.arguments["edit_mode"] { mode = Model.RequestBodyOverrideMode(rawValue: value) } else { mode = nil }
                    try await model.replace(with: values, mode: mode, expectedRevision: revision)
                    return GuideActionExecution(message: NSLocalizedString("已更新草稿，请保存配置以生效。", comment: ""))
                })
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 540, minHeight: 560)
        .task { await model.load(parameters: parameters, mode: mode, rawJSON: rawJSON) }
        .onDisappear { model.cancel() }
        .onReceive(AppConfigStore.shared.$appLanguage.dropFirst()) { _ in if model.ready { model.refresh() } }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }
}

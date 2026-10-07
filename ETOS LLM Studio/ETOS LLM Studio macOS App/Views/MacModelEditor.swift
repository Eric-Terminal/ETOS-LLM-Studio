import ETOSCore
import SwiftUI

struct MacModelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Model
    @State private var parametersJSON = ""
    @State private var originalParametersJSON = ""
    @State private var isBusy = true
    @State private var error: String?
    @State private var didPrepare = false
    private let onSave: (Model) -> Void

    init(model: Model, onSave: @escaping (Model) -> Void) {
        _draft = State(initialValue: model)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("模型 ID", comment: ""), text: $draft.modelName)
                    TextField(NSLocalizedString("显示名称", comment: ""), text: $draft.displayName)
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $draft.isActivated)
                    TextField(NSLocalizedString("分组名称", comment: ""), text: Binding(get: { draft.pickerGroupName ?? "" }, set: { draft.pickerGroupName = Model.normalizedPickerGroupName($0) }))
                    TextField(NSLocalizedString("model.prompt.title", comment: ""), text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...10)
                    Picker(NSLocalizedString("模型用途", comment: ""), selection: $draft.kind) {
                        ForEach(ModelKind.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                    }
                } footer: {
                    Text(NSLocalizedString("模型修改先返回提供商草稿，保存提供商后生效。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(ModelModality.allCases, id: \.self) { modality in
                        Toggle(modality.localizedName, isOn: Binding(
                            get: { draft.inputModalities.contains(modality) },
                            set: { enabled in
                                draft.inputModalities.removeAll { $0 == modality }
                                if enabled { draft.inputModalities.append(modality) }
                            }
                        ))
                    }
                } header: { Text(NSLocalizedString("输入类型", comment: "")) }
                Section {
                    ForEach(ModelModality.allCases, id: \.self) { modality in
                        Toggle(modality.localizedName, isOn: Binding(
                            get: { draft.outputModalities.contains(modality) },
                            set: { enabled in
                                draft.outputModalities.removeAll { $0 == modality }
                                if enabled { draft.outputModalities.append(modality) }
                            }
                        ))
                    }
                } header: { Text(NSLocalizedString("输出类型", comment: "")) }
                Section {
                    ForEach(ModelCapability.editableCases, id: \.self) { capability in
                        Toggle(capability.localizedName, isOn: Binding(
                            get: { draft.capabilities.contains(capability) },
                            set: { enabled in
                                draft.capabilities.removeAll { $0 == capability }
                                if enabled { draft.capabilities.append(capability) }
                            }
                        ))
                    }
                } header: { Text(NSLocalizedString("模型能力", comment: "")) }
                Section {
                    NavigationLink(NSLocalizedString("覆盖参数 JSON", comment: "")) {
                        MacJSONDraftEditor(pageID: GuidePageID(rawValue: "mac-model-parameters-\(draft.id)"), title: NSLocalizedString("覆盖参数 JSON", comment: ""), kind: .object, text: $parametersJSON)
                    }
                } header: { Text(NSLocalizedString("覆盖参数 JSON", comment: "")) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("模型配置", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { save() }.disabled(isBusy || draft.modelName.isEmpty)
                }
            }
            .task {
                guard !didPrepare else { return }
                didPrepare = true
                let parameters = draft.overrideParameters
                parametersJSON = await Task.detached {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return (try? encoder.encode(parameters)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                }.value
                originalParametersJSON = parametersJSON
                isBusy = false
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-model-\(draft.id)"), title: NSLocalizedString("模型配置", comment: ""),
                documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
                settings: guideSettings
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 500, minHeight: 600)
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("provider_draft_until_save") }),
            .string("model_id", label: NSLocalizedString("模型 ID", comment: ""), get: { draft.modelName }, set: { draft.modelName = $0 }),
            .string("display_name", label: NSLocalizedString("显示名称", comment: ""), get: { draft.displayName }, set: { draft.displayName = $0 }),
            .string("picker_group", label: NSLocalizedString("分组名称", comment: ""), get: { draft.pickerGroupName ?? "" }, set: { draft.pickerGroupName = Model.normalizedPickerGroupName($0) }),
            .string("model_prompt", label: NSLocalizedString("model.prompt.title", comment: ""), get: { draft.prompt }, set: { draft.prompt = $0 }),
            .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { draft.isActivated }, set: { draft.isActivated = $0 }),
            .string("kind", label: NSLocalizedString("模型用途", comment: ""), allowedValues: ModelKind.allCases.map(\.rawValue), get: { draft.kind.rawValue }, set: { if let kind = ModelKind(rawValue: $0) { draft.kind = kind } })
        ] + ModelModality.allCases.map { modality in
            .bool("input_\(modality.rawValue)", label: modality.localizedName, get: { draft.inputModalities.contains(modality) }, set: { enabled in
                draft.inputModalities.removeAll { $0 == modality }
                if enabled { draft.inputModalities.append(modality) }
            })
        } + ModelModality.allCases.map { modality in
            .bool("output_\(modality.rawValue)", label: modality.localizedName, get: { draft.outputModalities.contains(modality) }, set: { enabled in
                draft.outputModalities.removeAll { $0 == modality }
                if enabled { draft.outputModalities.append(modality) }
            })
        } + ModelCapability.editableCases.map { capability in
            .bool("capability_\(capability.rawValue)", label: capability.localizedName, get: { draft.capabilities.contains(capability) }, set: { enabled in
                draft.capabilities.removeAll { $0 == capability }
                if enabled { draft.capabilities.append(capability) }
            })
        }
    }

    private func save() {
        let text = parametersJSON
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                draft.overrideParameters = try await Task.detached {
                    try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8))
                }.value
                // 覆盖参数始终以同一份解析后的对象保存，避免旧 raw JSON 在其他平台重新打开时回退。
                if text != originalParametersJSON {
                    draft.requestBodyOverrideMode = .rawJSON
                    draft.rawRequestBodyJSON = text
                }
                if draft.displayName.isEmpty { draft.displayName = draft.modelName }
                onSave(draft)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

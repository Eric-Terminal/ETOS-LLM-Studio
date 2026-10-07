import ETOSCore
import SwiftUI

struct MacModelEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var draft: Model
    @State private var isBusy = false
    @State private var showsPricing = false
    @State private var showsRequestBody = false
    @State private var testSource: MacModelConnectivitySource?
    @State private var testError: String?
    @State private var saveTask: Task<Void, Never>?
    private let providerAPIFormat: String
    private let supportsConnectivityTest: Bool
    private let prepareTestSource: (Model) async throws -> MacModelConnectivitySource
    private let onSave: (Model) -> Void

    init(model: Model, providerAPIFormat: String, supportsConnectivityTest: Bool, prepareTestSource: @escaping (Model) async throws -> MacModelConnectivitySource, onSave: @escaping (Model) -> Void) {
        _draft = State(initialValue: model)
        self.providerAPIFormat = providerAPIFormat
        self.supportsConnectivityTest = supportsConnectivityTest
        self.prepareTestSource = prepareTestSource
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "model-\(draft.id)", title: NSLocalizedString("模型配置", comment: ""),
                                         details: NSLocalizedString("Mac 模型配置草稿使用说明", comment: ""), documentID: "provider-model-basics")
                }
                Section {
                    TextField(NSLocalizedString("模型 ID", comment: ""), text: $draft.modelName)
                    TextField(NSLocalizedString("显示名称", comment: ""), text: $draft.displayName)
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $draft.isActivated)
                    TextField(NSLocalizedString("分组名称", comment: ""), text: Binding(get: { draft.pickerGroupName ?? "" }, set: { draft.pickerGroupName = Model.normalizedPickerGroupName($0) }))
                    TextField(NSLocalizedString("model.prompt.title", comment: ""), text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...10)
                    Picker(NSLocalizedString("模型用途", comment: ""), selection: Binding(get: { draft.kind }, set: {
                        if draft.kind != $0 { draft.resetCapabilityShape(for: $0) }
                    })) {
                        ForEach(ModelKind.allCases, id: \.self) { Text($0.localizedName).tag($0) }
                    }
                    if providerAPIFormat != LocalModelProviderBridge.apiFormat {
                        Picker(NSLocalizedString("API 格式", comment: ""), selection: Binding(
                            get: { draft.apiFormatOverride ?? "" }, set: { draft.apiFormatOverride = Model.normalizedAPIFormatOverride($0) }
                        )) {
                            Text(NSLocalizedString("跟随提供商", comment: "")).tag("")
                            ForEach(ProviderAPIFormatOption.allCases) { Text($0.localizedName).tag($0.rawValue) }
                        }
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
                    ForEach(ModelModality.outputCases, id: \.self) { modality in
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
                    Button(NSLocalizedString("自定义Body", comment: "")) { showsRequestBody = true }
                    Button(NSLocalizedString("价格设置", comment: "")) { showsPricing = true }
                }
                if supportsConnectivityTest && draft.kind.supportsConnectivityTest {
                    Section {
                        Button(NSLocalizedString("模型测试", comment: "")) { prepareTest() }
                            .disabled(!workspace.canRunModelTests || draft.modelName.isEmpty)
                        if let testError { Text(testError).font(.footnote).foregroundStyle(.red) }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isBusy || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("模型配置", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { save() }.disabled(isBusy || draft.modelName.isEmpty)
                }
            }
            .sheet(isPresented: $showsPricing) {
                MacModelPricingEditor(modelID: draft.id, pricing: draft.pricing, apiFormat: draft.effectiveAPIFormat(providerAPIFormat: providerAPIFormat)) {
                    draft.pricing = $0
                }
            }
            .sheet(isPresented: $showsRequestBody) {
                MacRequestBodyEditor(model: draft, apiFormat: draft.effectiveAPIFormat(providerAPIFormat: providerAPIFormat)) { body in
                    body.apply(to: &draft)
                }
            }
            .sheet(item: $testSource) { MacModelConnectivityTestView(source: $0) }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-model-\(draft.id)"), title: NSLocalizedString("模型配置", comment: ""),
                documents: [GuideDocumentReference(id: "provider-model-basics", title: "Provider and Model Basics")],
                settings: guideSettings
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 500, minHeight: 600)
        .interactiveDismissDisabled(isBusy)
        .onDisappear { saveTask?.cancel() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }

    private var guideSettings: [GuidePageSetting] {
        let state: [GuidePageSetting] = [
            .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("provider_draft_until_save") }),
            .readOnly("provider_api_format", label: NSLocalizedString("API 格式", comment: ""), value: { .string(providerAPIFormat) })
        ]
        guard !isBusy, !workspace.isRestoringData else { return state }
        return state + [
            .string("model_id", label: NSLocalizedString("模型 ID", comment: ""), get: { draft.modelName }, set: { draft.modelName = $0 }),
            .string("display_name", label: NSLocalizedString("显示名称", comment: ""), get: { draft.displayName }, set: { draft.displayName = $0 }),
            .string("picker_group", label: NSLocalizedString("分组名称", comment: ""), get: { draft.pickerGroupName ?? "" }, set: { draft.pickerGroupName = Model.normalizedPickerGroupName($0) }),
            .string("model_prompt", label: NSLocalizedString("model.prompt.title", comment: ""), get: { draft.prompt }, set: { draft.prompt = $0 }),
            .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { draft.isActivated }, set: { draft.isActivated = $0 }),
            .string("kind", label: NSLocalizedString("模型用途", comment: ""), allowedValues: ModelKind.allCases.map(\.rawValue), get: { draft.kind.rawValue }, set: {
                if let kind = ModelKind(rawValue: $0), draft.kind != kind { draft.resetCapabilityShape(for: kind) }
            })
        ] + (providerAPIFormat == LocalModelProviderBridge.apiFormat ? [] : [
            .string("api_format_override", label: NSLocalizedString("API 格式", comment: ""), allowedValues: [""] + ProviderAPIFormatOption.allCases.map(\.rawValue),
                    get: { draft.apiFormatOverride ?? "" }, set: { draft.apiFormatOverride = Model.normalizedAPIFormatOverride($0) })
        ]) + ModelModality.allCases.map { modality in
            .bool("input_\(modality.rawValue)", label: modality.localizedName, get: { draft.inputModalities.contains(modality) }, set: { enabled in
                draft.inputModalities.removeAll { $0 == modality }
                if enabled { draft.inputModalities.append(modality) }
            })
        } + ModelModality.outputCases.map { modality in
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

    private func prepareTest() {
        guard !isBusy, workspace.canRunModelTests else { return }
        let source = draft
        isBusy = true; testError = nil
        saveTask = Task {
            defer { isBusy = false }
            do {
                let prepared = try await prepareTestSource(source)
                guard !Task.isCancelled, workspace.canRunModelTests, draft == source else { return }
                testSource = prepared
            } catch { if !Task.isCancelled { testError = error.localizedDescription } }
        }
    }

    private func save() {
        guard !isBusy, !workspace.isRestoringData else { return }
        let source = draft
        let format = providerAPIFormat
        isBusy = true
        saveTask = Task {
            defer { isBusy = false }
            let updated = await Task.detached {
                var result = source
                // 编辑协议后按核心规则移除不适用的 1 小时缓存档位，遍历价格配置留在后台。
                let pricing = result.pricing?.normalized(forAPIFormat: result.effectiveAPIFormat(providerAPIFormat: format))
                result.pricing = pricing?.isEffectivelyEmpty == true ? nil : pricing
                if result.displayName.isEmpty { result.displayName = result.modelName }
                return result
            }.value
            guard !Task.isCancelled, !workspace.isRestoringData, draft == source else { return }
            onSave(updated)
            dismiss()
        }
    }
}

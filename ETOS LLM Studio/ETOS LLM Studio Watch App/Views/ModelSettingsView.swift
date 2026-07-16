// ============================================================================
// ModelSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 模型设置视图
//
// 定义内容:
// - 提供一个表单用于编辑模型的模型名称与模型ID
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct ModelSettingsView: View {
    @Binding var model: Model
    let provider: Provider
    let onSave: () -> Void
    @State var keyValueEntries: [KeyValueEntry] = []
    @State var expressionEntries: [ExpressionEntry] = []
    @State var requestBodyMode: Model.RequestBodyOverrideMode = .keyValue
    @State var rawJSONInput: String = "{}"
    @State var rawJSONError: String?
    @State var requestBodyControlImportSources: [RunnableModel] = []
    @State var isRequestBodyControlImportPresented = false

    init(model: Binding<Model>, provider: Provider, onSave: @escaping () -> Void = {}) {
        _model = model
        self.provider = provider
        self.onSave = onSave
    }
    
    var body: some View {
        let preview = requestBodyPreview

        Form {
            Section(
                header: Text(NSLocalizedString("基础信息", comment: "")),
                footer: Text(NSLocalizedString("模型ID是 API 调用时使用的真实标识，模型名称是 App 内展示给用户的别名。", comment: ""))
            ) {
                TextField(NSLocalizedString("模型名称", comment: ""), text: $model.displayName.watchKeyboardNewlineBinding())
                TextField(NSLocalizedString("模型ID", comment: ""), text: $model.modelName.watchKeyboardNewlineBinding())
            }

            if model.isChatModel && !LocalModelProviderBridge.isLocalProvider(provider) {
                Section {
                    NavigationLink {
                        SingleModelConnectivityTestView(provider: provider, model: model)
                    } label: {
                        Label(NSLocalizedString("模型测试", comment: "Model connectivity test title"), systemImage: "checkmark.seal")
                    }
                } footer: {
                    Text(NSLocalizedString("测试该模型的非流式、流式和工具调用能力。", comment: "Single model connectivity test entry footer"))
                }
            }

            Section(
                header: Text(NSLocalizedString("模型类型", comment: "模型类型区块标题")),
                footer: Text(kindFooterText)
            ) {
                Picker(NSLocalizedString("模型类型", comment: "模型类型选择器标题"), selection: kindBinding) {
                    ForEach(ModelKind.allCases, id: \.self) { kind in
                        Text(modelKindSelectionTitle(kind)).tag(kind)
                    }
                }
            }

            if model.kind == .chat {
                chatModelCapabilitySections
            } else {
                Section(
                    header: Text(NSLocalizedString("能力", comment: "模型能力区块标题")),
                    footer: Text(capabilityFooterText)
                ) {
                    specializedModelCapabilityRows
                }
            }

            Section(
                header: Text(NSLocalizedString("计费", comment: "Model billing section title")),
                footer: Text(NSLocalizedString("用于在消息详情中估算本地费用，仅供参考。", comment: "Watch model pricing section footer"))
            ) {
                NavigationLink {
                    ModelPricingSettingsView(pricing: $model.pricing)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("价格设置", comment: "Model pricing settings row title"))
                        Text(modelPricingSummary)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(header: Text(NSLocalizedString("自定义Body", comment: ""))) {
                Picker(NSLocalizedString("编辑方式", comment: ""), selection: $requestBodyMode) {
                    Text(NSLocalizedString("键值对", comment: "")).tag(Model.RequestBodyOverrideMode.keyValue)
                    Text(NSLocalizedString("参数表达式", comment: "")).tag(Model.RequestBodyOverrideMode.expression)
                    Text(NSLocalizedString("原始 JSON", comment: "")).tag(Model.RequestBodyOverrideMode.rawJSON)
                }
            }

            structuredControlsSection

            if requestBodyMode == .keyValue {
                Section(
                    header: Text(NSLocalizedString("键值对", comment: "")),
                    footer: Text(NSLocalizedString("值里用 \\n 可以打出换行；无方向引号需要长按输入法里的有方向引号。", comment: ""))
                ) {
                    ForEach($keyValueEntries) { $entry in
                        KeyValueRow(entry: $entry)
                            .onChange(of: entry.key, initial: false) { _, _ in
                                validateKeyValueEntry(withId: entry.id)
                            }
                            .onChange(of: entry.value, initial: false) { _, _ in
                                validateKeyValueEntry(withId: entry.id)
                            }
                    }
                    .onDelete(perform: deleteKeyValueEntries)

                    Button {
                        addKeyValueEntry()
                    } label: {
                        Label(NSLocalizedString("添加", comment: ""), systemImage: "plus")
                    }
                }
            } else if requestBodyMode == .expression {
                Section(header: Text(NSLocalizedString("参数表达式", comment: ""))) {
                    ForEach($expressionEntries) { $entry in
                        ExpressionRow(entry: $entry)
                            .onChange(of: entry.text, initial: false) { _, _ in
                                validateEntry(withId: entry.id)
                            }
                    }
                    .onDelete(perform: deleteEntries)
                    
                    Button {
                        addEmptyEntry()
                    } label: {
                        Label(NSLocalizedString("添加", comment: ""), systemImage: "plus")
                    }
                }
                
                Section(header: Text(NSLocalizedString("写法提示", comment: ""))) {
                    Text(NSLocalizedString("使用 key = value 格式，例如 thinking_budget = 128", comment: ""))
                    Text(NSLocalizedString("嵌套用 { }，例如 chat_template_kwargs = {thinking = false}", comment: ""))
                }
            } else {
                Section(
                    header: Text(NSLocalizedString("原始 JSON", comment: "")),
                    footer: Text(NSLocalizedString("用 \\n 可以打出换行；无方向引号需要长按输入法里的有方向引号。", comment: ""))
                ) {
                    TextField(NSLocalizedString("填写 JSON 对象", comment: ""),
                        text: $rawJSONInput.watchKeyboardNewlineBinding(),
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(6...16)
                    .onChange(of: rawJSONInput, initial: false) { _, newValue in
                        validateRawJSON(newValue)
                    }

                    Text(NSLocalizedString("示例：{\"extra_body\":{\"abc\":\"123\"}}", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)

                    if let rawJSONError {
                        Text(rawJSONError)
                            .etFont(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section(header: Text(NSLocalizedString("请求体预览", comment: ""))) {
                RequestBodyPreviewInlineView(preview: preview)
            }
        }
        .navigationDestination(isPresented: $isRequestBodyControlImportPresented) {
            RequestBodyControlImportView(sources: requestBodyControlImportSources) { source in
                model.appendCopiesOfRequestBodyControls(source.model.requestBodyControls)
            }
        }
        .navigationTitle(NSLocalizedString("编辑模型信息", comment: ""))
        .onAppear(perform: loadEditorState)
        .onDisappear(perform: saveEditorState)
    }
}

// MARK: - 内部状态

extension ModelSettingsView {
    struct KeyValueEntry: Identifiable, Equatable {
        let id: UUID
        var key: String
        var value: String
        var error: String?

        init(id: UUID = UUID(), key: String, value: String, error: String? = nil) {
            self.id = id
            self.key = key
            self.value = value
            self.error = error
        }
    }

    struct ExpressionEntry: Identifiable, Equatable {
        let id: UUID
        var text: String
        var error: String?
        
        init(id: UUID = UUID(), text: String, error: String? = nil) {
            self.id = id
            self.text = text
            self.error = error
        }
    }
    
    private var kindBinding: Binding<ModelKind> {
        Binding(
            get: { model.kind },
            set: { newKind in
                guard model.kind != newKind else { return }
                model.resetCapabilityShape(for: newKind)
            }
        )
    }

    private var kindFooterText: String {
        switch model.kind {
        case .chat:
            return NSLocalizedString("用于普通对话。下面只需要开启这个模型实际支持的增强能力。", comment: "聊天模型用途说明")
        case .image:
            return NSLocalizedString("用于图片生成，会出现在生图模型列表中。", comment: "图片生成模型用途说明")
        case .embedding:
            return NSLocalizedString("用于长期记忆和检索向量化，不会出现在聊天模型列表中。", comment: "嵌入模型用途说明")
        case .rerank:
            return NSLocalizedString("用于检索结果重排，通常配合知识库或搜索结果精排使用。", comment: "重排模型用途说明")
        case .speechToText:
            return NSLocalizedString("用于把录音转换为文字。", comment: "语音转文字模型用途说明")
        case .textToSpeech:
            return NSLocalizedString("用于把文字转换为语音。", comment: "文字转语音模型用途说明")
        }
    }

    private func modelKindSelectionTitle(_ kind: ModelKind) -> String {
        kind == .image ? ModelModality.image.localizedName : kind.localizedName
    }

    private var capabilityFooterText: String {
        switch model.kind {
        case .image:
            return NSLocalizedString("图片生成由用途决定；如果模型支持图生图，可以开启参考图片。", comment: "图片模型能力说明")
        case .embedding, .rerank, .speechToText, .textToSpeech:
            return NSLocalizedString("专用模型的输入和输出由用途决定，通常不需要额外配置。", comment: "专用模型能力说明")
        case .chat:
            return ""
        }
    }

    private var modelPricingSummary: String {
        guard let pricing = model.pricing?.normalized, !pricing.isEffectivelyEmpty else {
            return NSLocalizedString("未配置", comment: "Model pricing not configured summary")
        }
        if pricing.billingMode == .perRequest {
            var parts = [NSLocalizedString("按次计费", comment: "Per-request pricing summary")]
            if let perRequestPrice = pricing.perRequestPrice {
                parts.append(String(
                    format: NSLocalizedString("每次 %@", comment: "Per-request pricing value summary"),
                    MessageCostFormatter.formatPriceValue(perRequestPrice)
                ))
            } else {
                parts.append(NSLocalizedString("未填写价格", comment: "Pricing value missing summary"))
            }
            return parts.joined(separator: NSLocalizedString("，", comment: "List separator"))
        }
        let baseCount = [
            pricing.inputPerMillionTokens,
            pricing.outputPerMillionTokens,
            pricing.cacheWritePerMillionTokens,
            pricing.cacheReadPerMillionTokens
        ].compactMap { $0 }.count
        var parts: [String] = []
        if baseCount > 0 {
            parts.append(String(format: NSLocalizedString("已填写 %d 项", comment: "Model pricing configured fields summary"), baseCount))
        }
        if !pricing.tiers.isEmpty {
            parts.append(String(format: NSLocalizedString("%d 个阶梯", comment: "Model pricing tiers summary"), pricing.tiers.count))
        }
        if pricing.timeOverridesEnabled, !pricing.timeOverrides.isEmpty {
            parts.append(String(format: NSLocalizedString("%d 个峰谷时段", comment: "Peak valley pricing ranges summary"), pricing.timeOverrides.count))
        } else if !pricing.timeOverrides.isEmpty {
            parts.append(NSLocalizedString("峰谷已关闭", comment: "Peak valley pricing disabled summary"))
        }
        return parts.isEmpty
            ? NSLocalizedString("未配置", comment: "Model pricing not configured summary")
            : parts.joined(separator: NSLocalizedString("，", comment: "List separator"))
    }

    @ViewBuilder
    private var chatModelCapabilitySections: some View {
        Section(NSLocalizedString("输入模态", comment: "聊天模型输入模态区块标题")) {
            ForEach(ModelModality.allCases, id: \.self) { modality in
                Toggle(modality.localizedName, isOn: modalityBinding(modality, keyPath: \.inputModalities))
            }
        }

        Section(NSLocalizedString("输出模态", comment: "聊天模型输出模态区块标题")) {
            Toggle(ModelModality.text.localizedName, isOn: modalityBinding(.text, keyPath: \.outputModalities))
            Toggle(ModelModality.image.localizedName, isOn: modalityBinding(.image, keyPath: \.outputModalities))
        }

        Section {
            Toggle(ModelCapability.toolCalling.localizedName, isOn: capabilityBinding(.toolCalling))
            Toggle(ModelCapability.reasoning.localizedName, isOn: capabilityBinding(.reasoning))
        } header: {
            Text(NSLocalizedString("能力", comment: "聊天模型能力区块标题"))
        } footer: {
            Text(NSLocalizedString("推理能力开启后会自动添加思考预算控制；关闭能力不会删除已经配置的控制。", comment: "推理能力与结构化控制联动说明"))
        }
    }

    @ViewBuilder
    private var specializedModelCapabilityRows: some View {
        switch model.kind {
        case .image:
            Toggle(NSLocalizedString("支持参考图片", comment: "图片生成模型能力：参考图片输入"), isOn: modalityBinding(.image, keyPath: \.inputModalities))
        case .embedding:
            Text(NSLocalizedString("此模型用于生成文本向量。", comment: "嵌入模型能力说明"))
                .foregroundStyle(.secondary)
        case .rerank:
            Text(NSLocalizedString("此模型用于重新排序候选内容。", comment: "重排模型能力说明"))
                .foregroundStyle(.secondary)
        case .speechToText:
            Text(NSLocalizedString("此模型接收音频并输出文字。", comment: "语音转文字模型能力说明"))
                .foregroundStyle(.secondary)
        case .textToSpeech:
            Text(NSLocalizedString("此模型接收文字并输出语音。", comment: "文字转语音模型能力说明"))
                .foregroundStyle(.secondary)
        case .chat:
            EmptyView()
        }
    }

    private func modalityBinding(
        _ modality: ModelModality,
        keyPath: WritableKeyPath<Model, [ModelModality]>
    ) -> Binding<Bool> {
        Binding(
            get: {
                model[keyPath: keyPath].contains(modality)
            },
            set: { isEnabled in
                var modalities = model[keyPath: keyPath]
                if isEnabled {
                    modalities.append(modality)
                } else {
                    modalities.removeAll { $0 == modality }
                }
                if keyPath == \Model.outputModalities {
                    model[keyPath: keyPath] = Model.orderedOutputModalities(modalities)
                } else {
                    model[keyPath: keyPath] = Model.orderedModalities(modalities)
                }
            }
        )
    }

    private func capabilityBinding(_ capability: ModelCapability) -> Binding<Bool> {
        Binding(
            get: {
                model.capabilities.contains(capability)
            },
            set: { isEnabled in
                var capabilitySet = Set(model.capabilities)
                if isEnabled {
                    capabilitySet.insert(capability)
                    if capability == .reasoning {
                        model.ensureThinkingRequestBodyControl(apiFormat: provider.apiFormat)
                    }
                } else {
                    capabilitySet.remove(capability)
                }
                model.capabilities = Model.orderedCapabilities(Array(capabilitySet))
            }
        )
    }

}

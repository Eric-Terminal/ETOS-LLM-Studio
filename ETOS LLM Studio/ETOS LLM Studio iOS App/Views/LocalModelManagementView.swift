// ============================================================================
// LocalModelManagementView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 管理本机 GGUF 权重入口。
// ============================================================================

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Shared

struct LocalModelManagementView: View {
    @ObservedObject private var store = LocalModelStore.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var isImportingModel = false
    @State private var errorMessage: String?

    private let ggufType = UTType(filenameExtension: "gguf") ?? .data

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("启用本地模型提供商", comment: "Enable local model provider"), isOn: localModelsEnabledBinding)
            } footer: {
                Text(NSLocalizedString("关闭后不会删除权重；重新开启时会自动把“本地模型”提供商加回模型管理。", comment: "Local provider toggle footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    isImportingModel = true
                } label: {
                    Label(NSLocalizedString("导入 GGUF 权重", comment: "Import local GGUF model"), systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text(NSLocalizedString("导入后的权重只保存在本机，并会以“本地模型”出现在模型候选列表中。", comment: "Local model import footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.models.isEmpty {
                    Text(NSLocalizedString("还没有本地模型。", comment: "No local models"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.models) { record in
                        NavigationLink {
                            LocalModelDetailView(record: record)
                        } label: {
                            LocalModelRow(record: record, fileExists: store.fileExists(for: record))
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("权重", comment: "Local model weights section"))
            }
        }
        .navigationTitle(NSLocalizedString("本地模型", comment: "Local models title"))
        .fileImporter(
            isPresented: $isImportingModel,
            allowedContentTypes: [ggufType, .data],
            allowsMultipleSelection: false
        ) { result in
            importModel(result)
        }
        .alert(NSLocalizedString("本地模型", comment: "Local models alert title"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: "OK"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importModel(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            _ = try store.importModel(from: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var localModelsEnabledBinding: Binding<Bool> {
        Binding {
            appConfig.localModelsEnabled
        } set: { isEnabled in
            appConfig.localModelsEnabled = isEnabled
            ChatService.shared.setLocalModelsEnabled(isEnabled)
        }
    }
}

private struct LocalModelRow: View {
    let record: LocalModelRecord
    let fileExists: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fileExists ? "cpu" : "exclamationmark.triangle")
                .etFont(.system(size: 17, weight: .semibold))
                .foregroundStyle(fileExists ? .blue : .orange)
                .frame(width: 32, height: 32)
                .background((fileExists ? Color.blue : Color.orange).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(record.sanitizedDisplayName)
                    .etFont(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(record.fileName) · \(StorageUtility.formatSize(record.fileSize))")
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !record.isActivated {
                Text(NSLocalizedString("未启用", comment: "Inactive local model"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            } else if !fileExists {
                Text(NSLocalizedString("缺文件", comment: "Missing local model file"))
                    .etFont(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LocalModelDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LocalModelStore.shared
    @State private var draft: LocalModelRecord
    @State private var showDeleteAlert = false
    @State private var showAdvancedIntro = false
    @State private var showCLIImport = false
    @State private var cliImportResult: LocalLLMCLIStyleImportResult?
    @State private var contextSizeText: String
    @State private var maxOutputTokensText: String
    @State private var gpuLayersText: String
    @State private var seedText: String
    @State private var temperatureText: String
    @State private var topKText: String
    @State private var topPText: String
    @State private var minPText: String
    @State private var repeatLastNText: String
    @State private var repeatPenaltyText: String
    @State private var frequencyPenaltyText: String
    @State private var presencePenaltyText: String

    init(record: LocalModelRecord) {
        _draft = State(initialValue: record)
        _contextSizeText = State(initialValue: "\(record.effectiveContextSize)")
        _maxOutputTokensText = State(initialValue: "\(record.effectiveMaxOutputTokens)")
        _gpuLayersText = State(initialValue: "\(record.effectiveGPULayers)")
        _seedText = State(initialValue: "\(record.effectiveSeed)")
        _temperatureText = State(initialValue: LocalModelFormat.decimal(record.effectiveTemperature))
        _topKText = State(initialValue: "\(record.effectiveTopK)")
        _topPText = State(initialValue: LocalModelFormat.decimal(record.effectiveTopP))
        _minPText = State(initialValue: LocalModelFormat.decimal(record.effectiveMinP))
        _repeatLastNText = State(initialValue: "\(record.effectiveRepeatLastN)")
        _repeatPenaltyText = State(initialValue: LocalModelFormat.decimal(record.effectiveRepeatPenalty))
        _frequencyPenaltyText = State(initialValue: LocalModelFormat.decimal(record.effectiveFrequencyPenalty))
        _presencePenaltyText = State(initialValue: LocalModelFormat.decimal(record.effectivePresencePenalty))
    }

    var body: some View {
        Form {
            Section {
                LocalModelAdvancedIntroCard(isExpanded: $showAdvancedIntro)
            }

            Section {
                TextField(NSLocalizedString("名称", comment: "Local model display name field"), text: $draft.displayName)
                Toggle(NSLocalizedString("加入候选模型", comment: "Activate local model"), isOn: $draft.isActivated)
            }

            runtimeSection
            samplingSection
            grammarSection
            samplerChainSection
            experimentSection

            Section {
                LabeledContent(NSLocalizedString("文件", comment: "Local model file label"), value: draft.fileName)
                LabeledContent(NSLocalizedString("大小", comment: "Local model size label"), value: StorageUtility.formatSize(draft.fileSize))
                LabeledContent(NSLocalizedString("状态", comment: "Local model file status")) {
                    Text(store.fileExists(for: draft)
                        ? NSLocalizedString("文件可用", comment: "Local model file exists")
                        : NSLocalizedString("文件缺失", comment: "Local model file missing"))
                        .foregroundStyle(store.fileExists(for: draft) ? Color.secondary : Color.orange)
                }
            }

            Section {
                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label(NSLocalizedString("删除权重", comment: "Delete local model"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(draft.sanitizedDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCLIImport) {
            NavigationStack {
                LocalModelCLIStyleImportView(record: draft) { result in
                    draft = result.updatedRecord
                    cliImportResult = result
                    refreshTextFieldsFromDraft()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "Save")) {
                    applyDraftNumbers()
                    store.update(draft)
                    dismiss()
                }
            }
        }
        .alert(NSLocalizedString("删除本地模型", comment: "Delete local model alert"), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                store.delete(draft)
                dismiss()
            }
        } message: {
            Text(NSLocalizedString("会同时删除本机保存的权重文件。", comment: "Delete local model alert message"))
        }
    }

    private var runtimeSection: some View {
        Section {
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "contextSize"),
                text: $contextSizeText,
                isEnabled: overrideEnabledBinding(\.contextSize, defaultValue: LocalModelRecord.defaultContextSize),
                keyboardType: .numberPad
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "maxOutputTokens"),
                text: $maxOutputTokensText,
                isEnabled: overrideEnabledBinding(\.maxOutputTokens, defaultValue: LocalModelRecord.defaultMaxOutputTokens),
                keyboardType: .numberPad
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "gpuLayers"),
                text: $gpuLayersText,
                isEnabled: overrideEnabledBinding(\.gpuLayers, defaultValue: LocalModelRecord.defaultGPULayers),
                keyboardType: .numbersAndPunctuation
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "seed"),
                text: $seedText,
                isEnabled: overrideEnabledBinding(\.seed, defaultValue: LocalModelRecord.defaultSeed),
                keyboardType: .numbersAndPunctuation
            )
        } header: {
            Text(NSLocalizedString("运行时", comment: "Local model runtime section"))
        }
    }

    private var samplingSection: some View {
        Section {
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "temperature"),
                text: $temperatureText,
                isEnabled: overrideEnabledBinding(\.temperature, defaultValue: LocalModelRecord.defaultTemperature),
                keyboardType: .decimalPad
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "topK"),
                text: $topKText,
                isEnabled: overrideEnabledBinding(\.topK, defaultValue: LocalModelRecord.defaultTopK),
                keyboardType: .numberPad
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "topP"),
                text: $topPText,
                isEnabled: overrideEnabledBinding(\.topP, defaultValue: LocalModelRecord.defaultTopP),
                keyboardType: .decimalPad
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "minP"),
                text: $minPText,
                isEnabled: overrideEnabledBinding(\.minP, defaultValue: LocalModelRecord.defaultMinP),
                keyboardType: .decimalPad
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "repeatLastN"),
                text: $repeatLastNText,
                isEnabled: overrideEnabledBinding(\.repeatLastN, defaultValue: LocalModelRecord.defaultRepeatLastN),
                keyboardType: .numbersAndPunctuation
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "repeatPenalty"),
                text: $repeatPenaltyText,
                isEnabled: overrideEnabledBinding(\.repeatPenalty, defaultValue: LocalModelRecord.defaultRepeatPenalty),
                keyboardType: .decimalPad
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "frequencyPenalty"),
                text: $frequencyPenaltyText,
                isEnabled: overrideEnabledBinding(\.frequencyPenalty, defaultValue: LocalModelRecord.defaultFrequencyPenalty),
                keyboardType: .numbersAndPunctuation
            )
            LocalModelParameterTextField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "presencePenalty"),
                text: $presencePenaltyText,
                isEnabled: overrideEnabledBinding(\.presencePenalty, defaultValue: LocalModelRecord.defaultPresencePenalty),
                keyboardType: .numbersAndPunctuation
            )
        } header: {
            Text(NSLocalizedString("采样", comment: "Local model sampling section"))
        }
    }

    private var grammarSection: some View {
        Section {
            LocalModelGrammarField(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "grammar"),
                text: grammarTextBinding,
                isEnabled: overrideEnabledBinding(\.grammar, defaultValue: LocalModelRecord.defaultGrammar)
            )
            LocalModelToggleParameterRow(
                descriptor: LocalLLMParameterCatalog.descriptor(for: "ignoreEOS"),
                value: ignoreEOSBinding,
                isEnabled: overrideEnabledBinding(\.ignoreEOS, defaultValue: true)
            )
        } header: {
            Text(NSLocalizedString("输出约束", comment: "Local model grammar section"))
        }
    }

    private var samplerChainSection: some View {
        Section {
            LabeledContent(NSLocalizedString("采样链", comment: "Sampler chain status")) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(isDefaultSamplerChain ? NSLocalizedString("默认", comment: "Default sampler chain") : NSLocalizedString("自定义", comment: "Custom sampler chain"))
                    Text(LocalLLMSamplerKind.chainString(draft.effectiveSamplerKinds))
                        .etFont(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                LocalModelSamplerChainLabView(samplerKinds: $draft.samplerKinds)
            } label: {
                Label(NSLocalizedString("进入采样器链实验室", comment: "Open sampler chain lab"), systemImage: "slider.horizontal.3")
            }
        } header: {
            Text(NSLocalizedString("采样器链", comment: "Local sampler chain section"))
        } footer: {
            Text(LocalLLMParameterCatalog.descriptor(for: "samplerKinds").summary)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var experimentSection: some View {
        Section {
            Button {
                showCLIImport = true
            } label: {
                Label(NSLocalizedString("llama.cpp-style 参数导入", comment: "Local llama style import"), systemImage: "square.and.arrow.down.on.square")
            }

            if !draft.advancedArguments.isEmpty {
                Button {
                    let result = LocalLLMCLIStyleArgumentImporter.importArguments(draft.advancedArguments, into: draft)
                    draft = result.updatedRecord
                    cliImportResult = result
                    refreshTextFieldsFromDraft()
                } label: {
                    Label(NSLocalizedString("导入旧版覆盖参数到表单", comment: "Import legacy local llama args"), systemImage: "arrow.triangle.2.circlepath")
                }
            }

            if let cliImportResult {
                LocalModelCLIImportSummary(result: cliImportResult)
            }
        } header: {
            Text(NSLocalizedString("实验区", comment: "Local model experiments section"))
        } footer: {
            Text(NSLocalizedString("支持常用 llama.cpp 风格参数，不等于完整 llama.cpp CLI。导入后会转换为 App 的本地配置。", comment: "Local llama style import footer"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }
    }

    private var isDefaultSamplerChain: Bool {
        draft.samplerKinds == nil || LocalLLMSamplerKind.unique(draft.samplerKinds ?? []) == LocalLLMSamplerKind.defaultChain
    }

    private func applyDraftNumbers() {
        if draft.contextSize != nil, let contextSize = Int(contextSizeText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.contextSize = contextSize
        }
        if draft.maxOutputTokens != nil, let maxOutputTokens = Int(maxOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.maxOutputTokens = maxOutputTokens
        }
        if draft.gpuLayers != nil, let gpuLayers = Int(gpuLayersText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.gpuLayers = gpuLayers
        }
        if draft.seed != nil, let seed = parseSeed(seedText) {
            draft.seed = seed
        }
        if draft.temperature != nil, let temperature = Double(temperatureText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.temperature = temperature
        }
        if draft.topK != nil, let topK = Int(topKText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.topK = topK
        }
        if draft.topP != nil, let topP = Double(topPText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.topP = topP
        }
        if draft.minP != nil, let minP = Double(minPText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.minP = minP
        }
        if draft.repeatLastN != nil, let repeatLastN = Int(repeatLastNText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.repeatLastN = repeatLastN
        }
        if draft.repeatPenalty != nil, let repeatPenalty = Double(repeatPenaltyText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.repeatPenalty = repeatPenalty
        }
        if draft.frequencyPenalty != nil, let frequencyPenalty = Double(frequencyPenaltyText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.frequencyPenalty = frequencyPenalty
        }
        if draft.presencePenalty != nil, let presencePenalty = Double(presencePenaltyText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            draft.presencePenalty = presencePenalty
        }
        draft.advancedArguments = ""
        draft.normalizeGenerationParameters()
        refreshTextFieldsFromDraft()
    }

    private func refreshTextFieldsFromDraft() {
        contextSizeText = "\(draft.effectiveContextSize)"
        maxOutputTokensText = "\(draft.effectiveMaxOutputTokens)"
        gpuLayersText = "\(draft.effectiveGPULayers)"
        seedText = "\(draft.effectiveSeed)"
        temperatureText = LocalModelFormat.decimal(draft.effectiveTemperature)
        topKText = "\(draft.effectiveTopK)"
        topPText = LocalModelFormat.decimal(draft.effectiveTopP)
        minPText = LocalModelFormat.decimal(draft.effectiveMinP)
        repeatLastNText = "\(draft.effectiveRepeatLastN)"
        repeatPenaltyText = LocalModelFormat.decimal(draft.effectiveRepeatPenalty)
        frequencyPenaltyText = LocalModelFormat.decimal(draft.effectiveFrequencyPenalty)
        presencePenaltyText = LocalModelFormat.decimal(draft.effectivePresencePenalty)
    }

    private func parseSeed(_ rawValue: String) -> UInt32? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "-1" {
            return LocalModelRecord.defaultSeed
        }
        return UInt32(trimmed)
    }

    private func overrideEnabledBinding<Value>(
        _ keyPath: WritableKeyPath<LocalModelRecord, Value?>,
        defaultValue: Value
    ) -> Binding<Bool> {
        Binding {
            draft[keyPath: keyPath] != nil
        } set: { isEnabled in
            if isEnabled {
                draft[keyPath: keyPath] = defaultValue
            } else {
                draft[keyPath: keyPath] = nil
            }
            refreshTextFieldsFromDraft()
        }
    }

    private var grammarTextBinding: Binding<String> {
        Binding {
            draft.grammar ?? ""
        } set: { newValue in
            draft.grammar = newValue
        }
    }

    private var ignoreEOSBinding: Binding<Bool> {
        Binding {
            draft.ignoreEOS ?? LocalModelRecord.defaultIgnoreEOS
        } set: { newValue in
            draft.ignoreEOS = newValue
        }
    }
}

private struct LocalModelAdvancedIntroCard: View {
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("本地模型调参", comment: "Local model tuning intro title"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString("这里保存 App 自己的结构化配置，再映射到 llama.cpp C ABI。", comment: "Local model tuning intro summary"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "Local model tuning intro details"))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString("普通高级设置使用 iOS 原生表单保存结构化参数；只有开启“自定义”的项目才会作为模型覆盖项保存。未开启的项目会沿用 App 默认或全局聊天设置，并在调用前映射到 llama.cpp C ABI。llama.cpp-style 参数导入只支持常用子集，会转换成这些覆盖项。App 不执行 llama.cpp CLI，也不会把命令行字符串当成本地推理的主交互。上下文长度和 GPU 层数通常需要重建 context；采样参数会在下一次请求或下一次采样链创建时生效。", comment: "Local model tuning intro details body"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString("本地模型调参", comment: "Local model tuning intro sheet title"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

private struct LocalModelParameterTextField: View {
    let descriptor: LocalLLMParameterDescriptor
    @Binding var text: String
    @Binding var isEnabled: Bool
    var keyboardType: UIKeyboardType = .numberPad

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .etFont(.subheadline.weight(.medium))
                    if !descriptor.aliasText.isEmpty {
                        Text(descriptor.aliasText)
                            .etFont(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Toggle(NSLocalizedString("自定义", comment: "Enable local parameter override"), isOn: $isEnabled)
                    .labelsHidden()
            }

            if isEnabled {
                TextField(descriptor.title, text: $text)
                    .keyboardType(keyboardType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            }

            Text(descriptor.summary)
                .etFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(isEnabled
                    ? NSLocalizedString("覆盖默认", comment: "Local parameter custom override enabled")
                    : String(format: NSLocalizedString("使用默认 %@", comment: "Local parameter default label"), descriptor.defaultValue))
                Text(descriptor.effectScope)
            }
            .etFont(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct LocalModelToggleParameterRow: View {
    let descriptor: LocalLLMParameterDescriptor
    @Binding var value: Bool
    @Binding var isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .etFont(.subheadline.weight(.medium))
                    Text(descriptor.aliasText)
                        .etFont(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(NSLocalizedString("自定义", comment: "Enable local parameter override"), isOn: $isEnabled)
                    .labelsHidden()
            }
            if isEnabled {
                Toggle(NSLocalizedString("开启", comment: "Enable bool local parameter"), isOn: $value)
            }
            Text(descriptor.summary)
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Text("\(isEnabled ? NSLocalizedString("覆盖默认", comment: "Local parameter custom override enabled") : String(format: NSLocalizedString("使用默认 %@", comment: "Local parameter default label"), descriptor.defaultValue)) · \(descriptor.effectScope)")
                .etFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct LocalModelGrammarField: View {
    let descriptor: LocalLLMParameterDescriptor
    @Binding var text: String
    @Binding var isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .etFont(.subheadline.weight(.medium))
                    Text(descriptor.aliasText)
                        .etFont(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(NSLocalizedString("自定义", comment: "Enable local parameter override"), isOn: $isEnabled)
                    .labelsHidden()
            }
            if isEnabled {
                TextEditor(text: $text)
                    .frame(minHeight: 88)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
            }
            Text(descriptor.summary)
                .etFont(.caption)
                .foregroundStyle(.secondary)
            Text("\(isEnabled ? NSLocalizedString("覆盖默认", comment: "Local parameter custom override enabled") : String(format: NSLocalizedString("使用默认 %@", comment: "Local parameter default label"), descriptor.defaultValue)) · \(descriptor.effectScope)")
                .etFont(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct LocalModelCLIStyleImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = "--temp 0.7 --top-p 0.9 --ctx-size 4096"
    @State private var result: LocalLLMCLIStyleImportResult?

    let record: LocalModelRecord
    let onApply: (LocalLLMCLIStyleImportResult) -> Void

    var body: some View {
        Form {
            Section {
                TextEditor(text: $inputText)
                    .frame(minHeight: 110)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
            } header: {
                Text(NSLocalizedString("llama.cpp-style 参数导入", comment: "Local llama style import title"))
            } footer: {
                Text(NSLocalizedString("支持常用 llama.cpp 风格参数，不等于完整 llama.cpp CLI。导入后会转换为 App 的本地配置。", comment: "Local llama style import explanation"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    let importResult = LocalLLMCLIStyleArgumentImporter.importArguments(inputText, into: record)
                    result = importResult
                    onApply(importResult)
                } label: {
                    Label(NSLocalizedString("解析并应用到表单", comment: "Apply local llama style import"), systemImage: "checkmark.circle")
                }
            }

            if let result {
                LocalModelCLIImportResultSections(result: result)
            }
        }
        .navigationTitle(NSLocalizedString("参数导入", comment: "Local llama style import navigation title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("完成", comment: "Done")) {
                    dismiss()
                }
            }
        }
    }
}

private struct LocalModelCLIImportResultSections: View {
    let result: LocalLLMCLIStyleImportResult

    var body: some View {
        Section {
            if result.appliedParameters.isEmpty {
                Text(NSLocalizedString("没有应用任何参数。", comment: "No applied local llama import params"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.appliedParameters) { item in
                    LabeledContent(item.title) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(item.value)
                            Text(item.option)
                                .etFont(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("已应用参数", comment: "Applied local llama import params"))
        }

        Section {
            if result.unsupportedParameters.isEmpty {
                Text(NSLocalizedString("没有不支持参数。", comment: "No unsupported local llama import params"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.unsupportedParameters) { item in
                    LocalModelImportIssueRow(issue: item, color: .orange)
                }
            }
        } header: {
            Text(NSLocalizedString("不支持参数", comment: "Unsupported local llama import params"))
        }

        Section {
            if result.errorParameters.isEmpty {
                Text(NSLocalizedString("没有出错参数。", comment: "No invalid local llama import params"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.errorParameters) { item in
                    LocalModelImportIssueRow(issue: item, color: .red)
                }
            }
        } header: {
            Text(NSLocalizedString("出错参数", comment: "Invalid local llama import params"))
        }
    }
}

private struct LocalModelCLIImportSummary: View {
    let result: LocalLLMCLIStyleImportResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("最近一次导入结果", comment: "Last local llama import summary title"))
                .etFont(.footnote.weight(.medium))
            Text(String(format: NSLocalizedString("已应用 %d 个，不支持 %d 个，出错 %d 个。", comment: "Last local llama import summary"), result.appliedParameters.count, result.unsupportedParameters.count, result.errorParameters.count))
                .etFont(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct LocalModelImportIssueRow: View {
    let issue: LocalLLMCLIStyleImportIssue
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(issue.option)
                .etFont(.subheadline.monospaced())
                .foregroundStyle(color)
            Text(issue.message)
                .etFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LocalModelSamplerChainLabView: View {
    @Binding var samplerKinds: [LocalLLMSamplerKind]?

    private var currentKinds: [LocalLLMSamplerKind] {
        samplerKinds ?? LocalLLMSamplerKind.defaultChain
    }

    var body: some View {
        List {
            Section {
                LabeledContent(NSLocalizedString("状态", comment: "Sampler chain override state")) {
                    Text(samplerKinds == nil
                        ? NSLocalizedString("使用默认", comment: "Use default sampler chain")
                        : NSLocalizedString("自定义", comment: "Custom sampler chain"))
                }
                LabeledContent(NSLocalizedString("等价字符串", comment: "Sampler chain string")) {
                    Text(LocalLLMSamplerKind.chainString(currentKinds))
                        .etFont(.body.monospaced())
                }
                Button {
                    samplerKinds = nil
                } label: {
                    Label(NSLocalizedString("重置为默认", comment: "Reset sampler chain to default"), systemImage: "arrow.counterclockwise")
                }
            }

            Section {
                ForEach(LocalLLMSamplerChainPreset.allPresets) { preset in
                    Button {
                        samplerKinds = preset.samplerKinds == LocalLLMSamplerKind.defaultChain ? nil : preset.samplerKinds
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(preset.title)
                                Spacer()
                                Text(preset.chainString)
                                    .etFont(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(preset.summary)
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(NSLocalizedString("预设链", comment: "Sampler chain presets"))
            }

            Section {
                if currentKinds.isEmpty {
                    Text(NSLocalizedString("当前链为空。", comment: "Empty sampler chain"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(currentKinds, id: \.self) { kind in
                        LocalModelSamplerKindRow(kind: kind)
                    }
                    .onMove { source, destination in
                        var updatedKinds = currentKinds
                        updatedKinds.move(fromOffsets: source, toOffset: destination)
                        samplerKinds = updatedKinds
                    }
                    .onDelete { offsets in
                        var updatedKinds = currentKinds
                        updatedKinds.remove(atOffsets: offsets)
                        samplerKinds = updatedKinds
                    }
                }
            } header: {
                Text(NSLocalizedString("当前采样链", comment: "Current sampler chain"))
            } footer: {
                Text(NSLocalizedString("拖拽可重排，左滑可移除；同一种 sampler 不会重复加入。", comment: "Sampler chain reorder footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(LocalLLMSamplerKind.allCases.filter { !currentKinds.contains($0) }) { kind in
                    Button {
                        samplerKinds = currentKinds + [kind]
                    } label: {
                        LocalModelSamplerKindRow(kind: kind)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(NSLocalizedString("可用采样器", comment: "Available samplers"))
            }
        }
        .navigationTitle(NSLocalizedString("采样器链实验室", comment: "Sampler chain lab title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }
}

private struct LocalModelSamplerKindRow: View {
    let kind: LocalLLMSamplerKind

    var body: some View {
        HStack(spacing: 12) {
            Text(kind.code)
                .etFont(.headline.monospaced().weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(kind.localizedTitle) · \(kind.title)")
                    .etFont(.subheadline.weight(.medium))
                Text(kind.summary)
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private enum LocalModelFormat {
    static func decimal(_ value: Double) -> String {
        let rounded = (value * 1_000).rounded() / 1_000
        if rounded.rounded() == rounded {
            return String(Int(rounded))
        }
        return String(rounded)
    }
}

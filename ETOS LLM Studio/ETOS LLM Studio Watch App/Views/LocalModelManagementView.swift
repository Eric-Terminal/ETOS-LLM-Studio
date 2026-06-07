// ============================================================================
// LocalModelManagementView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 管理手表端本机 GGUF 权重入口。
// ============================================================================

import SwiftUI
import ETOSCore

struct LocalModelManagementView: View {
    @ObservedObject private var store = LocalModelStore.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var downloadURLText = ""
    @State private var displayName = ""
    @State private var isDownloading = false
    @State private var downloadProgress: SyncPackageDownloadProgress?
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("启用本地模型提供商", comment: "Enable local model provider"), isOn: localModelsEnabledBinding)
            } footer: {
                Text(NSLocalizedString("关闭后不会删除权重；重新开启时会自动恢复到模型管理。", comment: "Watch local provider toggle footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(NSLocalizedString("模型文件链接", comment: "Local model download URL"), text: $downloadURLText.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                TextField(NSLocalizedString("名称", comment: "Local model display name"), text: $displayName.watchKeyboardNewlineBinding())
                Button {
                    downloadModel()
                } label: {
                    if isDownloading {
                        ProgressView()
                    } else {
                        Label(NSLocalizedString("下载权重", comment: "Download local model"), systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isDownloading || normalizedURL == nil)

                if let downloadProgress {
                    LocalModelDownloadProgressView(progress: downloadProgress)
                }
            } footer: {
                Text(NSLocalizedString("下载后的模型只保存在当前手表。", comment: "Watch local model download footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if store.models.isEmpty {
                    Text(NSLocalizedString("还没有本地模型。", comment: "No local models"))
                        .etFont(.caption2)
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
    }

    private var localModelsEnabledBinding: Binding<Bool> {
        Binding {
            appConfig.localModelsEnabled
        } set: { isEnabled in
            appConfig.localModelsEnabled = isEnabled
            ChatService.shared.setLocalModelsEnabled(isEnabled)
        }
    }

    private var normalizedURL: URL? {
        let text = downloadURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    private func downloadModel() {
        guard let url = normalizedURL else { return }
        let requestedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        isDownloading = true
        downloadProgress = nil
        statusMessage = nil
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = NetworkSessionConfiguration.minimumRequestTimeout
                let (downloadedURL, response) = try await SyncPackageUploadService.downloadTemporaryFile(
                    request: request,
                    progress: { progress in
                        Task { @MainActor in
                            downloadProgress = progress
                        }
                    }
                )
                defer { try? FileManager.default.removeItem(at: downloadedURL) }
                try validateDownloadResponse(response)
                let suggestedName = url.lastPathComponent.isEmpty ? "model.gguf" : url.lastPathComponent
                let completedSize = downloadedFileSize(at: downloadedURL)
                try await MainActor.run {
                    _ = try store.registerDownloadedModel(
                        fileAt: downloadedURL,
                        suggestedFileName: suggestedName,
                        displayName: requestedDisplayName.isEmpty ? nil : requestedDisplayName
                    )
                    downloadProgress = SyncPackageDownloadProgress(
                        bytesReceived: completedSize,
                        totalBytes: completedSize
                    )
                    downloadURLText = ""
                    displayName = ""
                    statusMessage = NSLocalizedString("下载完成。", comment: "Local model download completed")
                    isDownloading = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = error.localizedDescription
                    isDownloading = false
                    downloadProgress = nil
                }
            }
        }
    }

    private func validateDownloadResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              !(200..<300).contains(httpResponse.statusCode) else {
            return
        }
        throw NSError(domain: "ETOSWatchLocalModelDownload", code: httpResponse.statusCode, userInfo: [
            NSLocalizedDescriptionKey: String(
                format: NSLocalizedString("下载权重失败（HTTP %d）。", comment: "Local model download HTTP failure"),
                httpResponse.statusCode
            )
        ])
    }

    private func downloadedFileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

private struct LocalModelDownloadProgressView: View {
    let progress: SyncPackageDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(NSLocalizedString("下载进度", comment: ""))
                Spacer()
                if progress.totalBytes > 0 {
                    Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                        .monospacedDigit()
                }
            }
            .etFont(.caption2)

            if progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text(
                    String(
                        format: NSLocalizedString("已下载 %@ / %@", comment: ""),
                        StorageUtility.formatSize(progress.bytesReceived),
                        StorageUtility.formatSize(progress.totalBytes)
                    )
                )
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LocalModelRow: View {
    let record: LocalModelRecord
    let fileExists: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: fileExists ? "cpu" : "exclamationmark.triangle")
                    .foregroundStyle(fileExists ? .blue : .orange)
                Text(record.sanitizedDisplayName)
                    .lineLimit(1)
                Spacer()
            }
            Text(StorageUtility.formatSize(record.fileSize))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            if !record.isActivated {
                Text(NSLocalizedString("未启用", comment: "Inactive local model"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            } else if !fileExists {
                Text(NSLocalizedString("文件缺失", comment: "Missing local model file"))
                    .etFont(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct LocalModelDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = LocalModelStore.shared
    @State private var draft: LocalModelRecord
    @State private var showDeleteAlert = false
    @State private var showCLIImport = false
    @State private var cliImportResult: LocalLLMCLIStyleImportResult?
    @State private var contextSizeText: String
    @State private var maxOutputTokensText: String
    @State private var seedText: String
    @State private var temperatureText: String
    @State private var topKText: String
    @State private var topPText: String
    @State private var minPText: String
    @State private var repeatLastNText: String
    @State private var repeatPenaltyText: String
    @State private var frequencyPenaltyText: String
    @State private var presencePenaltyText: String

    private static let watchOSGPULayers = 0

    init(record: LocalModelRecord) {
        var initialDraft = record
        initialDraft.gpuLayers = Self.watchOSGPULayers
        _draft = State(initialValue: initialDraft)
        _contextSizeText = State(initialValue: "\(initialDraft.effectiveContextSize)")
        _maxOutputTokensText = State(initialValue: "\(initialDraft.effectiveMaxOutputTokens)")
        _seedText = State(initialValue: "\(initialDraft.effectiveSeed)")
        _temperatureText = State(initialValue: LocalModelFormat.decimal(initialDraft.effectiveTemperature))
        _topKText = State(initialValue: "\(initialDraft.effectiveTopK)")
        _topPText = State(initialValue: LocalModelFormat.decimal(initialDraft.effectiveTopP))
        _minPText = State(initialValue: LocalModelFormat.decimal(initialDraft.effectiveMinP))
        _repeatLastNText = State(initialValue: "\(initialDraft.effectiveRepeatLastN)")
        _repeatPenaltyText = State(initialValue: LocalModelFormat.decimal(initialDraft.effectiveRepeatPenalty))
        _frequencyPenaltyText = State(initialValue: LocalModelFormat.decimal(initialDraft.effectiveFrequencyPenalty))
        _presencePenaltyText = State(initialValue: LocalModelFormat.decimal(initialDraft.effectivePresencePenalty))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LocalModelAdvancedIntroView()
                } label: {
                    Label(NSLocalizedString("本地模型设置指南", comment: "Local model guide title"), systemImage: "book.pages")
                }
            } footer: {
                Text(NSLocalizedString("先读指南，再进入各参数二级页编辑；这样可以减少手表端误触。", comment: "Watch local model guide footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(NSLocalizedString("名称", comment: "Local model display name"), text: $draft.displayName.watchKeyboardNewlineBinding())
                Toggle(NSLocalizedString("加入候选模型", comment: "Activate local model"), isOn: $draft.isActivated)
            }

            runtimeSection
            samplingSection
            grammarSection
            samplerChainSection
            experimentSection

            Section {
                Text(draft.fileName)
                    .etFont(.caption2)
                    .lineLimit(2)
                Text(StorageUtility.formatSize(draft.fileSize))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                Text(store.fileExists(for: draft)
                    ? NSLocalizedString("文件可用", comment: "Local model file exists")
                    : NSLocalizedString("文件缺失", comment: "Local model file missing"))
                    .etFont(.caption2)
                    .foregroundStyle(store.fileExists(for: draft) ? Color.secondary : Color.orange)
            }

            Section {
                Button {
                    applyDraftNumbers()
                    store.update(draft)
                    dismiss()
                } label: {
                    Label(NSLocalizedString("保存", comment: "Save"), systemImage: "checkmark")
                }

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label(NSLocalizedString("删除权重", comment: "Delete local model"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(draft.sanitizedDisplayName)
        .sheet(isPresented: $showCLIImport) {
            NavigationStack {
                LocalModelCLIStyleImportView(record: draft) { result in
                    draft = result.updatedRecord
                    cliImportResult = result
                    refreshTextFieldsFromDraft()
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
            Text(NSLocalizedString("会同时删除手表上保存的权重文件。", comment: "Watch delete local model alert message"))
        }
    }

    private var runtimeSection: some View {
        Section {
            parameterEditorLink(
                descriptorID: "contextSize",
                text: $contextSizeText,
                isEnabled: overrideEnabledBinding(\.contextSize, defaultValue: LocalModelRecord.defaultContextSize)
            )
            parameterEditorLink(
                descriptorID: "maxOutputTokens",
                text: $maxOutputTokensText,
                isEnabled: overrideEnabledBinding(\.maxOutputTokens, defaultValue: LocalModelRecord.defaultMaxOutputTokens)
            )
            let gpuLayersDescriptor = LocalLLMParameterCatalog.descriptor(for: "gpuLayers")
            LocalModelParameterSummaryRow(
                descriptor: gpuLayersDescriptor,
                isEnabled: true,
                valueText: NSLocalizedString("0（固定）", comment: "Fixed watchOS GPU layers value")
            )
            parameterEditorLink(
                descriptorID: "seed",
                text: $seedText,
                isEnabled: overrideEnabledBinding(\.seed, defaultValue: LocalModelRecord.defaultSeed)
            )
        } header: {
            Text(NSLocalizedString("运行时", comment: "Local model runtime section"))
        } footer: {
            Text(NSLocalizedString("watchOS 本地推理只能使用 CPU 路径，GPU 层数固定为 0。", comment: "Watch fixed GPU layers footer"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var samplingSection: some View {
        Section {
            parameterEditorLink(
                descriptorID: "temperature",
                text: $temperatureText,
                isEnabled: overrideEnabledBinding(\.temperature, defaultValue: LocalModelRecord.defaultTemperature)
            )
            parameterEditorLink(
                descriptorID: "topK",
                text: $topKText,
                isEnabled: overrideEnabledBinding(\.topK, defaultValue: LocalModelRecord.defaultTopK)
            )
            parameterEditorLink(
                descriptorID: "topP",
                text: $topPText,
                isEnabled: overrideEnabledBinding(\.topP, defaultValue: LocalModelRecord.defaultTopP)
            )
            parameterEditorLink(
                descriptorID: "minP",
                text: $minPText,
                isEnabled: overrideEnabledBinding(\.minP, defaultValue: LocalModelRecord.defaultMinP)
            )
            parameterEditorLink(
                descriptorID: "repeatLastN",
                text: $repeatLastNText,
                isEnabled: overrideEnabledBinding(\.repeatLastN, defaultValue: LocalModelRecord.defaultRepeatLastN)
            )
            parameterEditorLink(
                descriptorID: "repeatPenalty",
                text: $repeatPenaltyText,
                isEnabled: overrideEnabledBinding(\.repeatPenalty, defaultValue: LocalModelRecord.defaultRepeatPenalty)
            )
            parameterEditorLink(
                descriptorID: "frequencyPenalty",
                text: $frequencyPenaltyText,
                isEnabled: overrideEnabledBinding(\.frequencyPenalty, defaultValue: LocalModelRecord.defaultFrequencyPenalty)
            )
            parameterEditorLink(
                descriptorID: "presencePenalty",
                text: $presencePenaltyText,
                isEnabled: overrideEnabledBinding(\.presencePenalty, defaultValue: LocalModelRecord.defaultPresencePenalty)
            )
        } header: {
            Text(NSLocalizedString("采样", comment: "Local model sampling section"))
        }
    }

    private var grammarSection: some View {
        Section {
            let grammarDescriptor = LocalLLMParameterCatalog.descriptor(for: "grammar")
            NavigationLink {
                LocalModelTextOverrideEditor(
                    descriptor: grammarDescriptor,
                    text: grammarTextBinding,
                    isEnabled: overrideEnabledBinding(\.grammar, defaultValue: LocalModelRecord.defaultGrammar)
                )
            } label: {
                LocalModelParameterSummaryRow(
                    descriptor: grammarDescriptor,
                    isEnabled: draft.grammar != nil,
                    valueText: draft.grammar ?? NSLocalizedString("已设置", comment: "Configured local parameter")
                )
            }

            let ignoreEOSDescriptor = LocalLLMParameterCatalog.descriptor(for: "ignoreEOS")
            NavigationLink {
                LocalModelBoolOverrideEditor(
                    descriptor: ignoreEOSDescriptor,
                    value: ignoreEOSBinding,
                    isEnabled: overrideEnabledBinding(\.ignoreEOS, defaultValue: true)
                )
            } label: {
                LocalModelBoolSummaryRow(
                    descriptor: ignoreEOSDescriptor,
                    isEnabled: draft.ignoreEOS != nil,
                    value: draft.effectiveIgnoreEOS
                )
            }
        } header: {
            Text(NSLocalizedString("输出约束", comment: "Local model grammar section"))
        }
    }

    private func parameterEditorLink(
        descriptorID: String,
        text: Binding<String>,
        isEnabled: Binding<Bool>
    ) -> some View {
        let descriptor = LocalLLMParameterCatalog.descriptor(for: descriptorID)
        return NavigationLink {
            LocalModelParameterOverrideEditor(
                descriptor: descriptor,
                text: text,
                isEnabled: isEnabled
            )
        } label: {
            LocalModelParameterSummaryRow(
                descriptor: descriptor,
                isEnabled: isEnabled.wrappedValue,
                valueText: text.wrappedValue
            )
        }
    }

    private var samplerChainSection: some View {
        Section {
            LabeledContent(NSLocalizedString("采样链", comment: "Sampler chain status")) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(isDefaultSamplerChain ? NSLocalizedString("默认", comment: "Default sampler chain") : NSLocalizedString("自定义", comment: "Custom sampler chain"))
                    Text(LocalLLMSamplerKind.chainString(draft.effectiveSamplerKinds))
                        .etFont(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                LocalModelSamplerChainLabView(samplerKinds: $draft.samplerKinds)
            } label: {
                Label(NSLocalizedString("采样器链实验室", comment: "Open sampler chain lab"), systemImage: "slider.horizontal.3")
            }
        } header: {
            Text(NSLocalizedString("采样器链", comment: "Local sampler chain section"))
        } footer: {
            Text(LocalLLMParameterCatalog.descriptor(for: "samplerKinds").summary)
                .etFont(.caption2)
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
                    Label(NSLocalizedString("导入旧版覆盖参数", comment: "Import legacy local llama args"), systemImage: "arrow.triangle.2.circlepath")
                }
            }

            if let cliImportResult {
                LocalModelCLIImportSummary(result: cliImportResult)
            }
        } header: {
            Text(NSLocalizedString("实验区", comment: "Local model experiments section"))
        } footer: {
            Text(NSLocalizedString("支持常用 llama.cpp 风格参数，会转换为手表端同一套本地配置。", comment: "Watch local llama style import footer"))
                .etFont(.caption2)
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
        draft.gpuLayers = Self.watchOSGPULayers
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
        draft.gpuLayers = Self.watchOSGPULayers
        contextSizeText = "\(draft.effectiveContextSize)"
        maxOutputTokensText = "\(draft.effectiveMaxOutputTokens)"
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

private struct LocalModelAdvancedIntroView: View {
    var body: some View {
        List {
            Section {
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("先确认能聊天", comment: "Local model guide quick start title"),
                    detail: NSLocalizedString("导入权重并加入候选模型后，先用默认参数发一条短消息。", comment: "Local model guide quick start detail")
                )
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("只覆盖必要项目", comment: "Watch local model guide overrides title"),
                    detail: NSLocalizedString("没有打开“自定义”的项目会继续使用 App 默认值或聊天页全局采样设置。", comment: "Watch local model guide overrides detail")
                )
            } header: {
                Text(NSLocalizedString("推荐配置顺序", comment: "Local model guide section order"))
            }

            Section {
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("上下文长度", comment: "Local parameter context size title"),
                    detail: NSLocalizedString("上下文越大越占内存；手表端建议从较小值开始，确认稳定后再提高。", comment: "Watch local model guide context detail")
                )
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("最大输出 token", comment: "Local parameter max output title"),
                    detail: NSLocalizedString("这是单次回复的上限。手表端短问答可以压低，避免长时间高负载生成。", comment: "Watch local model guide output detail")
                )
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("采样", comment: "Local model sampling section"),
                    detail: NSLocalizedString("不确定时先只调 Temperature；复读明显时再看重复检查窗口和重复惩罚。", comment: "Watch local model guide sampling detail")
                )
            } header: {
                Text(NSLocalizedString("参数怎么调", comment: "Watch local model guide parameters section"))
            }

            Section {
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("CPU 路径", comment: "Watch local model guide CPU title"),
                    detail: NSLocalizedString("watchOS 本地推理只能使用 CPU 路径，GPU 层数固定为 0。", comment: "Watch fixed GPU layers footer")
                )
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("模型大小", comment: "Watch local model guide model size title"),
                    detail: NSLocalizedString("手表端建议先用更小的 GGUF 和较短上下文，确认不会被系统回收后再提高参数。", comment: "Watch local model guide model size detail")
                )
            } header: {
                Text(NSLocalizedString("手表端限制", comment: "Watch local model guide limits section"))
            }

            Section {
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("参数导入", comment: "Local llama style import navigation title"),
                    detail: NSLocalizedString("llama.cpp-style 参数导入只解析常用子集，导入后会变成表单覆盖项；App 不执行完整 CLI。", comment: "Local model guide advanced import")
                )
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("文件与速度", comment: "Watch local model guide troubleshooting title"),
                    detail: NSLocalizedString("文件缺失时重新下载或停用模型；生成很慢时先降低上下文长度和最大输出 token。", comment: "Watch local model guide troubleshooting detail")
                )
            } header: {
                Text(NSLocalizedString("导入与排错", comment: "Watch local model guide import troubleshooting section"))
            }
        }
        .navigationTitle(NSLocalizedString("本地模型设置指南", comment: "Local model guide navigation title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalModelWatchGuideRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .etFont(.caption.weight(.semibold))
            Text(detail)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

private struct LocalModelParameterOverrideEditor: View {
    let descriptor: LocalLLMParameterDescriptor
    @Binding var text: String
    @Binding var isEnabled: Bool

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("自定义", comment: "Enable local parameter override"), isOn: $isEnabled)

                if isEnabled {
                    TextField(descriptor.title, text: $text.watchKeyboardNewlineBinding())
                        .textInputAutocapitalization(.never)
                }
            } footer: {
                Text(descriptor.summary)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(NSLocalizedString("默认", comment: "Local parameter default")) {
                    Text(descriptor.defaultValue)
                }
                LabeledContent(NSLocalizedString("作用", comment: "Local parameter scope")) {
                    Text(descriptor.effectScope)
                }
                if !descriptor.aliasText.isEmpty {
                    LabeledContent(NSLocalizedString("别名", comment: "Local parameter alias")) {
                        Text(descriptor.aliasText)
                            .etFont(.caption2.monospaced())
                    }
                }
            }
        }
        .navigationTitle(descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalModelTextOverrideEditor: View {
    let descriptor: LocalLLMParameterDescriptor
    @Binding var text: String
    @Binding var isEnabled: Bool

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("自定义", comment: "Enable local parameter override"), isOn: $isEnabled)

                if isEnabled {
                    TextField(descriptor.title, text: $text.watchKeyboardNewlineBinding(), axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                }
            } footer: {
                Text(descriptor.summary)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(NSLocalizedString("默认", comment: "Local parameter default")) {
                    Text(descriptor.defaultValue)
                }
                LabeledContent(NSLocalizedString("作用", comment: "Local parameter scope")) {
                    Text(descriptor.effectScope)
                }
                LabeledContent(NSLocalizedString("别名", comment: "Local parameter alias")) {
                    Text(descriptor.aliasText)
                        .etFont(.caption2.monospaced())
                }
            }
        }
        .navigationTitle(descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalModelBoolOverrideEditor: View {
    let descriptor: LocalLLMParameterDescriptor
    @Binding var value: Bool
    @Binding var isEnabled: Bool

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("自定义", comment: "Enable local parameter override"), isOn: $isEnabled)

                if isEnabled {
                    Toggle(NSLocalizedString("开启", comment: "Enable bool local parameter"), isOn: $value)
                }
            } footer: {
                Text(descriptor.summary)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(NSLocalizedString("默认", comment: "Local parameter default")) {
                    Text(descriptor.defaultValue)
                }
                LabeledContent(NSLocalizedString("作用", comment: "Local parameter scope")) {
                    Text(descriptor.effectScope)
                }
                LabeledContent(NSLocalizedString("别名", comment: "Local parameter alias")) {
                    Text(descriptor.aliasText)
                        .etFont(.caption2.monospaced())
                }
            }
        }
        .navigationTitle(descriptor.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LocalModelParameterSummaryRow: View {
    let descriptor: LocalLLMParameterDescriptor
    let isEnabled: Bool
    let valueText: String

    var body: some View {
        LabeledContent(descriptor.title) {
            Text(isEnabled ? valueText : NSLocalizedString("默认", comment: "Default local parameter state"))
                .foregroundStyle(isEnabled ? .primary : .secondary)
        }
    }
}

private struct LocalModelBoolSummaryRow: View {
    let descriptor: LocalLLMParameterDescriptor
    let isEnabled: Bool
    let value: Bool

    var body: some View {
        LabeledContent(descriptor.title) {
            Text(isEnabled
                ? (value ? NSLocalizedString("开启", comment: "Enabled") : NSLocalizedString("已关闭", comment: "Disabled local parameter state"))
                : NSLocalizedString("默认", comment: "Default local parameter state"))
                .foregroundStyle(isEnabled ? .primary : .secondary)
        }
    }
}

private struct LocalModelCLIStyleImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var inputText = "--temp 0.7 --top-p 0.9 --ctx-size 4096"
    @State private var result: LocalLLMCLIStyleImportResult?

    let record: LocalModelRecord
    let onApply: (LocalLLMCLIStyleImportResult) -> Void

    var body: some View {
        List {
            Section {
                TextField(NSLocalizedString("llama.cpp 参数", comment: "Local llama style import field"), text: $inputText.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(4...8)
                    .textInputAutocapitalization(.never)
            } footer: {
                Text(NSLocalizedString("支持常用 llama.cpp 风格参数，不等于完整 CLI。", comment: "Local llama style import explanation"))
                    .etFont(.caption2)
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text("\(item.value) · \(item.option)")
                            .etFont(.caption2.monospaced())
                            .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(NSLocalizedString("最近一次导入结果", comment: "Last local llama import summary title"))
                .etFont(.caption.weight(.medium))
            Text(String(format: NSLocalizedString("已应用 %d 个，不支持 %d 个，出错 %d 个。", comment: "Last local llama import summary"), result.appliedParameters.count, result.unsupportedParameters.count, result.errorParameters.count))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LocalModelImportIssueRow: View {
    let issue: LocalLLMCLIStyleImportIssue
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(issue.option)
                .etFont(.caption.monospaced())
                .foregroundStyle(color)
            Text(issue.message)
                .etFont(.caption2)
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
                        .etFont(.caption.monospaced())
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                            Text(preset.chainString)
                                .etFont(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(preset.summary)
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("预设链", comment: "Sampler chain presets"))
            }

            Section {
                ForEach(currentKindsBinding, id: \.self, editActions: .move) { $kind in
                    NavigationLink {
                        LocalModelSamplerKindActionView(
                            kind: kind,
                            canMoveUp: canMoveKind(kind, by: -1),
                            canMoveDown: canMoveKind(kind, by: 1),
                            onMoveUp: { moveKind(kind, by: -1) },
                            onMoveDown: { moveKind(kind, by: 1) },
                            onRemove: { removeKind(kind) }
                        )
                    } label: {
                        LocalModelSamplerKindRow(kind: kind)
                    }
                }
            } header: {
                Text(NSLocalizedString("当前采样链", comment: "Current sampler chain"))
            } footer: {
                Text(NSLocalizedString("拖拽右侧把手可调整采样器顺序。", comment: "Sampler chain reorder footer"))
            }

            Section {
                ForEach(LocalLLMSamplerKind.allCases.filter { !currentKinds.contains($0) }) { kind in
                    Button {
                        samplerKinds = currentKinds + [kind]
                    } label: {
                        LocalModelSamplerKindRow(kind: kind)
                    }
                }
            } header: {
                Text(NSLocalizedString("可用采样器", comment: "Available samplers"))
            }
        }
        .navigationTitle(NSLocalizedString("采样器链实验室", comment: "Sampler chain lab title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentKindsBinding: Binding<[LocalLLMSamplerKind]> {
        Binding {
            currentKinds
        } set: { updatedKinds in
            let uniqueKinds = LocalLLMSamplerKind.unique(updatedKinds)
            samplerKinds = uniqueKinds == LocalLLMSamplerKind.defaultChain ? nil : uniqueKinds
        }
    }

    private func canMoveKind(_ kind: LocalLLMSamplerKind, by offset: Int) -> Bool {
        guard let index = currentKinds.firstIndex(of: kind) else { return false }
        return currentKinds.indices.contains(index + offset)
    }

    private func moveKind(_ kind: LocalLLMSamplerKind, by offset: Int) {
        guard let index = currentKinds.firstIndex(of: kind) else { return }
        let destination = index + offset
        guard currentKinds.indices.contains(index), currentKinds.indices.contains(destination) else { return }
        var updatedKinds = currentKinds
        updatedKinds.swapAt(index, destination)
        currentKindsBinding.wrappedValue = updatedKinds
    }

    private func removeKind(_ kind: LocalLLMSamplerKind) {
        guard let index = currentKinds.firstIndex(of: kind) else { return }
        guard currentKinds.indices.contains(index) else { return }
        var updatedKinds = currentKinds
        updatedKinds.remove(at: index)
        currentKindsBinding.wrappedValue = updatedKinds
    }
}

private struct LocalModelSamplerKindRow: View {
    let kind: LocalLLMSamplerKind

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(kind.localizedTitle) · \(kind.title)")
                .etFont(.caption.weight(.medium))
            Text("\(kind.code) · \(kind.summary)")
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct LocalModelSamplerKindActionView: View {
    @Environment(\.dismiss) private var dismiss

    let kind: LocalLLMSamplerKind
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        List {
            Section {
                LocalModelSamplerKindRow(kind: kind)
            }

            Section {
                Button(NSLocalizedString("上移", comment: "Move sampler up")) {
                    onMoveUp()
                    dismiss()
                }
                .disabled(!canMoveUp)

                Button(NSLocalizedString("下移", comment: "Move sampler down")) {
                    onMoveDown()
                    dismiss()
                }
                .disabled(!canMoveDown)

                Button(role: .destructive) {
                    onRemove()
                    dismiss()
                } label: {
                    Text(NSLocalizedString("移除", comment: "Remove sampler"))
                }
            }
        }
        .navigationTitle(kind.localizedTitle)
        .navigationBarTitleDisplayMode(.inline)
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

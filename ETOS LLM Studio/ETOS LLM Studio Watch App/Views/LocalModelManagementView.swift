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
                SettingsHelpCard(
                    title: NSLocalizedString("本地模型", comment: ""),
                    summary: NSLocalizedString("在设备上运行模型，并按内存余量选择缓存。", comment: "本地模型缓存简介"),
                    details: "\(NSLocalizedString("对话 KV 缓存", comment: "对话缓存说明标题"))\n\(NSLocalizedString("打开后，本地文本模型会保留当前对话的 KV 缓存，让下一轮只处理新增内容；切换对话或关闭开关时释放。此功能会额外占用内存，且不复用于多模态对话。", comment: "对话缓存说明"))"
                )
            }
            Section {
                Toggle(NSLocalizedString("启用本地模型提供商", comment: "Enable local model provider"), isOn: localModelsEnabledBinding)
            } footer: {
                Text(NSLocalizedString("关闭后不会删除权重；重新开启时会自动恢复到模型管理。", comment: "Watch local provider toggle footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(NSLocalizedString("对话 KV 缓存", comment: "Conversation KV cache toggle"), isOn: localModelKVCacheEnabledBinding)
            } footer: {
                Text(NSLocalizedString("加快连续文字对话，但会额外占用内存。", comment: "对话缓存简短提示"))
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
        .guideSettingsPageContext(
            id: "watch-settings-local-models",
            title: NSLocalizedString("本地模型", comment: "本地模型向导上下文标题"),
            documents: [GuideDocumentReference(id: "local-models", title: "Local Models")],
            settings: [
                .bool("provider_enabled", label: NSLocalizedString("启用本地模型提供商", comment: "向导设置字段"), get: { appConfig.localModelsEnabled }, set: { localModelsEnabledBinding.wrappedValue = $0 }),
                .bool("conversation_kv_cache_enabled", label: NSLocalizedString("对话 KV 缓存", comment: "向导设置字段"), get: { appConfig.localModelKVCacheEnabled }, set: { localModelKVCacheEnabledBinding.wrappedValue = $0 }),
                .string("download_url", label: NSLocalizedString("模型文件链接", comment: "向导设置字段"), get: { downloadURLText }, set: { downloadURLText = $0 }),
                .string("download_display_name", label: NSLocalizedString("名称", comment: "向导设置字段"), get: { displayName }, set: { displayName = $0 }),
                .readOnly("download_requires_user_action", label: NSLocalizedString("下载应用方式", comment: "向导设置字段"), value: { .string(NSLocalizedString("填写后需要点击下载权重", comment: "向导草稿应用方式")) }),
                .readOnly("models", label: NSLocalizedString("权重", comment: "向导设置字段"), value: {
                    .array(store.models.map { record in
                        .dictionary([
                            "id": .string(record.id.uuidString),
                            "name": .string(record.sanitizedDisplayName),
                            "file_name": .string(record.fileName),
                            "file_size": .int(Int(clamping: record.fileSize)),
                            "file_available": .bool(store.fileExists(for: record)),
                            "activated": .bool(record.isActivated),
                            "architecture": .string(record.ggufArchitecture ?? "")
                        ])
                    })
                })
            ]
        )
        .watchGuideEntry()
    }

    private var localModelsEnabledBinding: Binding<Bool> {
        Binding {
            appConfig.localModelsEnabled
        } set: { isEnabled in
            appConfig.localModelsEnabled = isEnabled
            ChatService.shared.setLocalModelsEnabled(isEnabled)
        }
    }

    private var localModelKVCacheEnabledBinding: Binding<Bool> {
        Binding {
            appConfig.localModelKVCacheEnabled
        } set: { isEnabled in
            appConfig.localModelKVCacheEnabled = isEnabled
            if !isEnabled {
                Task.detached(priority: .utility) {
                    LocalLLMEngine.shared.clearKVCache()
                }
            }
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
                    Text(String(format: "%d%%", progress.displayPercentage))
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
                        StorageUtility.formatTransferSize(progress.bytesReceived),
                        StorageUtility.formatTransferSize(progress.totalBytes)
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
            if record.hasMultimodalProjector {
                Label(NSLocalizedString("已配置 mmproj", comment: "Local model has mmproj"), systemImage: "photo")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            if record.hasLoRAAdapter {
                Label(NSLocalizedString("已挂载 LoRA", comment: "Local model has LoRA"), systemImage: "link")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let architecture = record.speechArchitecture {
                Label(architecture.localizedTitle, systemImage: "waveform")
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
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
    @State private var showUnsavedChangesAlert = false
    @State private var showCLIImport = false
    @State private var cliImportResult: LocalLLMCLIStyleImportResult?
    @State private var loraDownloadURLText = ""
    @State private var isDownloadingLoRA = false
    @State private var loraDownloadProgress: SyncPackageDownloadProgress?
    @State private var loraStatusMessage: String?
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
    @State private var imageMinTokensText: String
    @State private var imageMaxTokensText: String
    @State private var loraScaleText: String

    private static let watchOSGPULayers = 0
    private let savedSnapshot: LocalModelRecord

    init(record: LocalModelRecord) {
        var initialDraft = record
        initialDraft.gpuLayers = Self.watchOSGPULayers
        savedSnapshot = initialDraft
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
        _imageMinTokensText = State(initialValue: "\(initialDraft.effectiveImageMinTokens)")
        _imageMaxTokensText = State(initialValue: "\(initialDraft.effectiveImageMaxTokens)")
        _loraScaleText = State(initialValue: LocalModelFormat.decimal(initialDraft.effectiveLoRAScale))
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
                if draft.isSpeechAuxiliaryModel {
                    Label(NSLocalizedString("语音分段辅助模型", comment: "Speech VAD auxiliary model role"), systemImage: "waveform")
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(NSLocalizedString("加入候选模型", comment: "Activate local model"), isOn: $draft.isActivated)
                }
            }

            speechSection
            runtimeSection
            loraSection
            multimodalSection
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
                    saveAndDismiss()
                } label: {
                    Label(NSLocalizedString("保存", comment: "Save"), systemImage: "checkmark")
                }
                .disabled(!hasUnsavedChanges)

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label(NSLocalizedString("删除权重", comment: "Delete local model"), systemImage: "trash")
                }
            }
        }
        .navigationTitle(draft.sanitizedDisplayName)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .guideSettingsPageContext(
            id: "watch-settings-local-model-detail",
            title: String(format: NSLocalizedString("本地模型：%@", comment: "本地模型详情向导标题"), draft.sanitizedDisplayName),
            documents: [GuideDocumentReference(id: "local-models", title: "Local Models")],
            settings: guideSettings
        )
        .watchGuideEntry()
        .navigationDestination(isPresented: $showCLIImport) {
            LocalModelCLIStyleImportView(record: draft) { result in
                draft = result.updatedRecord
                cliImportResult = result
                refreshTextFieldsFromDraft()
            }
        }
        .toolbar {
            if hasUnsavedChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        requestDismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel(NSLocalizedString("返回", comment: "Back button"))
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "Save")) {
                    saveAndDismiss()
                }
                .disabled(!hasUnsavedChanges)
            }
        }
        .alert(NSLocalizedString("删除本地模型", comment: "Delete local model alert"), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                store.delete(draft)
                dismiss()
            }
        } message: {
            Text(NSLocalizedString("会同时删除手表上保存的权重文件、mmproj 投影器和 LoRA Adapter。", comment: "Watch delete local model alert message"))
        }
        .alert(NSLocalizedString("未保存更改", comment: "Unsaved changes alert title"), isPresented: $showUnsavedChangesAlert) {
            Button(NSLocalizedString("保存并离开", comment: "Save changes and leave")) {
                saveAndDismiss()
            }
            Button(NSLocalizedString("放弃更改", comment: "Discard changes"), role: .destructive) {
                discardAndDismiss()
            }
            Button(NSLocalizedString("继续编辑", comment: "Continue editing"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("要保存当前本地模型设置，还是放弃更改并离开？", comment: "Unsaved local model settings alert message"))
        }
    }

    private var guideSettings: [GuidePageSetting] {
        var result: [GuidePageSetting] = [
            .string("display_name", label: NSLocalizedString("名称", comment: "向导设置字段"), allowsEmpty: false, get: { draft.displayName }, set: { draft.displayName = $0 }),
            .bool("activated", label: NSLocalizedString("加入候选模型", comment: "向导设置字段"), get: { draft.isActivated }, set: { draft.isActivated = $0 }),
            .integer("context_size", label: NSLocalizedString("上下文长度", comment: "向导设置字段"), range: 1...1_048_576, get: { draft.effectiveContextSize }, set: { draft.contextSize = $0; contextSizeText = "\($0)" }),
            .integer("max_output_tokens", label: NSLocalizedString("最大输出长度", comment: "向导设置字段"), range: 1...131_072, get: { draft.effectiveMaxOutputTokens }, set: { draft.maxOutputTokens = $0; maxOutputTokensText = "\($0)" }),
            .integer("seed", label: NSLocalizedString("随机种子", comment: "向导设置字段"), range: 0...Int(UInt32.max), get: { Int(draft.effectiveSeed) }, set: { draft.seed = UInt32($0); seedText = "\($0)" }),
            .double("temperature", label: NSLocalizedString("温度", comment: "向导设置字段"), range: 0...5, get: { draft.effectiveTemperature }, set: { draft.temperature = $0; temperatureText = LocalModelFormat.decimal($0) }),
            .integer("top_k", label: NSLocalizedString("Top K", comment: "向导设置字段"), range: 0...1_000, get: { draft.effectiveTopK }, set: { draft.topK = $0; topKText = "\($0)" }),
            .double("top_p", label: NSLocalizedString("Top P", comment: "向导设置字段"), range: 0...1, get: { draft.effectiveTopP }, set: { draft.topP = $0; topPText = LocalModelFormat.decimal($0) }),
            .double("min_p", label: NSLocalizedString("Min P", comment: "向导设置字段"), range: 0...1, get: { draft.effectiveMinP }, set: { draft.minP = $0; minPText = LocalModelFormat.decimal($0) }),
            .integer("repeat_last_n", label: NSLocalizedString("重复惩罚窗口", comment: "向导设置字段"), range: -1...1_048_576, get: { draft.effectiveRepeatLastN }, set: { draft.repeatLastN = $0; repeatLastNText = "\($0)" }),
            .double("repeat_penalty", label: NSLocalizedString("重复惩罚", comment: "向导设置字段"), range: 0...4, get: { draft.effectiveRepeatPenalty }, set: { draft.repeatPenalty = $0; repeatPenaltyText = LocalModelFormat.decimal($0) }),
            .double("frequency_penalty", label: NSLocalizedString("频率惩罚", comment: "向导设置字段"), range: -2...2, get: { draft.effectiveFrequencyPenalty }, set: { draft.frequencyPenalty = $0; frequencyPenaltyText = LocalModelFormat.decimal($0) }),
            .double("presence_penalty", label: NSLocalizedString("存在惩罚", comment: "向导设置字段"), range: -2...2, get: { draft.effectivePresencePenalty }, set: { draft.presencePenalty = $0; presencePenaltyText = LocalModelFormat.decimal($0) }),
            .string("grammar", label: NSLocalizedString("Grammar", comment: "向导设置字段"), get: { draft.grammar ?? "" }, set: { draft.grammar = $0 }),
            .bool("ignore_eos", label: NSLocalizedString("忽略 EOS", comment: "向导设置字段"), get: { draft.effectiveIgnoreEOS }, set: { draft.ignoreEOS = $0 }),
            .integer("image_min_tokens", label: NSLocalizedString("最少图片 Token", comment: "向导设置字段"), range: -1...1_048_576, get: { draft.effectiveImageMinTokens }, set: { draft.imageMinTokens = $0; imageMinTokensText = "\($0)" }),
            .integer("image_max_tokens", label: NSLocalizedString("最多图片 Token", comment: "向导设置字段"), range: -1...1_048_576, get: { draft.effectiveImageMaxTokens }, set: { draft.imageMaxTokens = $0; imageMaxTokensText = "\($0)" }),
            .string("sampler_chain", label: NSLocalizedString("采样链", comment: "向导设置字段"), allowsEmpty: false, get: { LocalLLMSamplerKind.chainString(draft.effectiveSamplerKinds) }, set: { draft.samplerKinds = LocalLLMSamplerKind.parse($0) }),
            .readOnly("file_name", label: NSLocalizedString("文件", comment: "向导设置字段"), value: { .string(draft.fileName) }),
            .readOnly("file_size", label: NSLocalizedString("大小", comment: "向导设置字段"), value: { .int(Int(clamping: draft.fileSize)) }),
            .readOnly("file_available", label: NSLocalizedString("状态", comment: "向导设置字段"), value: { .bool(store.fileExists(for: draft)) }),
            .readOnly("architecture", label: NSLocalizedString("GGUF 架构", comment: "向导设置字段"), value: { .string(draft.ggufArchitecture ?? "") }),
            .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: "向导设置字段"), value: { .string(NSLocalizedString("修改后需要保存", comment: "向导草稿应用方式")) })
        ]
        if draft.hasLoRAAdapter {
            result.append(.double("lora_scale", label: NSLocalizedString("LoRA 强度", comment: "向导设置字段"), range: -100...100, get: { draft.effectiveLoRAScale }, set: { draft.loraScale = $0; loraScaleText = LocalModelFormat.decimal($0) }))
        }
        if draft.speechArchitecture?.requiresDecoderModel == true {
            result.append(.string("speech_decoder_model_id", label: NSLocalizedString("解码模型", comment: "向导设置字段"), allowedValues: [""] + speechDecoderCandidates.map { $0.id.uuidString }, get: { draft.speechDecoderModelID?.uuidString ?? "" }, set: { draft.speechDecoderModelID = UUID(uuidString: $0) }))
        }
        if draft.speechArchitecture?.isTranscriptionModel == true {
            result.append(.string("speech_vad_model_id", label: NSLocalizedString("VAD 模型", comment: "向导设置字段"), allowedValues: [""] + speechVADCandidates.map { $0.id.uuidString }, get: { draft.speechVADModelID?.uuidString ?? "" }, set: { draft.speechVADModelID = UUID(uuidString: $0) }))
        }
        return result
    }

    @ViewBuilder
    private var speechSection: some View {
        if let architecture = draft.speechArchitecture {
            Section {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("GGUF 架构", comment: "Local GGUF architecture label"))
                    Text(architecture.localizedTitle)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                if architecture.requiresDecoderModel {
                    Picker(
                        NSLocalizedString("解码模型", comment: "Local speech decoder model picker"),
                        selection: $draft.speechDecoderModelID
                    ) {
                        Text(NSLocalizedString("未选择", comment: "No associated local model"))
                            .tag(UUID?.none)
                        ForEach(speechDecoderCandidates) { record in
                            Text(record.sanitizedDisplayName)
                                .tag(Optional(record.id))
                        }
                    }
                }

                if architecture.isTranscriptionModel {
                    Picker(
                        NSLocalizedString("VAD 模型", comment: "Local speech VAD model picker"),
                        selection: $draft.speechVADModelID
                    ) {
                        Text(NSLocalizedString("不使用", comment: "Do not use an optional local model"))
                            .tag(UUID?.none)
                        ForEach(speechVADCandidates) { record in
                            Text(record.sanitizedDisplayName)
                                .tag(Optional(record.id))
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("本地语音转写", comment: "Local speech transcription section"))
            } footer: {
                Text(speechSectionFooter(for: architecture))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var speechDecoderCandidates: [LocalModelRecord] {
        store.models.filter {
            $0.id != draft.id
                && $0.ggufArchitecture == "qwen3"
                && store.fileExists(for: $0)
        }
    }

    private var speechVADCandidates: [LocalModelRecord] {
        store.models.filter {
            $0.id != draft.id
                && $0.speechArchitecture == .fsmnVAD
                && store.fileExists(for: $0)
        }
    }

    private func speechSectionFooter(for architecture: LocalSpeechModelArchitecture) -> String {
        if architecture == .funASRNanoEncoder {
            return NSLocalizedString("Fun-ASR-Nano 必须关联本地 Qwen3 解码模型；FSMN-VAD 可选。", comment: "Fun-ASR-Nano local model association footer")
        }
        if architecture == .fsmnVAD {
            return NSLocalizedString("FSMN-VAD 只负责切分语音，请在转写模型中关联使用。", comment: "FSMN-VAD auxiliary model footer")
        }
        return NSLocalizedString("SenseVoiceSmall 与 Paraformer 可直接转写，也可以关联 FSMN-VAD 处理长音频。", comment: "Local speech model footer")
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

    @ViewBuilder
    private var loraSection: some View {
        if !draft.isSpeechTranscriptionModel && !draft.isSpeechAuxiliaryModel {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("LoRA Adapter", comment: "Local model LoRA adapter label"))
                    Text(draft.loraFileName ?? NSLocalizedString("未挂载", comment: "No local LoRA adapter"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let size = draft.loraFileSize {
                        Text(StorageUtility.formatSize(size))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if draft.hasLoRAAdapter {
                    TextField(
                        NSLocalizedString("LoRA 强度", comment: "Local LoRA scale field"),
                        text: $loraScaleText.watchKeyboardNewlineBinding()
                    )
                    .textInputAutocapitalization(.never)
                }

                TextField(
                    NSLocalizedString("LoRA 文件链接", comment: "Watch LoRA download URL"),
                    text: $loraDownloadURLText.watchKeyboardNewlineBinding()
                )
                .textInputAutocapitalization(.never)

                Button {
                    downloadLoRA()
                } label: {
                    if isDownloadingLoRA {
                        ProgressView()
                    } else {
                        Label(draft.hasLoRAAdapter
                            ? NSLocalizedString("下载并替换 LoRA", comment: "Watch replace LoRA")
                            : NSLocalizedString("下载并挂载 LoRA", comment: "Watch attach LoRA"),
                              systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isDownloadingLoRA || normalizedLoRAURL == nil)

                if let loraDownloadProgress {
                    LocalModelDownloadProgressView(progress: loraDownloadProgress)
                }
                if let loraStatusMessage {
                    Text(loraStatusMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                if draft.hasLoRAAdapter {
                    Button(role: .destructive) {
                        if let relativePath = draft.loraRelativePath,
                           relativePath != savedSnapshot.loraRelativePath {
                            store.deleteLoRAFile(relativePath: relativePath)
                        }
                        draft.loraFileName = nil
                        draft.loraRelativePath = nil
                        draft.loraFileSize = nil
                        draft.loraScale = nil
                        loraScaleText = LocalModelFormat.decimal(LocalModelRecord.defaultLoRAScale)
                    } label: {
                        Label(NSLocalizedString("移除 LoRA", comment: "Remove local LoRA adapter"), systemImage: "xmark.circle")
                    }
                }
            } header: {
                Text(NSLocalizedString("LoRA", comment: "Local LoRA section title"))
            } footer: {
                Text(NSLocalizedString("请下载与基础模型架构匹配的 LoRA GGUF。强度 1 使用原始效果，0 保留挂载但不改变输出。", comment: "Watch local LoRA footer"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var multimodalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("mmproj 投影器", comment: "Local model mmproj label"))
                Text(draft.mmprojFileName ?? NSLocalizedString("未导入", comment: "No local mmproj"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let size = draft.mmprojFileSize {
                    Text(StorageUtility.formatSize(size))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if draft.hasMultimodalProjector {
                Text(store.mmprojFileExists(for: draft)
                    ? NSLocalizedString("投影器文件可用", comment: "Watch local mmproj exists")
                    : NSLocalizedString("投影器文件缺失", comment: "Watch local mmproj missing"))
                    .etFont(.caption2)
                    .foregroundStyle(store.mmprojFileExists(for: draft) ? Color.secondary : Color.orange)
            }

            parameterEditorLink(
                descriptorID: "imageMinTokens",
                text: $imageMinTokensText,
                isEnabled: overrideEnabledBinding(\.imageMinTokens, defaultValue: LocalModelRecord.defaultImageMinTokens)
            )
            parameterEditorLink(
                descriptorID: "imageMaxTokens",
                text: $imageMaxTokensText,
                isEnabled: overrideEnabledBinding(\.imageMaxTokens, defaultValue: LocalModelRecord.defaultImageMaxTokens)
            )
        } header: {
            Text(NSLocalizedString("多模态", comment: "Local model multimodal section"))
        } footer: {
            Text(NSLocalizedString("手表端不提供文件选择器；Image Token 仅影响支持动态分辨率的视觉模型。", comment: "Watch local multimodal footer"))
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

    private var hasUnsavedChanges: Bool {
        draftApplyingTextFields(draft, clearsAdvancedArguments: false) != savedSnapshot
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            showUnsavedChangesAlert = true
        } else {
            dismiss()
        }
    }

    private func saveAndDismiss() {
        let updatedDraft = draftApplyingTextFields(draft, clearsAdvancedArguments: true)
        draft = updatedDraft
        store.update(updatedDraft)
        dismiss()
    }

    private func discardAndDismiss() {
        cleanupUnsavedLoRAIfNeeded()
        dismiss()
    }

    private func cleanupUnsavedLoRAIfNeeded() {
        guard let relativePath = draft.loraRelativePath,
              relativePath != savedSnapshot.loraRelativePath else {
            return
        }
        store.deleteLoRAFile(relativePath: relativePath)
    }

    private var normalizedLoRAURL: URL? {
        let text = loraDownloadURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private func downloadLoRA() {
        guard let url = normalizedLoRAURL else { return }
        isDownloadingLoRA = true
        loraDownloadProgress = nil
        loraStatusMessage = nil
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = NetworkSessionConfiguration.minimumRequestTimeout
                let (downloadedURL, response) = try await SyncPackageUploadService.downloadTemporaryFile(
                    request: request,
                    progress: { progress in
                        Task { @MainActor in
                            loraDownloadProgress = progress
                        }
                    }
                )
                defer {
                    Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: downloadedURL)
                    }
                }
                try validateLoRADownloadResponse(response)
                let previousUnsavedLoRA = draft.loraRelativePath == savedSnapshot.loraRelativePath
                    ? nil
                    : draft.loraRelativePath
                let responseFileName = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
                let suggestedFileName: String
                if let responseFileName, !responseFileName.isEmpty {
                    suggestedFileName = responseFileName
                } else {
                    suggestedFileName = url.lastPathComponent.isEmpty ? "adapter.gguf" : url.lastPathComponent
                }
                let updatedDraft = try await store.copyLoRAAdapter(
                    from: downloadedURL,
                    for: draft,
                    suggestedFileName: suggestedFileName
                )
                if let previousUnsavedLoRA {
                    store.deleteLoRAFile(relativePath: previousUnsavedLoRA)
                }
                draft = updatedDraft
                loraScaleText = LocalModelFormat.decimal(updatedDraft.effectiveLoRAScale)
                loraDownloadURLText = ""
                loraStatusMessage = NSLocalizedString("LoRA 已挂载。", comment: "Watch LoRA attached")
                isDownloadingLoRA = false
            } catch {
                loraStatusMessage = error.localizedDescription
                loraDownloadProgress = nil
                isDownloadingLoRA = false
            }
        }
    }

    private func validateLoRADownloadResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              !(200..<300).contains(httpResponse.statusCode) else {
            return
        }
        throw NSError(domain: "ETOSWatchLoRADownload", code: httpResponse.statusCode, userInfo: [
            NSLocalizedDescriptionKey: String(
                format: NSLocalizedString("下载 LoRA 失败（HTTP %d）。", comment: "Watch LoRA download HTTP failure"),
                httpResponse.statusCode
            )
        ])
    }

    private func draftApplyingTextFields(_ source: LocalModelRecord, clearsAdvancedArguments: Bool) -> LocalModelRecord {
        var updatedDraft = source
        if updatedDraft.contextSize != nil, let contextSize = Int(contextSizeText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.contextSize = contextSize
        }
        if updatedDraft.maxOutputTokens != nil, let maxOutputTokens = Int(maxOutputTokensText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.maxOutputTokens = maxOutputTokens
        }
        updatedDraft.gpuLayers = Self.watchOSGPULayers
        if updatedDraft.seed != nil, let seed = parseSeed(seedText) {
            updatedDraft.seed = seed
        }
        if updatedDraft.temperature != nil, let temperature = Double(temperatureText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.temperature = temperature
        }
        if updatedDraft.topK != nil, let topK = Int(topKText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.topK = topK
        }
        if updatedDraft.topP != nil, let topP = Double(topPText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.topP = topP
        }
        if updatedDraft.minP != nil, let minP = Double(minPText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.minP = minP
        }
        if updatedDraft.repeatLastN != nil, let repeatLastN = Int(repeatLastNText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.repeatLastN = repeatLastN
        }
        if updatedDraft.repeatPenalty != nil, let repeatPenalty = Double(repeatPenaltyText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.repeatPenalty = repeatPenalty
        }
        if updatedDraft.frequencyPenalty != nil, let frequencyPenalty = Double(frequencyPenaltyText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.frequencyPenalty = frequencyPenalty
        }
        if updatedDraft.presencePenalty != nil, let presencePenalty = Double(presencePenaltyText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.presencePenalty = presencePenalty
        }
        if updatedDraft.imageMinTokens != nil, let imageMinTokens = Int(imageMinTokensText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.imageMinTokens = imageMinTokens
        }
        if updatedDraft.imageMaxTokens != nil, let imageMaxTokens = Int(imageMaxTokensText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.imageMaxTokens = imageMaxTokens
        }
        if updatedDraft.hasLoRAAdapter,
           let loraScale = Double(loraScaleText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            updatedDraft.loraScale = loraScale
        }
        if clearsAdvancedArguments {
            updatedDraft.advancedArguments = ""
        }
        updatedDraft.normalizeGenerationParameters()
        return updatedDraft
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
        imageMinTokensText = "\(draft.effectiveImageMinTokens)"
        imageMaxTokensText = "\(draft.effectiveImageMaxTokens)"
        loraScaleText = LocalModelFormat.decimal(draft.effectiveLoRAScale)
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
                LocalModelWatchGuideRow(
                    title: NSLocalizedString("LoRA Adapter", comment: "Local model LoRA adapter label"),
                    detail: NSLocalizedString("请下载与基础模型架构匹配的 LoRA GGUF。强度 1 使用原始效果，0 保留挂载但不改变输出。", comment: "Watch local LoRA footer")
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
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "settings-local-model-cli-import-\(record.id.uuidString.lowercased())"),
            title: NSLocalizedString("参数导入", comment: "本地模型参数导入向导上下文标题"),
            documents: [GuideDocumentReference(id: "local-models", title: "Local Models")],
            settings: [
                .string(
                    "arguments",
                    label: NSLocalizedString("llama.cpp-style 参数", comment: "本地模型参数导入向导字段"),
                    get: { inputText },
                    set: { inputText = $0 }
                ),
                .readOnly(
                    "last_result",
                    label: NSLocalizedString("最近一次导入结果", comment: "本地模型参数导入向导字段"),
                    value: { guideResultValue }
                ),
                .readOnly(
                    "apply_method",
                    label: NSLocalizedString("应用方式", comment: "向导设置字段"),
                    value: { .string(NSLocalizedString("填写后需要点击解析并应用到表单", comment: "本地模型参数导入应用方式")) }
                )
            ]
        )
        .watchGuideEntry()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("完成", comment: "Done")) {
                    dismiss()
                }
            }
        }
    }

    private var guideResultValue: JSONValue {
        guard let result else { return .null }
        return .dictionary([
            "applied": .array(result.appliedParameters.map { item in
                .dictionary([
                    "option": .string(item.option),
                    "field": .string(item.title),
                    "value": .string(item.value)
                ])
            }),
            "unsupported": .array(result.unsupportedParameters.map { item in
                .dictionary(["option": .string(item.option), "message": .string(item.message)])
            }),
            "errors": .array(result.errorParameters.map { item in
                .dictionary(["option": .string(item.option), "message": .string(item.message)])
            })
        ])
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
        .guideSettingsPageContext(
            id: "settings-local-model-sampler-chain",
            title: NSLocalizedString("采样器链实验室", comment: "采样器链向导上下文标题"),
            documents: [GuideDocumentReference(id: "local-models", title: "Local Models")],
            settings: samplerGuideSettings
        )
        .watchGuideEntry()
    }

    private var samplerGuideSettings: [GuidePageSetting] {
        [
            .json(
                "sampler_chain",
                label: NSLocalizedString("采样器链", comment: "采样器链向导字段"),
                schema: .dictionary([
                    "type": .string("string"),
                    "description": .string("按执行顺序排列的 sampler 代码；可用代码为 edskypmxta，空字符串表示空链")
                ]),
                get: { .string(LocalLLMSamplerKind.chainString(currentKinds)) },
                normalize: { value in
                    guard case .string(let rawValue) = value else { throw GuideError.invalidToolArguments }
                    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let parsed = LocalLLMSamplerKind.parse(trimmed)
                    guard trimmed.isEmpty || (!parsed.isEmpty && LocalLLMSamplerKind.chainString(parsed) == trimmed) else {
                        throw GuideError.invalidToolArguments
                    }
                    return .string(trimmed)
                },
                set: { value in
                    guard case .string(let rawValue) = value else { throw GuideError.invalidToolArguments }
                    let parsed = LocalLLMSamplerKind.parse(rawValue)
                    samplerKinds = parsed == LocalLLMSamplerKind.defaultChain ? nil : parsed
                }
            ),
            .readOnly(
                "requires_save",
                label: NSLocalizedString("应用方式", comment: "向导设置字段"),
                value: { .string(NSLocalizedString("修改后需要保存本地模型", comment: "本地模型草稿应用方式")) }
            )
        ]
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

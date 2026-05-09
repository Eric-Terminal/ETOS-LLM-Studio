// ============================================================================
// ImageGenerationFeatureView.swift
// ============================================================================
// ImageGenerationFeatureView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import Shared

struct ImageGenerationFeatureView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @EnvironmentObject private var appConfig: AppConfigStore
    @State private var prompt: String = ""
    @State private var showGalleryFromStatus: Bool = false
    @State private var parameterExpressionEntries: [WatchImageParameterExpressionEntry] = [WatchImageParameterExpressionEntry(text: "")]

    private var availableImageModels: [RunnableModel] {
        viewModel.imageGenerationModelOptions
    }

    private var selectedImageModel: RunnableModel? {
        if let matched = viewModel.imageGenerationModel(with: appConfig.imageGenerationModelIdentifier) {
            return matched
        }
        return availableImageModels.first
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canGenerate: Bool {
        !trimmedPrompt.isEmpty
            && !viewModel.isSendingMessage
            && viewModel.supportsImageGeneration(for: selectedImageModel)
            && !parameterExpressionEntries.contains(where: { $0.error != nil })
    }

    private var generatedImageCount: Int {
        generatedImageItems(from: viewModel.allMessagesForSession).count
    }

    private func selectedImageModelLabel(in models: [RunnableModel]) -> String {
        if let selected = selectedImageModel,
           models.contains(where: { $0.id == selected.id }) {
            return "\(selected.model.displayName) | \(selected.provider.name)"
        }
        guard let first = models.first else {
            return NSLocalizedString("未选择", comment: "No image generation model selected")
        }
        return "\(first.model.displayName) | \(first.provider.name)"
    }

    private var galleryDestination: some View {
        WatchImageGenerationGalleryView(
            onReusePrompt: { reusedPrompt in
                prompt = reusedPrompt
            },
            onContinueGeneration: { reusedPrompt, attachment in
                prompt = reusedPrompt
                guard let runtimeParameters = runtimeOverrideParameters(showErrorMessage: true) else { return }
                submitImageGeneration(
                    prompt: reusedPrompt,
                    referenceImages: [attachment],
                    runtimeOverrideParameters: runtimeParameters
                )
            }
        )
        .environmentObject(viewModel)
    }

    var body: some View {
        List {
            Section {
                if availableImageModels.isEmpty {
                    Text(NSLocalizedString("请先在模型管理中启用至少一个生图模型。", comment: "No image generation model is available"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        WatchImageModelSelectionListView(
                            models: availableImageModels,
                            selectedModelIdentifier: $appConfig.imageGenerationModelIdentifier
                        )
                    } label: {
                        HStack {
                            Text(NSLocalizedString("生图模型", comment: "Image generation model picker title"))
                            Spacer(minLength: 8)
                            MarqueeText(
                                content: selectedImageModelLabel(in: availableImageModels),
                                uiFont: .preferredFont(forTextStyle: .footnote)
                            )
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } footer: {
                Text(NSLocalizedString("生图请求会使用这里单独选择的模型，不影响主聊天模型。也可以在“提供商与模型管理 > 专用模型”中统一设置。", comment: "Image generation uses independent model selection"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField(
                    NSLocalizedString("输入生图提示词", comment: "Image generation prompt placeholder on watch"),
                    text: $prompt.watchKeyboardNewlineBinding(),
                    axis: .vertical
                )
                .lineLimit(3...6)
            } footer: {
                Text(NSLocalizedString("输入提示词，独立发起生图请求。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($parameterExpressionEntries) { $entry in
                    WatchImageParameterExpressionRow(entry: $entry)
                        .onChange(of: entry.text) { _, _ in
                            validateParameterExpressionEntry(withId: entry.id)
                            saveParameterExpressions(for: appConfig.imageGenerationModelIdentifier)
                        }
                }
                .onDelete(perform: deleteParameterExpressionEntries)

                Button(NSLocalizedString("添加表达式", comment: "")) {
                    addParameterExpressionEntry()
                }
            } header: {
                Text(NSLocalizedString("生图参数（表达式）", comment: "Image generation parameter expression section title"))
            } footer: {
                Text(
                    NSLocalizedString(
                        "每行一个参数，示例：size = 2048x2048。参数会覆盖模型默认值，仅在生图请求中生效。",
                        comment: "Image generation runtime parameter expression section footer"
                    )
                )
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    triggerImageGeneration()
                } label: {
                    let buttonTitle = viewModel.isSendingMessage
                        ? NSLocalizedString("正在生成...", comment: "Image generation is running")
                        : NSLocalizedString("开始生成", comment: "Start image generation")
                    Label(buttonTitle, systemImage: "sparkles")
                }
                .disabled(!canGenerate)
            } footer: {
                if selectedImageModel == nil {
                    Text(NSLocalizedString("请先在模型管理中启用至少一个生图模型。", comment: "No image generation model is available"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else if viewModel.supportsImageGeneration(for: selectedImageModel) {
                    Text(NSLocalizedString("生成结果会写入当前会话，返回聊天页即可查看。", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(NSLocalizedString("当前模型不可用于生图，请在模型设置中将用途设为图片生成，或在模型能力中开启可生成图片。", comment: "模型没有生图能力提示"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                imageGenerationStatusContent
            } header: {
                Text(NSLocalizedString("生图状态", comment: "Image generation status section title"))
            } footer: {
                Text(NSLocalizedString("等待时可取消，完成后可复用提示词。", comment: "Image generation status section footer on watch"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    galleryDestination
                } label: {
                    Label(NSLocalizedString("生成相册", comment: "Generated image gallery title"), systemImage: "photo.stack")
                }

                if generatedImageCount > 0 {
                    Text(
                        String(
                            format: NSLocalizedString("已生成 %d 张图片。", comment: "Generated image count"),
                            generatedImageCount
                        )
                    )
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text(NSLocalizedString("打开生成相册可查看、下载或删除已生成图片。", comment: "Gallery entry footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("图片生成", comment: "Image generation view title"))
        .onAppear {
            syncSelectedImageModel()
            loadParameterExpressions(for: appConfig.imageGenerationModelIdentifier)
            validateParameterExpressions()
        }
        .onChange(of: viewModel.activatedModelListVersion) { _, _ in
            let previousIdentifier = appConfig.imageGenerationModelIdentifier
            syncSelectedImageModel()
            if previousIdentifier != appConfig.imageGenerationModelIdentifier {
                loadParameterExpressions(for: appConfig.imageGenerationModelIdentifier)
            }
            validateParameterExpressions()
        }
        .onChange(of: appConfig.imageGenerationModelIdentifier) { oldValue, newValue in
            saveParameterExpressions(for: oldValue)
            loadParameterExpressions(for: newValue)
            validateParameterExpressions()
        }
        .navigationDestination(isPresented: $showGalleryFromStatus) {
            galleryDestination
        }
        .toolbar {
            if !prompt.isEmpty {
                Button(NSLocalizedString("清空", comment: "")) {
                    prompt = ""
                }
            }
        }
    }

    @ViewBuilder
    private var imageGenerationStatusContent: some View {
        switch viewModel.imageGenerationFeedback.phase {
        case .idle:
            Text(NSLocalizedString("尚未开始生图。", comment: "No image generation has been started yet"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("正在生成图片…", comment: "Image generation is in progress"), systemImage: "hourglass")
                    .etFont(.footnote)

                if let startedAt = viewModel.imageGenerationFeedback.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                        Text(
                            String(
                                format: NSLocalizedString("已等待 %d 秒", comment: "Image generation elapsed seconds"),
                                elapsed
                            )
                        )
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                Button(role: .destructive) {
                    viewModel.cancelSending()
                } label: {
                    Text(NSLocalizedString("取消生成", comment: "Cancel image generation"))
                }
                .etFont(.footnote)
            }
        case .success:
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    String(
                        format: NSLocalizedString("生成完成，共 %d 张。", comment: "Image generation succeeded with count"),
                        viewModel.imageGenerationFeedback.imageCount
                    )
                )
                .etFont(.footnote)

                Button {
                    showGalleryFromStatus = true
                } label: {
                    Text(NSLocalizedString("查看结果", comment: "Open generated image gallery"))
                }
                .etFont(.footnote)

                Button {
                    prompt = viewModel.imageGenerationFeedback.prompt
                } label: {
                    Text(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"))
                }
                .etFont(.footnote)
                .disabled(viewModel.imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .failure:
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("生成失败", comment: "Image generation failed status"))
                    .etFont(.footnote)
                    .foregroundStyle(.red)

                if let reason = viewModel.imageGenerationFeedback.errorMessage, !reason.isEmpty {
                    Text(reason)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Button {
                    retryLastImageGeneration()
                } label: {
                    Text(NSLocalizedString("重试生成", comment: "Retry image generation"))
                }
                .etFont(.footnote)

                Button {
                    prompt = viewModel.imageGenerationFeedback.prompt
                } label: {
                    Text(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"))
                }
                .etFont(.footnote)
                .disabled(viewModel.imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("已取消生成", comment: "Image generation cancelled status"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    retryLastImageGeneration()
                } label: {
                    Text(NSLocalizedString("再次生成", comment: "Generate again"))
                }
                .etFont(.footnote)

                Button {
                    prompt = viewModel.imageGenerationFeedback.prompt
                } label: {
                    Text(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"))
                }
                .etFont(.footnote)
                .disabled(viewModel.imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func generatedImageItems(from messages: [ChatMessage]) -> [WatchGeneratedImageItem] {
        guard !messages.isEmpty else { return [] }

        var items: [WatchGeneratedImageItem] = []
        for (index, message) in messages.enumerated() where message.role == .assistant {
            guard let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty else { continue }
            let prompt = messages[..<index].last(where: { $0.role == .user })?.content ?? ""
            for fileName in imageFileNames {
                items.append(
                    WatchGeneratedImageItem(
                        id: "\(message.id.uuidString)-\(fileName)",
                        messageID: message.id,
                        fileName: fileName,
                        prompt: prompt
                    )
                )
            }
        }
        return items.reversed()
    }

    private func syncSelectedImageModel() {
        if let matched = viewModel.imageGenerationModel(with: appConfig.imageGenerationModelIdentifier) {
            appConfig.imageGenerationModelIdentifier = matched.id
            return
        }

        if let firstModel = availableImageModels.first {
            appConfig.imageGenerationModelIdentifier = firstModel.id
        } else {
            appConfig.imageGenerationModelIdentifier = ""
        }
    }

    private func triggerImageGeneration() {
        let promptToSend = trimmedPrompt
        guard !promptToSend.isEmpty else { return }
        guard let runtimeParameters = runtimeOverrideParameters(showErrorMessage: true) else { return }

        prompt = ""
        submitImageGeneration(prompt: promptToSend, runtimeOverrideParameters: runtimeParameters)
    }

    private func retryLastImageGeneration() {
        guard let runtimeParameters = runtimeOverrideParameters(showErrorMessage: true) else { return }
        viewModel.retryLastImageGeneration(
            model: selectedImageModel,
            runtimeOverrideParameters: runtimeParameters
        )
    }

    private func submitImageGeneration(
        prompt: String,
        referenceImages: [ImageAttachment] = [],
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) {
        guard let selectedImageModel else {
            viewModel.addErrorMessage(NSLocalizedString("当前没有可用的生图模型，请先在模型管理中启用。", comment: "No image generation model can be used"))
            return
        }

        guard viewModel.supportsImageGeneration(for: selectedImageModel) else {
            viewModel.addErrorMessage(NSLocalizedString("当前模型不可用于生图，请在模型设置中将用途设为图片生成，或在模型能力中开启可生成图片。", comment: "模型没有生图能力提示"))
            return
        }

        viewModel.generateImage(
            prompt: prompt,
            referenceImages: referenceImages,
            model: selectedImageModel,
            runtimeOverrideParameters: runtimeOverrideParameters
        )
    }

    private func validateParameterExpressions() {
        _ = parseRuntimeOverrideParameters()
    }

    private func runtimeOverrideParameters(showErrorMessage: Bool) -> [String: JSONValue]? {
        switch parseRuntimeOverrideParameters() {
        case .success(let parameters):
            return parameters
        case .failure(let error):
            if showErrorMessage {
                viewModel.addErrorMessage(error.localizedDescription)
            }
            return nil
        }
    }

    private func addParameterExpressionEntry() {
        parameterExpressionEntries.append(WatchImageParameterExpressionEntry(text: ""))
    }

    private func deleteParameterExpressionEntries(at offsets: IndexSet) {
        parameterExpressionEntries.remove(atOffsets: offsets)
        if parameterExpressionEntries.isEmpty {
            addParameterExpressionEntry()
        }
        saveParameterExpressions(for: appConfig.imageGenerationModelIdentifier)
        validateParameterExpressions()
    }

    private func validateParameterExpressionEntry(withId id: UUID) {
        guard let index = parameterExpressionEntries.firstIndex(where: { $0.id == id }) else { return }
        var entry = parameterExpressionEntries[index]
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entry.error = nil
            parameterExpressionEntries[index] = entry
            return
        }

        do {
            _ = try ParameterExpressionParser.parse(trimmed)
            entry.error = nil
        } catch {
            entry.error = error.localizedDescription
        }
        parameterExpressionEntries[index] = entry
    }

    private func parseRuntimeOverrideParameters() -> Result<[String: JSONValue], Error> {
        var updatedEntries = parameterExpressionEntries
        var parsedExpressions: [ParameterExpressionParser.ParsedExpression] = []
        var firstErrorMessage: String?

        for index in updatedEntries.indices {
            let trimmed = updatedEntries[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                updatedEntries[index].error = nil
                continue
            }
            do {
                let parsed = try ParameterExpressionParser.parse(trimmed)
                parsedExpressions.append(parsed)
                updatedEntries[index].error = nil
            } catch {
                let lineError = String(format: NSLocalizedString("第%d行：%@", comment: ""), index + 1, error.localizedDescription)
                let message = String(
                    format: NSLocalizedString("生图参数解析失败：%@", comment: "Image generation parameter expression parse failed"),
                    lineError
                )
                updatedEntries[index].error = message
                if firstErrorMessage == nil {
                    firstErrorMessage = message
                }
            }
        }

        parameterExpressionEntries = updatedEntries

        if let firstErrorMessage {
            return .failure(
                NSError(
                    domain: "ImageGenerationFeatureView",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: firstErrorMessage]
                )
            )
        }

        return .success(ParameterExpressionParser.buildParameters(from: parsedExpressions))
    }

    private func loadParameterExpressions(for modelIdentifier: String) {
        guard !modelIdentifier.isEmpty else {
            parameterExpressionEntries = [WatchImageParameterExpressionEntry(text: "")]
            return
        }
        let map = decodeParameterExpressionStore()
        let lines = (map[modelIdentifier] ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            parameterExpressionEntries = [WatchImageParameterExpressionEntry(text: "")]
        } else {
            parameterExpressionEntries = lines.map { WatchImageParameterExpressionEntry(text: $0) }
        }
    }

    private func saveParameterExpressions(for modelIdentifier: String) {
        guard !modelIdentifier.isEmpty else { return }
        var map = decodeParameterExpressionStore()
        let normalizedLines = parameterExpressionEntries
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if normalizedLines.isEmpty {
            map.removeValue(forKey: modelIdentifier)
        } else {
            map[modelIdentifier] = normalizedLines.joined(separator: "\n")
        }
        encodeParameterExpressionStore(map)
    }

    private func decodeParameterExpressionStore() -> [String: String] {
        guard let data = appConfig.imageGenerationParameterExpressionsByModel.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private func encodeParameterExpressionStore(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map),
              let string = String(data: data, encoding: .utf8) else {
            appConfig.imageGenerationParameterExpressionsByModel = "{}"
            return
        }
        appConfig.imageGenerationParameterExpressionsByModel = string
    }
}

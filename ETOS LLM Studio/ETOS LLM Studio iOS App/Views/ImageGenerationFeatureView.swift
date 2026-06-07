// ============================================================================
// ImageGenerationFeatureView.swift
// ============================================================================
// ImageGenerationFeatureView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import Foundation
import PhotosUI
import ETOSCore
import SwiftUI

struct ImageGenerationFeatureView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var prompt: String = ""
    @State private var referenceImages: [ImageAttachment] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showGalleryFromStatus: Bool = false
    @State private var parameterExpressionEntries: [ImageParameterExpressionEntry] = [ImageParameterExpressionEntry(text: "")]

    private var availableImageModels: [RunnableModel] {
        viewModel.imageGenerationModelOptions
    }

    private var imageGenerationModelIdentifier: String {
        get { appConfig.imageGenerationModelIdentifier }
        nonmutating set { setImageGenerationModelIdentifier(newValue) }
    }

    private var imageGenerationModelIdentifierBinding: Binding<String> {
        Binding(
            get: { appConfig.imageGenerationModelIdentifier },
            set: { setImageGenerationModelIdentifier($0) }
        )
    }

    private var imageGenerationParameterExpressionsByModel: String {
        get { appConfig.imageGenerationParameterExpressionsByModel }
        nonmutating set { appConfig.imageGenerationParameterExpressionsByModel = newValue }
    }

    private var selectedImageModel: RunnableModel? {
        if let matched = viewModel.imageGenerationModel(with: imageGenerationModelIdentifier) {
            return matched
        }
        return availableImageModels.first
    }

    private func setImageGenerationModelIdentifier(_ identifier: String) {
        AppConfigStore.persistSynchronously(.text(identifier), for: .imageGenerationModelIdentifier)
        appConfig.imageGenerationModelIdentifier = identifier
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

    private var selectedImageModelLabel: String {
        guard let selectedImageModel else { return "" }
        return "\(selectedImageModel.model.displayName) | \(selectedImageModel.provider.name)"
    }

    private var galleryDestination: some View {
        ImageGenerationGalleryView(
            onReusePrompt: { reusedPrompt in
                prompt = reusedPrompt
            },
            onContinueGeneration: { reusedPrompt, attachment in
                prompt = reusedPrompt
                referenceImages = [attachment]
                selectedPhotos = []
            }
        )
        .environmentObject(viewModel)
    }

    var body: some View {
        Form {
            Section {
                if availableImageModels.isEmpty {
                    Text(NSLocalizedString("请先在模型管理中启用至少一个生图模型。", comment: "No image generation model is available"))
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        ImageGenerationModelSelectionView(
                            models: availableImageModels,
                            selectedModelIdentifier: imageGenerationModelIdentifierBinding
                        )
                    } label: {
                        HStack {
                            Text(NSLocalizedString("生图模型", comment: "Image generation model picker title"))
                            MarqueeText(
                                content: selectedImageModelLabel,
                                uiFont: .preferredFont(forTextStyle: .body)
                            )
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } footer: {
                Text(NSLocalizedString("生图请求会使用这里单独选择的模型，不影响主聊天模型。也可以在“提供商与模型管理 > 专用模型”中统一设置。", comment: "Image generation uses independent model selection"))
            }

            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 120)
            } header: {
                Text(NSLocalizedString("提示词", comment: ""))
            } footer: {
                Text(NSLocalizedString("输入提示词，独立发起生图请求。", comment: ""))
            }

            Section {
                ForEach($parameterExpressionEntries) { $entry in
                    ImageParameterExpressionRow(entry: $entry)
                        .onChange(of: entry.text) { _, _ in
                            validateParameterExpressionEntry(withId: entry.id)
                            saveParameterExpressions(for: imageGenerationModelIdentifier)
                        }
                }
                .onDelete(perform: deleteParameterExpressionEntries)

                Button {
                    addParameterExpressionEntry()
                } label: {
                    Label(NSLocalizedString("添加表达式", comment: ""), systemImage: "plus")
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
            }

            Section {
                PhotosPicker(selection: $selectedPhotos, matching: .images) {
                    Label(NSLocalizedString("选择参考图", comment: ""), systemImage: "photo")
                }

                if referenceImages.isEmpty {
                    Text(NSLocalizedString("暂未添加参考图", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(referenceImages) { attachment in
                                ZStack(alignment: .topTrailing) {
                                    imagePreview(for: attachment)
                                        .frame(width: 88, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    Button {
                                        referenceImages.removeAll { $0.id == attachment.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white)
                                            .background(Color.black.opacity(0.45), in: Circle())
                                    }
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text(NSLocalizedString("参考图片（可选）", comment: ""))
            } footer: {
                Text(NSLocalizedString("图片会和提示词一起发送，作为图生图参考。", comment: ""))
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
                } else if viewModel.supportsImageGeneration(for: selectedImageModel) {
                    Text(NSLocalizedString("生成结果会写入当前会话，返回聊天页即可查看。", comment: ""))
                } else {
                    Text(NSLocalizedString("当前模型不可用于生图，请在模型设置中将用途设为图片生成，或在模型能力中开启可生成图片。", comment: "模型没有生图能力提示"))
                }
            }

            Section {
                imageGenerationStatusContent
            } header: {
                Text(NSLocalizedString("生图状态", comment: "Image generation status section title"))
            } footer: {
                Text(NSLocalizedString("等待时可取消，完成后可复用提示词或继续编辑。", comment: "Image generation status section footer"))
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
            }
        }
        .navigationTitle(NSLocalizedString("图片生成", comment: "Image generation view title"))
        .onAppear {
            syncSelectedImageModel()
            loadParameterExpressions(for: imageGenerationModelIdentifier)
            validateParameterExpressions()
        }
        .onChange(of: selectedPhotos) { _, newItems in
            loadSelectedPhotos(newItems)
        }
        .onChange(of: viewModel.activatedModelListVersion) { _, _ in
            let previousIdentifier = imageGenerationModelIdentifier
            syncSelectedImageModel()
            if previousIdentifier != imageGenerationModelIdentifier {
                loadParameterExpressions(for: imageGenerationModelIdentifier)
            }
            validateParameterExpressions()
        }
        .onChange(of: imageGenerationModelIdentifier) { oldValue, newValue in
            saveParameterExpressions(for: oldValue)
            loadParameterExpressions(for: newValue)
            validateParameterExpressions()
        }
        .navigationDestination(isPresented: $showGalleryFromStatus) {
            galleryDestination
        }
        .toolbar {
            if !prompt.isEmpty || !referenceImages.isEmpty {
                Button(NSLocalizedString("清空", comment: "")) {
                    prompt = ""
                    referenceImages = []
                    selectedPhotos = []
                }
            }
        }
    }

    @ViewBuilder
    private func imagePreview(for attachment: ImageAttachment) -> some View {
        if let thumbnail = attachment.thumbnailImage {
            Image(uiImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var imageGenerationStatusContent: some View {
        switch viewModel.imageGenerationFeedback.phase {
        case .idle:
            Text(NSLocalizedString("尚未开始生图。", comment: "No image generation has been started yet"))
                .foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(NSLocalizedString("正在生成图片…", comment: "Image generation is in progress"))
                        .etFont(.headline)
                }

                if let startedAt = viewModel.imageGenerationFeedback.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                        Text(
                            String(
                                format: NSLocalizedString("已等待 %d 秒", comment: "Image generation elapsed seconds"),
                                elapsed
                            )
                        )
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.imageGenerationFeedback.prompt.isEmpty {
                    Text(viewModel.imageGenerationFeedback.prompt)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Button(role: .destructive) {
                    viewModel.cancelSending()
                } label: {
                    Label(NSLocalizedString("取消生成", comment: "Cancel image generation"), systemImage: "stop.circle")
                }
            }
        case .success:
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    String(
                        format: NSLocalizedString("生成完成，共 %d 张。", comment: "Image generation succeeded with count"),
                        viewModel.imageGenerationFeedback.imageCount
                    )
                )
                .etFont(.headline)

                if !viewModel.imageGenerationFeedback.prompt.isEmpty {
                    Text(viewModel.imageGenerationFeedback.prompt)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Button {
                        showGalleryFromStatus = true
                    } label: {
                        Label(NSLocalizedString("查看结果", comment: "Open generated image gallery"), systemImage: "photo.stack")
                    }

                    Button {
                        prompt = viewModel.imageGenerationFeedback.prompt
                    } label: {
                        Label(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(viewModel.imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        case .failure:
            VStack(alignment: .leading, spacing: 10) {
                Text(NSLocalizedString("生成失败", comment: "Image generation failed status"))
                    .etFont(.headline)
                    .foregroundStyle(.red)

                if let reason = viewModel.imageGenerationFeedback.errorMessage, !reason.isEmpty {
                    Text(reason)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        retryLastImageGeneration()
                    } label: {
                        Label(NSLocalizedString("重试生成", comment: "Retry image generation"), systemImage: "arrow.clockwise")
                    }

                    Button {
                        prompt = viewModel.imageGenerationFeedback.prompt
                    } label: {
                        Label(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"), systemImage: "text.quote")
                    }
                    .disabled(viewModel.imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 10) {
                Text(NSLocalizedString("已取消生成", comment: "Image generation cancelled status"))
                    .etFont(.headline)
                    .foregroundStyle(.secondary)

                if !viewModel.imageGenerationFeedback.prompt.isEmpty {
                    Text(viewModel.imageGenerationFeedback.prompt)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Button {
                        retryLastImageGeneration()
                    } label: {
                        Label(NSLocalizedString("再次生成", comment: "Generate again"), systemImage: "arrow.clockwise")
                    }

                    Button {
                        prompt = viewModel.imageGenerationFeedback.prompt
                    } label: {
                        Label(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"), systemImage: "text.quote")
                    }
                    .disabled(viewModel.imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func generatedImageItems(from messages: [ChatMessage]) -> [GeneratedImageItem] {
        guard !messages.isEmpty else { return [] }

        var items: [GeneratedImageItem] = []
        for (index, message) in messages.enumerated() where message.role == .assistant {
            guard let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty else { continue }
            let prompt = messages[..<index].last(where: { $0.role == .user })?.content ?? ""
            for fileName in imageFileNames {
                items.append(
                    GeneratedImageItem(
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

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let attachment = ImageAttachment.from(image: image) {
                    await MainActor.run {
                        referenceImages.append(attachment)
                    }
                }
            }
            await MainActor.run {
                selectedPhotos = []
            }
        }
    }

    private func syncSelectedImageModel() {
        if let matched = viewModel.imageGenerationModel(with: imageGenerationModelIdentifier) {
            imageGenerationModelIdentifier = matched.id
            return
        }

        if let firstModel = availableImageModels.first {
            imageGenerationModelIdentifier = firstModel.id
        } else {
            imageGenerationModelIdentifier = ""
        }
    }

    private func triggerImageGeneration() {
        guard let selectedImageModel else {
            viewModel.addErrorMessage(NSLocalizedString("当前没有可用的生图模型，请先在模型管理中启用。", comment: "No image generation model can be used"))
            return
        }

        guard viewModel.supportsImageGeneration(for: selectedImageModel) else {
            viewModel.addErrorMessage(NSLocalizedString("当前模型不可用于生图，请在模型设置中将用途设为图片生成，或在模型能力中开启可生成图片。", comment: "模型没有生图能力提示"))
            return
        }

        let promptToSend = trimmedPrompt
        guard !promptToSend.isEmpty else { return }
        guard let runtimeParameters = runtimeOverrideParameters(showErrorMessage: true) else { return }

        let imagesToSend = referenceImages
        prompt = ""
        referenceImages = []
        selectedPhotos = []

        viewModel.generateImage(
            prompt: promptToSend,
            referenceImages: imagesToSend,
            model: selectedImageModel,
            runtimeOverrideParameters: runtimeParameters
        )
    }

    private func retryLastImageGeneration() {
        guard let runtimeParameters = runtimeOverrideParameters(showErrorMessage: true) else { return }
        viewModel.retryLastImageGeneration(
            model: selectedImageModel,
            runtimeOverrideParameters: runtimeParameters
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
        parameterExpressionEntries.append(ImageParameterExpressionEntry(text: ""))
    }

    private func deleteParameterExpressionEntries(at offsets: IndexSet) {
        parameterExpressionEntries.remove(atOffsets: offsets)
        if parameterExpressionEntries.isEmpty {
            addParameterExpressionEntry()
        }
        saveParameterExpressions(for: imageGenerationModelIdentifier)
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
            parameterExpressionEntries = [ImageParameterExpressionEntry(text: "")]
            return
        }
        let map = decodeParameterExpressionStore()
        let lines = (map[modelIdentifier] ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            parameterExpressionEntries = [ImageParameterExpressionEntry(text: "")]
        } else {
            parameterExpressionEntries = lines.map { ImageParameterExpressionEntry(text: $0) }
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
        guard let data = imageGenerationParameterExpressionsByModel.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private func encodeParameterExpressionStore(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map),
              let string = String(data: data, encoding: .utf8) else {
            imageGenerationParameterExpressionsByModel = "{}"
            return
        }
        imageGenerationParameterExpressionsByModel = string
    }
}

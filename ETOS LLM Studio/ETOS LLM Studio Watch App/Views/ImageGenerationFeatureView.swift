import SwiftUI
import Shared

private struct WatchGeneratedImageItem: Identifiable {
    let id: String
    let messageID: UUID
    let fileName: String
    let prompt: String
}

private struct WatchImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let prompt: String
}

struct ImageGenerationFeatureView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @AppStorage("imageGenerationModelIdentifier") private var imageGenerationModelIdentifier: String = ""
    @AppStorage("imageGenerationParameterExpressionsByModel") private var imageGenerationParameterExpressionsByModel: String = "{}"
    @State private var prompt: String = ""
    @State private var showGalleryFromStatus: Bool = false
    @State private var parameterExpressionEntries: [WatchImageParameterExpressionEntry] = [WatchImageParameterExpressionEntry(text: "")]

    private var availableImageModels: [RunnableModel] {
        viewModel.imageGenerationModelOptions
    }

    private var selectedImageModel: RunnableModel? {
        if let matched = viewModel.imageGenerationModel(with: imageGenerationModelIdentifier) {
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(NSLocalizedString("生图模型", comment: "Image generation model picker title"), selection: $imageGenerationModelIdentifier) {
                        ForEach(availableImageModels) { model in
                            Text("\(model.model.displayName) | \(model.provider.name)")
                                .tag(model.id)
                        }
                    }
                }
            } footer: {
                Text(NSLocalizedString("生图请求会使用这里单独选择的模型，不影响主聊天模型。", comment: "Image generation uses independent model selection"))
                    .font(.footnote)
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
                Text("输入提示词，独立发起生图请求。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($parameterExpressionEntries) { $entry in
                    WatchImageParameterExpressionRow(entry: $entry)
                        .onChange(of: entry.text) { _, _ in
                            validateParameterExpressionEntry(withId: entry.id)
                            saveParameterExpressions(for: imageGenerationModelIdentifier)
                        }
                }
                .onDelete(perform: deleteParameterExpressionEntries)

                Button("添加表达式") {
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
                .font(.footnote)
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if viewModel.supportsImageGeneration(for: selectedImageModel) {
                    Text("生成结果会写入当前会话，返回聊天页即可查看。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前模型未启用生图能力，请在模型设置中开启“生图”。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                imageGenerationStatusContent
            } header: {
                Text(NSLocalizedString("生图状态", comment: "Image generation status section title"))
            } footer: {
                Text(NSLocalizedString("等待时可取消，完成后可复用提示词。", comment: "Image generation status section footer on watch"))
                    .font(.footnote)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text(NSLocalizedString("打开生成相册可查看、下载或删除已生成图片。", comment: "Gallery entry footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("图片生成", comment: "Image generation view title"))
        .onAppear {
            syncSelectedImageModel()
            loadParameterExpressions(for: imageGenerationModelIdentifier)
            validateParameterExpressions()
        }
        .onChange(of: viewModel.activatedModels) { _, _ in
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
            if !prompt.isEmpty {
                Button("清空") {
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
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                Label(NSLocalizedString("正在生成图片…", comment: "Image generation is in progress"), systemImage: "hourglass")
                    .font(.footnote)

                if let startedAt = viewModel.imageGenerationFeedback.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                        Text(
                            String(
                                format: NSLocalizedString("已等待 %d 秒", comment: "Image generation elapsed seconds"),
                                elapsed
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }

                Button(role: .destructive) {
                    viewModel.cancelSending()
                } label: {
                    Text(NSLocalizedString("取消生成", comment: "Cancel image generation"))
                }
                .font(.footnote)
            }
        case .success:
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    String(
                        format: NSLocalizedString("生成完成，共 %d 张。", comment: "Image generation succeeded with count"),
                        viewModel.imageGenerationFeedback.imageCount
                    )
                )
                .font(.footnote)

                Button {
                    showGalleryFromStatus = true
                } label: {
                    Text(NSLocalizedString("查看结果", comment: "Open generated image gallery"))
                }
                .font(.footnote)

                Button {
                    prompt = viewModel.imageGenerationFeedback.prompt
                } label: {
                    Text(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"))
                }
                .font(.footnote)
                .disabled(viewModel.imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .failure:
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("生成失败", comment: "Image generation failed status"))
                    .font(.footnote)
                    .foregroundStyle(.red)

                if let reason = viewModel.imageGenerationFeedback.errorMessage, !reason.isEmpty {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Button {
                    retryLastImageGeneration()
                } label: {
                    Text(NSLocalizedString("重试生成", comment: "Retry image generation"))
                }
                .font(.footnote)

                Button {
                    prompt = viewModel.imageGenerationFeedback.prompt
                } label: {
                    Text(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"))
                }
                .font(.footnote)
                .disabled(viewModel.imageGenerationFeedback.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("已取消生成", comment: "Image generation cancelled status"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    retryLastImageGeneration()
                } label: {
                    Text(NSLocalizedString("再次生成", comment: "Generate again"))
                }
                .font(.footnote)

                Button {
                    prompt = viewModel.imageGenerationFeedback.prompt
                } label: {
                    Text(NSLocalizedString("复用提示词", comment: "Reuse last image generation prompt"))
                }
                .font(.footnote)
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
            viewModel.addErrorMessage(NSLocalizedString("当前模型未启用生图能力，请在模型设置中开启“生图”。", comment: "Model has no image generation capability"))
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
                let lineError = "第\(index + 1)行：\(error.localizedDescription)"
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

private struct WatchImageParameterExpressionEntry: Identifiable, Equatable {
    let id: UUID
    var text: String
    var error: String?

    init(id: UUID = UUID(), text: String, error: String? = nil) {
        self.id = id
        self.text = text
        self.error = error
    }
}

private struct WatchImageParameterExpressionRow: View {
    @Binding var entry: WatchImageParameterExpressionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                NSLocalizedString("生图参数表达式，比如 size = 2048x2048", comment: "Image generation parameter expression placeholder"),
                text: $entry.text.watchKeyboardNewlineBinding()
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())

            if let error = entry.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct WatchImageGenerationGalleryView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var previewPayload: WatchImagePreviewPayload?
    @State private var pendingDeleteItem: WatchGeneratedImageItem?
    @State private var alertMessage: String?
    let onReusePrompt: (String) -> Void
    let onContinueGeneration: (String, ImageAttachment) -> Void
    
    private let galleryColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var generatedImageItems: [WatchGeneratedImageItem] {
        let messages = viewModel.allMessagesForSession
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

    var body: some View {
        ScrollView {
            if generatedImageItems.isEmpty {
                Text(NSLocalizedString("当前会话暂无生图结果。", comment: "No generated images in current session"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                    .padding(.horizontal, 10)
            } else {
                LazyVGrid(columns: galleryColumns, spacing: 8) {
                    ForEach(generatedImageItems.prefix(20)) { item in
                        galleryCard(for: item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle(NSLocalizedString("生成相册", comment: "Generated image gallery title"))
        .sheet(item: $previewPayload) { payload in
            ScrollView {
                VStack(spacing: 8) {
                    Image(uiImage: payload.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                    if !payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(payload.prompt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .confirmationDialog(
            NSLocalizedString("确认删除这张图片？", comment: "Delete generated image confirmation"),
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { isPresented in
                    if !isPresented { pendingDeleteItem = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Delete generated image"), role: .destructive) {
                if let item = pendingDeleteItem {
                    viewModel.removeGeneratedImage(fileName: item.fileName, fromMessageID: item.messageID)
                    alertMessage = NSLocalizedString("图片已删除。", comment: "Generated image deleted")
                }
                pendingDeleteItem = nil
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                pendingDeleteItem = nil
            }
        }
        .alert(
            Text(NSLocalizedString("提示", comment: "Notice")),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented { alertMessage = nil }
                }
            )
        ) {
            Button(NSLocalizedString("确定", comment: "OK"), role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private func galleryCard(for item: WatchGeneratedImageItem) -> some View {
        if let image = generatedUIImage(fileName: item.fileName) {
            let promptText = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayPrompt = promptText.isEmpty
                ? NSLocalizedString("图片生成", comment: "Image generation view title")
                : promptText

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    previewPayload = WatchImagePreviewPayload(image: image, prompt: item.prompt)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Text(displayPrompt)
                            .font(.footnote)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    Text(item.fileName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let fileURL = generatedImageFileURL(fileName: item.fileName) {
                        if #available(watchOS 9.0, *) {
                            ShareLink(item: fileURL) {
                                Image(systemName: "square.and.arrow.down")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(NSLocalizedString("下载", comment: "Download generated image"))
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        onReusePrompt(item.prompt)
                        dismiss()
                    } label: {
                        Image(systemName: "text.quote")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("复用提示词", comment: "Reuse prompt from generated image"))

                    Button {
                        if let attachment = imageAttachment(for: item.fileName) {
                            onContinueGeneration(item.prompt, attachment)
                            dismiss()
                        } else {
                            alertMessage = NSLocalizedString("图片文件不存在。", comment: "Generated image file missing")
                        }
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("以此图继续生成", comment: "Continue generation with selected image"))

                    Button(role: .destructive) {
                        pendingDeleteItem = item
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("删除", comment: "Delete generated image"))
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.gray.opacity(0.15))
            )
        } else {
            Label(NSLocalizedString("图片丢失", comment: "Image missing"), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func generatedUIImage(fileName: String) -> UIImage? {
        let url = Persistence.getImageDirectory().appendingPathComponent(fileName)
        return UIImage(contentsOfFile: url.path)
    }

    private func generatedImageFileURL(fileName: String) -> URL? {
        let url = Persistence.getImageDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func imageAttachment(for fileName: String) -> ImageAttachment? {
        let fileURL = Persistence.getImageDirectory().appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "png":
            mimeType = "image/png"
        case "webp":
            mimeType = "image/webp"
        case "heic", "heif":
            mimeType = "image/heic"
        default:
            mimeType = "image/jpeg"
        }
        return ImageAttachment(data: data, mimeType: mimeType, fileName: fileName)
    }
}

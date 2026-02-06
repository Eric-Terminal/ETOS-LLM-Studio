import SwiftUI
import PhotosUI
import Photos
import Shared

private struct GeneratedImageItem: Identifiable {
    let id: String
    let messageID: UUID
    let fileName: String
    let prompt: String
}

private struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let prompt: String
}

struct ImageGenerationFeatureView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @AppStorage("imageGenerationModelIdentifier") private var imageGenerationModelIdentifier: String = ""
    @State private var prompt: String = ""
    @State private var referenceImages: [ImageAttachment] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showGalleryFromStatus: Bool = false

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
    }

    private var generatedImageCount: Int {
        generatedImageItems(from: viewModel.allMessagesForSession).count
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
                    Picker(NSLocalizedString("生图模型", comment: "Image generation model picker title"), selection: $imageGenerationModelIdentifier) {
                        ForEach(availableImageModels) { model in
                            Text("\(model.model.displayName) · \(model.provider.name)")
                                .tag(model.id)
                        }
                    }
                }
            } footer: {
                Text(NSLocalizedString("生图请求会使用这里单独选择的模型，不影响主聊天模型。", comment: "Image generation uses independent model selection"))
            }

            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 120)
            } header: {
                Text("提示词")
            } footer: {
                Text("输入提示词，独立发起生图请求。")
            }

            Section {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 4, matching: .images) {
                    Label("选择参考图", systemImage: "photo")
                }

                if referenceImages.isEmpty {
                    Text("暂未添加参考图")
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
                Text("参考图片（可选）")
            } footer: {
                Text("图片会和提示词一起发送，作为图生图参考。")
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
                    Text("生成结果会写入当前会话，返回聊天页即可查看。")
                } else {
                    Text("当前模型未启用生图能力，请在模型设置中开启“生图”。")
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            } footer: {
                Text(NSLocalizedString("打开生成相册可查看、下载或删除已生成图片。", comment: "Gallery entry footer"))
            }
        }
        .navigationTitle(NSLocalizedString("图片生成", comment: "Image generation view title"))
        .onAppear {
            syncSelectedImageModel()
        }
        .onChange(of: selectedPhotos) { _, newItems in
            loadSelectedPhotos(newItems)
        }
        .onChange(of: viewModel.activatedModels) { _, _ in
            syncSelectedImageModel()
        }
        .navigationDestination(isPresented: $showGalleryFromStatus) {
            galleryDestination
        }
        .toolbar {
            if !prompt.isEmpty || !referenceImages.isEmpty {
                Button("清空") {
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
                        .font(.headline)
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.imageGenerationFeedback.prompt.isEmpty {
                    Text(viewModel.imageGenerationFeedback.prompt)
                        .font(.footnote)
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
                .font(.headline)

                if !viewModel.imageGenerationFeedback.prompt.isEmpty {
                    Text(viewModel.imageGenerationFeedback.prompt)
                        .font(.footnote)
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
                    .font(.headline)
                    .foregroundStyle(.red)

                if let reason = viewModel.imageGenerationFeedback.errorMessage, !reason.isEmpty {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.retryLastImageGeneration(model: selectedImageModel)
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
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if !viewModel.imageGenerationFeedback.prompt.isEmpty {
                    Text(viewModel.imageGenerationFeedback.prompt)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Button {
                        viewModel.retryLastImageGeneration(model: selectedImageModel)
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
            viewModel.addErrorMessage(NSLocalizedString("当前模型未启用生图能力，请在模型设置中开启“生图”。", comment: "Model has no image generation capability"))
            return
        }

        let promptToSend = trimmedPrompt
        guard !promptToSend.isEmpty else { return }

        let imagesToSend = referenceImages
        prompt = ""
        referenceImages = []
        selectedPhotos = []

        viewModel.generateImage(prompt: promptToSend, referenceImages: imagesToSend, model: selectedImageModel)
    }
}

private struct ImageGenerationGalleryView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var previewPayload: ImagePreviewPayload?
    @State private var pendingDeleteItem: GeneratedImageItem?
    @State private var alertMessage: String?
    let onReusePrompt: (String) -> Void
    let onContinueGeneration: (String, ImageAttachment) -> Void
    
    private let galleryColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var generatedImageItems: [GeneratedImageItem] {
        let messages = viewModel.allMessagesForSession
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

    var body: some View {
        ScrollView {
            if generatedImageItems.isEmpty {
                Text(NSLocalizedString("当前会话暂无生图结果。", comment: "No generated images in current session"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                    .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: galleryColumns, spacing: 12) {
                    ForEach(generatedImageItems) { item in
                        galleryCard(for: item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(NSLocalizedString("生成相册", comment: "Generated image gallery title"))
        .sheet(item: $previewPayload) { payload in
            ScrollView {
                VStack(spacing: 16) {
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
    private func galleryCard(for item: GeneratedImageItem) -> some View {
        let image = generatedUIImage(fileName: item.fileName)
        let promptText = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPrompt = promptText.isEmpty
            ? NSLocalizedString("图片生成", comment: "Image generation view title")
            : promptText

        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard let image else { return }
                previewPayload = ImagePreviewPayload(image: image, prompt: item.prompt)
            } label: {
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color(uiColor: .secondarySystemBackground)
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            Text(displayPrompt)
                .font(.footnote)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(item.fileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Menu {
                    Button {
                        onReusePrompt(item.prompt)
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("复用提示词", comment: "Reuse prompt from generated image"), systemImage: "text.quote")
                    }

                    Button {
                        if let attachment = imageAttachment(for: item.fileName) {
                            onContinueGeneration(item.prompt, attachment)
                            dismiss()
                        } else {
                            alertMessage = NSLocalizedString("图片文件不存在。", comment: "Generated image file missing")
                        }
                    } label: {
                        Label(NSLocalizedString("以此图继续生成", comment: "Continue generation with selected image"), systemImage: "wand.and.stars")
                    }

                    Button {
                        Task {
                            await downloadImage(item)
                        }
                    } label: {
                        Label(NSLocalizedString("下载", comment: "Download generated image"), systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        pendingDeleteItem = item
                    } label: {
                        Label(NSLocalizedString("删除", comment: "Delete generated image"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("更多", comment: "More actions"))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func generatedUIImage(fileName: String) -> UIImage? {
        let url = Persistence.getImageDirectory().appendingPathComponent(fileName)
        return UIImage(contentsOfFile: url.path)
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

    private func downloadImage(_ item: GeneratedImageItem) async {
        do {
            try await saveImageToPhotoLibrary(fileName: item.fileName)
            await MainActor.run {
                alertMessage = NSLocalizedString("已保存到相册。", comment: "Saved to photo library")
            }
        } catch {
            await MainActor.run {
                alertMessage = String(
                    format: NSLocalizedString("保存失败: %@", comment: "Save generated image failed"),
                    error.localizedDescription
                )
            }
        }
    }

    private func saveImageToPhotoLibrary(fileName: String) async throws {
        let fileURL = Persistence.getImageDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "ImageGenerationGallery", code: 404, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("图片文件不存在。", comment: "Generated image file missing")])
        }

        let status = await requestPhotoLibraryAccessStatus()
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "ImageGenerationGallery", code: 403, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("没有相册访问权限。", comment: "Photo library permission denied")])
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "ImageGenerationGallery", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("保存到相册失败。", comment: "Failed to save image to photo library")]))
                }
            }
        }
    }

    private func requestPhotoLibraryAccessStatus() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

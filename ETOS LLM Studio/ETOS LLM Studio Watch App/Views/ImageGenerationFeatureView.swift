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
    @State private var prompt: String = ""

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
                NavigationLink {
                    WatchImageGenerationGalleryView()
                        .environmentObject(viewModel)
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
        }
        .onChange(of: viewModel.activatedModels) { _, _ in
            syncSelectedImageModel()
        }
        .toolbar {
            if !prompt.isEmpty {
                Button("清空") {
                    prompt = ""
                }
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

        prompt = ""
        viewModel.generateImage(prompt: promptToSend, model: selectedImageModel)
    }
}

private struct WatchImageGenerationGalleryView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var previewPayload: WatchImagePreviewPayload?
    @State private var pendingDeleteItem: WatchGeneratedImageItem?
    @State private var alertMessage: String?
    
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
}

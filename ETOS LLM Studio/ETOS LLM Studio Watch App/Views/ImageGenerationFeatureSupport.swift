// ============================================================================
// ImageGenerationFeatureSupport.swift
// ============================================================================
// watchOS 图片生成页面支持组件
// - 负责模型选择、参数表达式行、生成相册与图片预览
// ============================================================================

import SwiftUI
import Shared

struct WatchGeneratedImageItem: Identifiable {
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

struct WatchImageModelSelectionListView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModelIdentifier: String

    var body: some View {
        List {
            ForEach(models) { model in
                Button {
                    select(model)
                } label: {
                    selectionRow(
                        title: model.model.displayName,
                        subtitle: "\(model.provider.name) · \(model.model.modelName)",
                        isSelected: selectedModelIdentifier == model.id
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("生图模型", comment: "Image generation model picker title"))
    }

    private func select(_ model: RunnableModel) {
        selectedModelIdentifier = model.id
        dismiss()
    }

    @ViewBuilder
    private func selectionRow(title: String, subtitle: String? = nil, isSelected: Bool) -> some View {
        MarqueeTitleSubtitleSelectionRow(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            subtitleUIFont: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            )
        )
    }
}

struct WatchImageParameterExpressionEntry: Identifiable, Equatable {
    let id: UUID
    var text: String
    var error: String?

    init(id: UUID = UUID(), text: String, error: String? = nil) {
        self.id = id
        self.text = text
        self.error = error
    }
}

struct WatchImageParameterExpressionRow: View {
    @Binding var entry: WatchImageParameterExpressionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                NSLocalizedString("生图参数表达式，比如 size = 2048x2048", comment: "Image generation parameter expression placeholder"),
                text: $entry.text.watchKeyboardNewlineBinding()
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.footnote.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct WatchImageGenerationGalleryView: View {
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
                    .etFont(.footnote)
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
            WatchGeneratedImagePreviewSheet(payload: payload)
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
                            .etFont(.footnote)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    Text(item.fileName)
                        .etFont(.caption2)
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
                .etFont(.footnote)
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

private struct WatchGeneratedImagePreviewSheet: View {
    let payload: WatchImagePreviewPayload

    @State private var zoomScale = 1.0
    @State private var settledOffset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    private let maxZoomScale = 6.0
    private let contentInset: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let contentSize = CGSize(
                width: max(containerSize.width - contentInset * 2, 1),
                height: max(containerSize.height - contentInset * 2, 1)
            )
            let effectiveOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
                proposed: CGSize(
                    width: settledOffset.width + dragTranslation.width,
                    height: settledOffset.height + dragTranslation.height
                ),
                containerSize: containerSize,
                contentSize: contentSize,
                scale: CGFloat(zoomScale)
            )

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: payload.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: contentSize.width, height: contentSize.height)
                    .scaleEffect(CGFloat(zoomScale))
                    .offset(effectiveOffset)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($dragTranslation) { value, state, _ in
                                guard zoomScale > 1.01 else {
                                    state = .zero
                                    return
                                }
                                state = value.translation
                            }
                            .onEnded { value in
                                guard zoomScale > 1.01 else {
                                    settledOffset = .zero
                                    return
                                }
                                settledOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
                                    proposed: CGSize(
                                        width: settledOffset.width + value.translation.width,
                                        height: settledOffset.height + value.translation.height
                                    ),
                                    containerSize: containerSize,
                                    contentSize: contentSize,
                                    scale: CGFloat(zoomScale)
                                )
                            }
                    )
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .focusable(true)
            .digitalCrownRotation(
                $zoomScale,
                from: 1.0,
                through: maxZoomScale,
                by: 0.05,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onChange(of: zoomScale) { _, newValue in
                if newValue <= 1.01 {
                    settledOffset = .zero
                } else {
                    settledOffset = ETWatchMarkdownImageZoomMath.clampedOffset(
                        proposed: settledOffset,
                        containerSize: containerSize,
                        contentSize: contentSize,
                        scale: CGFloat(newValue)
                    )
                }
            }
        }
    }
}

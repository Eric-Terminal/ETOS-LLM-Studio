// ============================================================================
// ImageGenerationFeatureSupport.swift
// ============================================================================
// iOS 图片生成页面支持组件
// - 负责模型选择、参数表达式行、生成相册与图片保存
// ============================================================================

import Foundation
import Photos
import Shared
import SwiftUI
import UIKit

struct GeneratedImageItem: Identifiable {
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

struct ImageGenerationModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModelIdentifier: String

    var body: some View {
        List {
            ForEach(models) { model in
                Button {
                    select(model.id)
                } label: {
                    MarqueeTitleSubtitleSelectionRow(
                        title: model.model.displayName,
                        subtitle: "\(model.provider.name) · \(model.model.modelName)",
                        isSelected: selectedModelIdentifier == model.id,
                        subtitleUIFont: .monospacedSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                            weight: .regular
                        )
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("生图模型", comment: "Image generation model picker title"))
    }

    private func select(_ identifier: String) {
        selectedModelIdentifier = identifier
        dismiss()
    }
}

struct ImageParameterExpressionEntry: Identifiable, Equatable {
    let id: UUID
    var text: String
    var error: String?

    init(id: UUID = UUID(), text: String, error: String? = nil) {
        self.id = id
        self.text = text
        self.error = error
    }
}

struct ImageParameterExpressionRow: View {
    @Binding var entry: ImageParameterExpressionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                NSLocalizedString("生图参数表达式，比如 size = 2048x2048", comment: "Image generation parameter expression placeholder"),
                text: $entry.text
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .etFont(.body.monospaced())

            if let error = entry.error {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct ImageGenerationGalleryView: View {
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
                            .etFont(.footnote)
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
                .etFont(.footnote)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(item.fileName)
                    .etFont(.caption2)
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

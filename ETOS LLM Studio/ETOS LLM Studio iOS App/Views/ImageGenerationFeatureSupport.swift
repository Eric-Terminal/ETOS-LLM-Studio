// ============================================================================
// ImageGenerationFeatureSupport.swift
// ============================================================================
// iOS 图片相册支持组件
// - 扫描当前会话中助手返回的图片消息
// - 提供预览、保存到系统相册与删除本地图片
// ============================================================================

import Foundation
import Photos
import ETOSCore
import SwiftUI
import UIKit

struct AssistantImageItem: Identifiable, Sendable {
    let id: String
    let messageID: UUID
    let fileName: String
    let sourcePrompt: String
}

private struct AssistantImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let sourcePrompt: String
}

struct ImageGenerationGalleryView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var assistantImageItems: [AssistantImageItem] = []
    @State private var previewPayload: AssistantImagePreviewPayload?
    @State private var pendingDeleteItem: AssistantImageItem?
    @State private var alertMessage: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var isShowingIntroDetails = false

    private let galleryColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                settingsIntroCard(
                    title: NSLocalizedString("图片相册", comment: "Image album intro title"),
                    summary: NSLocalizedString("集中查看当前会话里由助手返回并保存到本机的图片。", comment: "Image album intro summary"),
                    details: NSLocalizedString("图片相册说明正文", comment: "Image album intro details"),
                    isExpanded: $isShowingIntroDetails
                )
                .padding(.horizontal)
                .padding(.top)

                if assistantImageItems.isEmpty {
                    Text(NSLocalizedString("当前会话暂无助手返回的图片。", comment: "No assistant images in current session"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                        .padding(.horizontal)
                } else {
                    LazyVGrid(columns: galleryColumns, spacing: 12) {
                        ForEach(assistantImageItems) { item in
                            galleryCard(for: item)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
        }
        .navigationTitle(NSLocalizedString("图片相册", comment: "Assistant image album title"))
        .onAppear(perform: refreshAssistantImageItems)
        .onChange(of: viewModel.allMessageIdentityVersion) { _, _ in
            refreshAssistantImageItems()
        }
        .onChange(of: viewModel.currentSession?.id) { _, _ in
            refreshAssistantImageItems()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        .sheet(item: $previewPayload) { payload in
            ScrollView {
                VStack(spacing: 16) {
                    Image(uiImage: payload.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)

                    if !payload.sourcePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(payload.sourcePrompt)
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .confirmationDialog(
            NSLocalizedString("确认删除这张图片？", comment: "Delete assistant image confirmation"),
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { isPresented in
                    if !isPresented { pendingDeleteItem = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Delete assistant image"), role: .destructive) {
                if let item = pendingDeleteItem {
                    viewModel.removeGeneratedImage(fileName: item.fileName, fromMessageID: item.messageID)
                    assistantImageItems.removeAll { $0.id == item.id }
                    alertMessage = NSLocalizedString("图片已删除。", comment: "Assistant image deleted")
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

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 10) {
                Text(NSLocalizedString(title, comment: "图片相册介绍卡片标题"))
                    .etFont(.headline.weight(.semibold))
                Text(NSLocalizedString(summary, comment: "图片相册介绍卡片摘要"))
                    .etFont(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    isExpanded.wrappedValue = true
                } label: {
                    Text(NSLocalizedString("进一步了解…", comment: "图片相册介绍卡片展开按钮"))
                        .etFont(.footnote.weight(.medium))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(NSLocalizedString(details, comment: "图片相册介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "图片相册介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    @ViewBuilder
    private func galleryCard(for item: AssistantImageItem) -> some View {
        let image = generatedUIImage(fileName: item.fileName)
        let promptText = item.sourcePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPrompt = promptText.isEmpty
            ? NSLocalizedString("助手图片", comment: "Assistant image fallback title")
            : promptText

        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard let image else { return }
                previewPayload = AssistantImagePreviewPayload(image: image, sourcePrompt: item.sourcePrompt)
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
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        Task {
                            await downloadImage(item)
                        }
                    } label: {
                        Label(NSLocalizedString("下载", comment: "Download assistant image"), systemImage: "square.and.arrow.down")
                    }

                    Button(role: .destructive) {
                        pendingDeleteItem = item
                    } label: {
                        Label(NSLocalizedString("删除", comment: "Delete assistant image"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("更多", comment: "More actions"))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func refreshAssistantImageItems() {
        let messages = viewModel.allMessagesForSession
        refreshTask?.cancel()
        refreshTask = Task {
            let items = await Task.detached(priority: .userInitiated) {
                Self.makeAssistantImageItems(from: messages)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                assistantImageItems = items
            }
        }
    }

    private nonisolated static func makeAssistantImageItems(from messages: [ChatMessage]) -> [AssistantImageItem] {
        guard !messages.isEmpty else { return [] }

        var items: [AssistantImageItem] = []
        for (index, message) in messages.enumerated() where message.role == .assistant {
            guard let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty else { continue }
            let sourcePrompt = messages[..<index].last(where: { $0.role == .user })?.content ?? ""
            for fileName in imageFileNames {
                items.append(
                    AssistantImageItem(
                        id: "\(message.id.uuidString)-\(fileName)",
                        messageID: message.id,
                        fileName: fileName,
                        sourcePrompt: sourcePrompt
                    )
                )
            }
        }
        return Array(items.reversed())
    }

    private func generatedUIImage(fileName: String) -> UIImage? {
        let url = Persistence.getImageDirectory().appendingPathComponent(fileName)
        return UIImage(contentsOfFile: url.path)
    }

    private func downloadImage(_ item: AssistantImageItem) async {
        do {
            try await saveImageToPhotoLibrary(fileName: item.fileName)
            await MainActor.run {
                alertMessage = NSLocalizedString("已保存到系统相册。", comment: "Saved to photo library")
            }
        } catch {
            await MainActor.run {
                alertMessage = String(
                    format: NSLocalizedString("保存失败：%@", comment: "Save assistant image failed"),
                    error.localizedDescription
                )
            }
        }
    }

    private func saveImageToPhotoLibrary(fileName: String) async throws {
        let fileURL = Persistence.getImageDirectory().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw NSError(domain: "ImageGenerationGallery", code: 404, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("图片文件不存在。", comment: "Assistant image file missing")])
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

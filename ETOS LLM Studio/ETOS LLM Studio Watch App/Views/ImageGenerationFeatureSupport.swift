// ============================================================================
// ImageGenerationFeatureSupport.swift
// ============================================================================
// watchOS 图片相册支持组件
// - 扫描当前会话中助手返回的图片消息
// - 小屏提供预览、分享保存与删除本地图片
// ============================================================================

import Foundation
import SwiftUI
import ETOSCore

struct WatchAssistantImageItem: Identifiable, Sendable {
    let id: String
    let messageID: UUID
    let fileName: String
    let sourcePrompt: String
}

private struct WatchImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct WatchImageGenerationGalleryView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var assistantImageItems: [WatchAssistantImageItem] = []
    @State private var previewPayload: WatchImagePreviewPayload?
    @State private var pendingDeleteItem: WatchAssistantImageItem?
    @State private var alertMessage: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var isShowingIntroDetails = false

    private let galleryColumns: [GridItem] = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                settingsIntroCard(
                    title: NSLocalizedString("图片相册", comment: "Image album intro title"),
                    summary: NSLocalizedString("集中查看当前会话里由助手返回并保存到本机的图片。", comment: "Image album intro summary"),
                    details: NSLocalizedString("图片相册说明正文", comment: "Image album intro details"),
                    isExpanded: $isShowingIntroDetails
                )
                .padding(.horizontal)
                .padding(.top, 4)

                if assistantImageItems.isEmpty {
                    Text(NSLocalizedString("当前会话暂无助手返回的图片。", comment: "No assistant images in current session"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                        .padding(.horizontal)
                } else {
                    LazyVGrid(columns: galleryColumns, spacing: 8) {
                        ForEach(assistantImageItems) { item in
                            galleryCard(for: item)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
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
            WatchAssistantImagePreviewSheet(payload: payload)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .etFont(.footnote)
                    .foregroundStyle(.blue)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString(title, comment: "图片相册介绍卡片标题"))
                        .etFont(.footnote.weight(.semibold))
                    Text(NSLocalizedString(summary, comment: "图片相册介绍卡片摘要"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "图片相册介绍卡片展开按钮"))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.15))
        )
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "图片相册介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private func galleryCard(for item: WatchAssistantImageItem) -> some View {
        let image = generatedUIImage(fileName: item.fileName)
        let promptText = item.sourcePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPrompt = promptText.isEmpty
            ? NSLocalizedString("助手图片", comment: "Assistant image fallback title")
            : promptText

        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard let image else { return }
                previewPayload = WatchImagePreviewPayload(image: image)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color.gray.opacity(0.15)
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
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

                if let fileURL = generatedImageFileURL(fileName: item.fileName),
                   #available(watchOS 9.0, *) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("下载", comment: "Download assistant image"))
                }
            }

            Button(role: .destructive) {
                pendingDeleteItem = item
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("删除", comment: "Delete assistant image"))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.15))
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

    private nonisolated static func makeAssistantImageItems(from messages: [ChatMessage]) -> [WatchAssistantImageItem] {
        guard !messages.isEmpty else { return [] }

        var items: [WatchAssistantImageItem] = []
        for (index, message) in messages.enumerated() where message.role == .assistant {
            guard let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty else { continue }
            let sourcePrompt = messages[..<index].last(where: { $0.role == .user })?.content ?? ""
            for fileName in imageFileNames {
                items.append(
                    WatchAssistantImageItem(
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

    private func generatedImageFileURL(fileName: String) -> URL? {
        let url = Persistence.getImageDirectory().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private struct WatchAssistantImagePreviewSheet: View {
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

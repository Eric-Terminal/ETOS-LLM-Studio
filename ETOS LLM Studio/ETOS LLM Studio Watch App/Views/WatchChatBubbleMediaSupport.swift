// ============================================================================
// WatchChatBubbleMediaSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡使用的图片预览包装、附件加载与缓存逻辑。
// ============================================================================

import SwiftUI
import ETOSCore

private struct WatchChatPreloadedAttachmentImagesKey: EnvironmentKey {
    static let defaultValue: [String: UIImage] = [:]
}

extension EnvironmentValues {
    var watchChatPreloadedAttachmentImages: [String: UIImage] {
        get { self[WatchChatPreloadedAttachmentImagesKey.self] }
        set { self[WatchChatPreloadedAttachmentImagesKey.self] = newValue }
    }
}

struct AttachmentImageView: View {
    let fileName: String
    let height: CGFloat
    let onPreview: (UIImage) -> Void

    @Environment(\.watchChatPreloadedAttachmentImages) private var preloadedImages
    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    private var resolvedImage: UIImage? {
        preloadedImages[fileName] ?? image
    }

    var body: some View {
        Group {
            if let image = resolvedImage {
                Button {
                    onPreview(image)
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: height)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo")
                                .etFont(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Text(NSLocalizedString("图片丢失", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    )
            }
        }
        .task(id: fileName) {
            guard preloadedImages[fileName] == nil else { return }
            guard !didAttemptLoad else { return }
            didAttemptLoad = true
            await loadImage()
        }
    }

    private func loadImage() async {
        if let cached = ChatAttachmentImageCache.image(for: fileName) {
            await MainActor.run {
                image = cached
            }
            return
        }

        let uiImage = await Task.detached(priority: .userInitiated) {
            let fileURL = Persistence.getImageDirectory().appendingPathComponent(fileName)
            return UIImage(contentsOfFile: fileURL.path)
                ?? Persistence.loadImage(fileName: fileName).flatMap { UIImage(data: $0) }
        }.value
        guard let uiImage else { return }
        ChatAttachmentImageCache.store(uiImage, for: fileName)
        await MainActor.run {
            image = uiImage
        }
    }
}

struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct WatchAttachmentImagePreviewSheet: View {
    let payload: ImagePreviewPayload

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
        .accessibilityLabel(NSLocalizedString("图片预览", comment: ""))
    }
}

private enum ChatAttachmentImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        return cache
    }()

    static func image(for fileName: String) -> UIImage? {
        cache.object(forKey: fileName as NSString)
    }

    static func store(_ image: UIImage, for fileName: String) {
        let pixelCost = Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: fileName as NSString, cost: max(1, pixelCost))
    }
}

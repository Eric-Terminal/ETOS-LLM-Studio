// ============================================================================
// ChatBubbleMediaSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳聊天气泡使用的图片缓存、预览包装和附件加载视图。
// ============================================================================

import Foundation
import SwiftUI
import UIKit
import ETOSCore
import ImageIO

struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ChatAttachmentImagePreview: View {
    let payload: ImagePreviewPayload

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ZoomableUIImageScrollView(image: payload.image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("关闭", comment: ""))
            .padding(.top)
            .padding(.trailing)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
    }
}

private struct ZoomableUIImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableUIImageScrollContainerView {
        ZoomableUIImageScrollContainerView(image: image)
    }

    func updateUIView(_ uiView: ZoomableUIImageScrollContainerView, context: Context) {
        uiView.image = image
    }
}

private final class ZoomableUIImageScrollContainerView: UIView, UIScrollViewDelegate {
    var image: UIImage {
        didSet {
            guard oldValue !== image else { return }
            imageView.image = image
            needsZoomReset = true
            setNeedsLayout()
        }
    }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var fittedImageSize: CGSize = .zero
    private var needsZoomReset = true

    init(image: UIImage) {
        self.image = image
        super.init(frame: .zero)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        updateImageFrame()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    private func configureViews() {
        backgroundColor = .black
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTapGesture)
    }

    private func updateImageFrame() {
        guard bounds.width > 0,
              bounds.height > 0,
              image.size.width > 0,
              image.size.height > 0 else {
            return
        }

        let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let targetSize = CGSize(
            width: image.size.width * fitScale,
            height: image.size.height * fitScale
        )
        let previousZoomScale = scrollView.zoomScale
        let shouldReframe = fittedImageSize != targetSize || needsZoomReset
        guard shouldReframe else {
            centerImage()
            return
        }

        scrollView.setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: targetSize)
        scrollView.contentSize = targetSize
        fittedImageSize = targetSize

        if needsZoomReset {
            needsZoomReset = false
        } else {
            scrollView.setZoomScale(min(max(previousZoomScale, 1), scrollView.maximumZoomScale), animated: false)
        }
        centerImage()
    }

    private func centerImage() {
        let horizontalInset = max((bounds.width - scrollView.contentSize.width) / 2, 0)
        let verticalInset = max((bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard scrollView.maximumZoomScale > scrollView.minimumZoomScale else { return }
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
            return
        }

        let targetScale = min(3, scrollView.maximumZoomScale)
        let tapPoint = gesture.location(in: imageView)
        let zoomRectSize = CGSize(
            width: scrollView.bounds.width / targetScale,
            height: scrollView.bounds.height / targetScale
        )
        let zoomRect = CGRect(
            x: tapPoint.x - zoomRectSize.width / 2,
            y: tapPoint.y - zoomRectSize.height / 2,
            width: zoomRectSize.width,
            height: zoomRectSize.height
        )
        scrollView.zoom(to: zoomRect, animated: true)
    }
}

enum ChatAttachmentImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        return cache
    }()

    static func image(for fileName: String) -> UIImage? {
        cache.object(forKey: fileName as NSString)
    }

    static func store(_ image: UIImage, for fileName: String) {
        let pixelCost = Int(image.size.width * image.size.height * image.scale * image.scale)
        cache.setObject(image, forKey: fileName as NSString, cost: max(1, pixelCost))
    }

    /// 离屏导出只保留展示尺寸缩略图，避免原图与长图位图叠加占用内存。
    static func preload(fileNames: [String]) async throws -> ChatAttachmentImagePreloadResult {
        let uniqueFileNames = Array(Set(fileNames))
        guard !uniqueFileNames.isEmpty else {
            return ChatAttachmentImagePreloadResult(images: [:])
        }

        return try await Task.detached(priority: .userInitiated) {
            var images: [String: UIImage] = [:]
            images.reserveCapacity(uniqueFileNames.count)
            for fileName in uniqueFileNames {
                try Task.checkCancellation()
                let fileURL = Persistence.getImageDirectory().appendingPathComponent(fileName)
                let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil)
                    ?? Persistence.loadImage(fileName: fileName).flatMap {
                        CGImageSourceCreateWithData($0 as CFData, nil)
                    }
                guard let source else { continue }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_024
                ]
                if let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                ) {
                    images[fileName] = UIImage(cgImage: cgImage)
                }
            }
            return ChatAttachmentImagePreloadResult(images: images)
        }.value
    }
}

struct ChatAttachmentImagePreloadResult: @unchecked Sendable {
    let images: [String: UIImage]
}

private struct ChatTranscriptPreloadedAttachmentImagesKey: EnvironmentKey {
    static let defaultValue: [String: UIImage] = [:]
}

extension EnvironmentValues {
    var chatTranscriptPreloadedAttachmentImages: [String: UIImage] {
        get { self[ChatTranscriptPreloadedAttachmentImagesKey.self] }
        set { self[ChatTranscriptPreloadedAttachmentImagesKey.self] = newValue }
    }
}

struct ChatBubbleOpenMoreGestureModifier: ViewModifier {
    let isSelectionMode: Bool
    let onToggleSelection: () -> Void
    let onOpenMore: (() -> Void)?

    func body(content: Content) -> some View {
        if isSelectionMode {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture()
                        .onEnded { _ in
                            onToggleSelection()
                        }
                )
        } else if let onOpenMore {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            onOpenMore()
                        }
                )
        } else {
            content
        }
    }
}

struct AttachmentImageView: View {
    let fileName: String
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let onPreview: (UIImage) -> Void

    @Environment(\.chatTranscriptPreloadedAttachmentImages) private var preloadedImages
    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    private var displayedImage: UIImage? {
        preloadedImages[fileName] ?? image ?? ChatAttachmentImageCache.image(for: fileName)
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                Button {
                    onPreview(image)
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: minWidth, maxWidth: maxWidth)
                        .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(minWidth: minWidth, maxWidth: maxWidth)
                    .frame(height: height)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "photo")
                                .etFont(.system(size: 20))
                                .foregroundStyle(.secondary)
                            Text(NSLocalizedString("图片丢失", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 3, y: 1)
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

        let loadTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let fileURL = Persistence.getImageDirectory().appendingPathComponent(fileName)
            if let image = UIImage(contentsOfFile: fileURL.path) {
                return image
            }
            guard let data = Persistence.loadImage(fileName: fileName) else { return nil }
            return UIImage(data: data)
        }
        let loadedImage = await loadTask.value

        guard let loadedImage else { return }
        ChatAttachmentImageCache.store(loadedImage, for: fileName)
        await MainActor.run {
            image = loadedImage
        }
    }
}

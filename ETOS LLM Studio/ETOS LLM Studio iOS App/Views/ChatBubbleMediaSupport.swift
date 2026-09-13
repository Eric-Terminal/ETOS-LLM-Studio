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
    var fileName: String? = nil
}

struct ChatAttachmentImagePreview: View {
    let payload: ImagePreviewPayload

    @Environment(\.dismiss) private var dismiss
    @State private var originalImage: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ZoomableUIImageScrollView(image: originalImage ?? payload.image)
                .id(payload.id)
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
        .task(id: payload.id) {
            originalImage = nil
            guard let fileName = payload.fileName else { return }
            let image = await DisplayImageLoader.shared.originalAttachment(named: fileName)
            guard !Task.isCancelled else { return }
            originalImage = image
        }
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

final class ZoomableUIImageScrollContainerView: UIView, UIScrollViewDelegate {
    var image: UIImage {
        didSet {
            guard oldValue !== image else { return }
            imageView.image = image
            // 缩略图升级为原图时保留用户已经开始的缩放和拖动。
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
        let previousOffset = scrollView.contentOffset
        let preservesPosition = !needsZoomReset
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
        if preservesPosition {
            let inset = scrollView.contentInset
            scrollView.contentOffset = CGPoint(
                x: min(max(previousOffset.x, -inset.left), max(-inset.left, scrollView.contentSize.width - bounds.width + inset.right)),
                y: min(max(previousOffset.y, -inset.top), max(-inset.top, scrollView.contentSize.height - bounds.height + inset.bottom))
            )
        }
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
                // 子按钮和 WKWebView 会优先消费触摸；多选时由整行蒙层统一接管。
                .allowsHitTesting(false)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToggleSelection)
                }
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
    let onDownload: (() -> Void)?
    let onDelete: (() -> Void)?

    init(
        fileName: String,
        minWidth: CGFloat,
        maxWidth: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat,
        onPreview: @escaping (UIImage) -> Void,
        onDownload: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.fileName = fileName
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.height = height
        self.cornerRadius = cornerRadius
        self.onPreview = onPreview
        self.onDownload = onDownload
        self.onDelete = onDelete
    }

    @Environment(\.chatTranscriptPreloadedAttachmentImages) private var preloadedImages
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedFileName: String?
    @State private var displaySize: CGSize = .zero
    @State private var showsDeleteConfirmation = false

    private var displayedImage: UIImage? {
        preloadedImages[fileName] ?? (loadedFileName == fileName ? image : nil)
    }

    private var imageTarget: DisplayImageTarget {
        DisplayImageTarget(size: displaySize, scale: displayScale)
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { displaySize = $0 }
        .task(id: "\(fileName)|\(imageTarget.width)x\(imageTarget.height)") {
            guard preloadedImages[fileName] == nil else { return }
            await loadImage()
        }
        .contextMenu {
            if let onDownload {
                Button(action: onDownload) {
                    Label(
                        NSLocalizedString("下载", comment: "Download image attachment"),
                        systemImage: "square.and.arrow.down"
                    )
                }
            }
            if onDelete != nil {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label(
                        NSLocalizedString("删除图片", comment: "Delete one image attachment"),
                        systemImage: "trash"
                    )
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("确认删除这张图片？", comment: "Delete one image attachment confirmation"),
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Confirm deleting one image attachment"), role: .destructive) {
                onDelete?()
            }
            Button(NSLocalizedString("取消", comment: "Cancel deleting one image attachment"), role: .cancel) {}
        }
    }

    private func loadImage() async {
        guard !imageTarget.isEmpty else { return }
        let prepared = await DisplayImageLoader.shared.attachment(named: fileName, target: imageTarget)
        guard !Task.isCancelled else { return }
        image = prepared?.image
        loadedFileName = fileName
    }
}

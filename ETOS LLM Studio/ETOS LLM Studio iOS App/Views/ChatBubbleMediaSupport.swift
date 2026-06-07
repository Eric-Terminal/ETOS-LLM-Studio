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

struct ImagePreviewWrapper: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ImagePreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

private enum ChatAttachmentImageCache {
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
}

struct ChatBubbleOpenMoreGestureModifier: ViewModifier {
    let onOpenMore: (() -> Void)?

    func body(content: Content) -> some View {
        if let onOpenMore {
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

    @State private var image: UIImage?
    @State private var didAttemptLoad = false

    var body: some View {
        Group {
            if let image {
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

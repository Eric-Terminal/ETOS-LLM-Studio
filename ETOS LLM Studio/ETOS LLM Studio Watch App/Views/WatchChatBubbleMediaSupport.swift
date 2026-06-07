// ============================================================================
// WatchChatBubbleMediaSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件收纳 watchOS 聊天气泡使用的图片预览包装、附件加载与缓存逻辑。
// ============================================================================

import SwiftUI
import ETOSCore

struct AttachmentImageView: View {
    let fileName: String
    let height: CGFloat
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

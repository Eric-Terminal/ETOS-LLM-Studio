// ============================================================================
// ChatBubble+AttachmentImageView.swift
// ============================================================================
// watchOS 聊天气泡中的图片附件缩略图加载与预览入口。
// ============================================================================

import SwiftUI
import WatchKit
import Foundation
import MarkdownUI
import Shared
import AVFoundation
import Combine

struct AttachmentImageView: View {
    let fileName: String
    let height: CGFloat
    let onPreview: (UIImage) -> Void

    @State var image: UIImage?
    @State var didAttemptLoad = false

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

    func loadImage() async {
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

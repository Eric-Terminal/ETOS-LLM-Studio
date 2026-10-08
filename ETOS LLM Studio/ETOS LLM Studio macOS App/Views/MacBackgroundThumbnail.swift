import AppKit
import AVFoundation
import ETOSCore
import SwiftUI

struct MacBackgroundThumbnail: View {
    let file: MacBackgroundFile
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: file.isVideo ? "video" : "photo").foregroundStyle(.secondary) }
        }
        .frame(width: 96, height: 64)
        .accessibilityHidden(true)
        .task(id: file) {
            image = nil
            let file = file, target = DisplayImageTarget(size: CGSize(width: 96, height: 64), scale: scale, fillsBounds: false)
            let worker = Task.detached(priority: .utility) { await Self.prepare(file, target: target) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            image = result.image
        }
    }

    nonisolated private static func prepare(_ file: MacBackgroundFile, target: DisplayImageTarget) async -> MacPreparedBackgroundThumbnail {
        guard file.isVideo else {
            return MacPreparedBackgroundThumbnail(image: await DisplayImageLoader.shared.image(at: file.url, target: target)?.image)
        }
        let asset = AVURLAsset(url: file.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: CGFloat(target.width), height: CGFloat(target.height))
        do {
            try Task.checkCancellation()
            let frame = try await withTaskCancellationHandler { try await generator.image(at: .zero) }
                onCancel: { generator.cancelAllCGImageGeneration() }
            return MacPreparedBackgroundThumbnail(image: NSImage(cgImage: frame.image, size: .zero))
        } catch { return MacPreparedBackgroundThumbnail(image: nil) }
    }
}

private struct MacPreparedBackgroundThumbnail: @unchecked Sendable { let image: NSImage? }

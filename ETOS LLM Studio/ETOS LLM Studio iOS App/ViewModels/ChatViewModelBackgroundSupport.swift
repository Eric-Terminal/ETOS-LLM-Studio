// ============================================================================
// ChatViewModelBackgroundSupport.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 聊天视图模型的背景图片加载、模糊缓存与磁盘缓存辅助。
// ============================================================================

import CoreImage
import Foundation
import ImageIO
import ETOSCore
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(UIKit)
import UIKit
#endif

extension ChatViewModel {
    var currentBackgroundIsVideo: Bool {
        ConfigLoader.isVideoBackgroundFile(currentBackgroundImage)
    }

    var currentBackgroundMediaURL: URL? {
        guard !currentBackgroundImage.isEmpty else { return nil }
        return ConfigLoader.getBackgroundsDirectory().appendingPathComponent(currentBackgroundImage)
    }

    func updateBackgroundDisplayTarget(size: CGSize, scale: CGFloat) {
        let target = DisplayImageTarget(size: size, scale: scale, fillsBounds: backgroundContentMode == "fill")
        guard !target.isEmpty, target != backgroundDisplayTarget else { return }
        let isResize = currentBackgroundImageBlurredUIImage != nil
        backgroundDisplayTarget = target
        refreshBlurredBackgroundImage(coalescesResize: isResize)
    }

    func refreshBlurredBackgroundImage(coalescesResize: Bool = false) {
        backgroundBlurTask?.cancel()
        guard enableBackground, !currentBackgroundImage.isEmpty else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard !currentBackgroundIsVideo else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard !backgroundDisplayTarget.isEmpty else { return }
        let expectedName = currentBackgroundImage
        let expectedRadius = backgroundBlur
        let target = backgroundDisplayTarget
        backgroundBlurTask = Task { [weak self] in
            if coalescesResize {
                // 键盘和窗口动画会逐帧改变尺寸；短暂复用旧位图，稳定后只解码最终尺寸。
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            if let cached = await ChatBackgroundStartupCache.shared.image(
                named: expectedName, radius: expectedRadius, target: target
            ) {
                guard !Task.isCancelled else { return }
                self?.currentBackgroundImageBlurredUIImage = cached
                return
            }
            let prepared = await DisplayImageLoader.shared.background(named: expectedName, target: target)
            guard !Task.isCancelled else { return }
            let cacheName = "\(expectedName)__display_\(target.width)x\(target.height)_\(target.fillsBounds)_\(prepared?.sourceRevision ?? "missing")"
            let cacheKey = "\(cacheName)|\(expectedRadius)" as NSString
            if let cached = self?.blurredBackgroundImageCache.object(forKey: cacheKey) {
                self?.currentBackgroundImageBlurredUIImage = cached
                return
            }
            let rendered = await Self.renderBackgroundImage(prepared, cacheName: cacheName, radius: expectedRadius)
            guard !Task.isCancelled, let self,
                  self.enableBackground,
                  self.currentBackgroundImage == expectedName,
                  self.backgroundBlur == expectedRadius,
                  self.backgroundDisplayTarget == target else { return }
            if let rendered { self.blurredBackgroundImageCache.setObject(rendered, forKey: cacheKey) }
            self.currentBackgroundImageBlurredUIImage = rendered
            if let rendered, let prepared {
                await ChatBackgroundStartupCache.shared.store(
                    rendered, named: expectedName, radius: expectedRadius,
                    target: target, sourceRevision: prepared.sourceRevision
                )
            }
        }
    }

    func waitForBackgroundImage() async {
        await backgroundBlurTask?.value
    }

    /// 导出独立准备自己的像素尺寸，不能把 iPad 当前背景改成窄长图的清晰度。
    func backgroundImageForExport(size: CGSize, scale: CGFloat) async -> UIImage? {
        guard enableBackground, !currentBackgroundImage.isEmpty, !currentBackgroundIsVideo else { return nil }
        let name = currentBackgroundImage
        let radius = backgroundBlur
        let target = DisplayImageTarget(size: size, scale: scale, fillsBounds: backgroundContentMode == "fill")
        let prepared = await DisplayImageLoader.shared.background(named: name, target: target)
        let cacheName = "\(name)__display_\(target.width)x\(target.height)_\(target.fillsBounds)_\(prepared?.sourceRevision ?? "missing")"
        return await Self.renderBackgroundImage(prepared, cacheName: cacheName, radius: radius)
    }

    nonisolated private static func renderBackgroundImage(
        _ prepared: PreparedDisplayImage?, cacheName: String, radius: Double
    ) async -> UIImage? {
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled, let prepared else { return nil as UIImage? }
            let diskCacheURL = Self.blurredDiskCacheURL(for: cacheName, radius: radius)
            if radius > 0.01, let cached = Self.loadBlurredImageFromDisk(at: diskCacheURL) { return cached }
            guard radius > 0.01, let source = prepared.image.cgImage,
                  let blurred = Self.makeBlurredCGImage(from: source, radius: radius * prepared.sourcePixelScale)
            else { return prepared.image }
            let image = UIImage(cgImage: blurred)
            guard !Task.isCancelled else { return nil }
            Self.saveBlurredImageToDisk(image, at: diskCacheURL)
            Self.cleanupBlurredDiskCache(keeping: diskCacheURL)
            return image
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func makeBlurredCGImage(from baseCGImage: CGImage, radius: Double) -> CGImage? {
        if let cgImage = blurCGImageWithCoreImage(baseCGImage, radius: radius) {
            return cgImage
        }
#if canImport(Accelerate)
        return blurCGImageWithVImage(baseCGImage, radius: radius)
#else
        return nil
#endif
    }

    nonisolated private static func blurCGImageWithCoreImage(_ baseCGImage: CGImage, radius: Double) -> CGImage? {
        let ciImage = CIImage(cgImage: baseCGImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        let cropped = output.cropped(to: ciImage.extent)
        let context = CIContext()
        return context.createCGImage(cropped, from: ciImage.extent)
    }

#if canImport(Accelerate)
    nonisolated private static func blurCGImageWithVImage(_ baseCGImage: CGImage, radius: Double) -> CGImage? {
        let kernelSize = boxKernelSize(for: radius)
        guard kernelSize > 1 else { return baseCGImage }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passRetained(colorSpace),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )
        defer { format.colorSpace?.release() }

        var sourceBuffer = vImage_Buffer()
        var error = vImageBuffer_InitWithCGImage(
            &sourceBuffer,
            &format,
            nil,
            baseCGImage,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { return nil }
        defer { free(sourceBuffer.data) }

        var destinationBuffer = vImage_Buffer()
        error = vImageBuffer_Init(
            &destinationBuffer,
            sourceBuffer.height,
            sourceBuffer.width,
            format.bitsPerPixel,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { return nil }
        defer { free(destinationBuffer.data) }

        var temporaryBuffer = vImage_Buffer()
        error = vImageBuffer_Init(
            &temporaryBuffer,
            sourceBuffer.height,
            sourceBuffer.width,
            format.bitsPerPixel,
            vImage_Flags(kvImageNoFlags)
        )
        guard error == kvImageNoError else { return nil }
        defer { free(temporaryBuffer.data) }

        let flags = vImage_Flags(kvImageEdgeExtend)
        error = vImageBoxConvolve_ARGB8888(
            &sourceBuffer,
            &destinationBuffer,
            nil,
            0,
            0,
            kernelSize,
            kernelSize,
            nil,
            flags
        )
        guard error == kvImageNoError else { return nil }
        error = vImageBoxConvolve_ARGB8888(
            &destinationBuffer,
            &temporaryBuffer,
            nil,
            0,
            0,
            kernelSize,
            kernelSize,
            nil,
            flags
        )
        guard error == kvImageNoError else { return nil }
        error = vImageBoxConvolve_ARGB8888(
            &temporaryBuffer,
            &destinationBuffer,
            nil,
            0,
            0,
            kernelSize,
            kernelSize,
            nil,
            flags
        )
        guard error == kvImageNoError else { return nil }

        error = kvImageNoError
        guard let blurredCGImage = vImageCreateCGImageFromBuffer(
            &destinationBuffer,
            &format,
            nil,
            nil,
            vImage_Flags(kvImageNoFlags),
            &error
        )?.takeRetainedValue(),
              error == kvImageNoError else {
            return nil
        }
        return blurredCGImage
    }

    nonisolated private static func boxKernelSize(for radius: Double) -> UInt32 {
        let clampedRadius = max(0, radius)
        let estimated = Int((clampedRadius * 2.4).rounded())
        let odd = max(1, estimated | 1)
        return UInt32(min(odd, 151))
    }
#endif

    nonisolated private static func blurredDiskCacheURL(for name: String, radius: Double) -> URL {
        blurredDiskCacheDirectory().appendingPathComponent(blurredDiskCacheFilename(for: name, radius: radius))
    }

    nonisolated private static func blurredDiskCacheDirectory() -> URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return cachesDirectory.appendingPathComponent("blurred-background-cache", isDirectory: true)
    }

    nonisolated private static func blurredDiskCacheFilename(for name: String, radius: Double) -> String {
        let scaled = Int((radius * 10).rounded())
        let sanitized = name.replacingOccurrences(of: "/", with: "_")
        return "\(sanitized)__blur_\(scaled).jpg"
    }

    nonisolated private static func loadBlurredImageFromDisk(at url: URL) -> UIImage? {
        // 磁盘命中也在后台完成解码，不能把 JPEG 首次解压留给下一帧渲染。
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        return UIImage(cgImage: image)
    }

    nonisolated private static func saveBlurredImageToDisk(_ image: UIImage, at url: URL) {
        guard let data = image.jpegData(compressionQuality: 0.92) ?? image.pngData() else { return }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            return
        }
    }

    nonisolated private static func cleanupBlurredDiskCache(keeping keepURL: URL) {
        let directory = keepURL.deletingLastPathComponent()
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        let keepPath = keepURL.standardizedFileURL.path
        for fileURL in fileURLs where fileURL.standardizedFileURL.path != keepPath {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

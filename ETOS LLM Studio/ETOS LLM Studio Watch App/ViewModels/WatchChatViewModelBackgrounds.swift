// ============================================================================
// WatchChatViewModelBackgrounds.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 的背景图片加载、模糊缓存与背景轮换。
// ============================================================================

import Foundation
import SwiftUI
import WatchKit
import ETOSCore
import os.log
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(Accelerate)
import Accelerate
#endif

extension ChatViewModel {
    func refreshBackgroundImages() {
        let images = ConfigLoader.loadBackgroundImages()
        backgroundImages = images
        guard AppConfigStore.shared.didLoadPersistentStore else {
            refreshBlurredBackgroundImage()
            return
        }
        if !images.contains(currentBackgroundImage) {
            currentBackgroundImage = images.first ?? ""
        }
        refreshBlurredBackgroundImage()
    }

    func rotateBackgroundImageIfNeeded() {
        refreshBackgroundImages()
        guard AppConfigStore.shared.didLoadPersistentStore else { return }
        guard enableAutoRotateBackground, !backgroundImages.isEmpty else { return }
        let availableBackgrounds = backgroundImages.filter { $0 != currentBackgroundImage }
        currentBackgroundImage = availableBackgrounds.randomElement() ?? backgroundImages.randomElement() ?? ""
        logger.info("自动轮换背景，新背景: \(self.currentBackgroundImage, privacy: .public)")
    }

    func normalizeBackgroundOpacityIfNeeded() {
        let normalized = WatchBackgroundOpacitySetting.normalized(backgroundOpacity)
        if normalized != backgroundOpacity {
            backgroundOpacity = normalized
        }
    }

    func loadBackgroundImage(named name: String) -> UIImage? {
        if let cached = backgroundImageCache.object(forKey: name as NSString) {
            return cached
        }
        let fileURL = ConfigLoader.getBackgroundsDirectory().appendingPathComponent(name)
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
        backgroundImageCache.setObject(image, forKey: name as NSString)
        return image
    }

    private func blurredCacheKey(for name: String, radius: Double) -> NSString {
        let scaled = Int((radius * 10).rounded())
        return "\(name)|blur:\(scaled)" as NSString
    }

    func refreshBlurredBackgroundImage() {
        backgroundBlurTask?.cancel()
        guard enableBackground, !currentBackgroundImage.isEmpty else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard !currentBackgroundIsVideo else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard let baseImage = loadBackgroundImage(named: currentBackgroundImage) else {
            currentBackgroundImageBlurredUIImage = nil
            return
        }
        guard let baseCGImage = baseImage.cgImage else {
            currentBackgroundImageBlurredUIImage = baseImage
            return
        }
        let baseScale = baseImage.scale
        let baseOrientation = baseImage.imageOrientation
        let radius = backgroundBlur
        if radius <= 0.01 {
            currentBackgroundImageBlurredUIImage = baseImage
            return
        }
        let cacheKey = blurredCacheKey(for: currentBackgroundImage, radius: radius)
        if let cached = blurredBackgroundImageCache.object(forKey: cacheKey) {
            currentBackgroundImageBlurredUIImage = cached
            return
        }
        let diskCacheURL = Self.blurredDiskCacheURL(for: currentBackgroundImage, radius: radius)
        if let diskCachedImage = Self.loadBlurredImageFromDisk(at: diskCacheURL) {
            blurredBackgroundImageCache.setObject(diskCachedImage, forKey: cacheKey)
            currentBackgroundImageBlurredUIImage = diskCachedImage
            return
        }
        currentBackgroundImageBlurredUIImage = baseImage
        let expectedName = currentBackgroundImage
        let expectedRadius = radius
        backgroundBlurTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let blurredCGImage = Self.makeBlurredCGImage(from: baseCGImage, radius: expectedRadius)
            let blurredUIImage = blurredCGImage.map {
                UIImage(cgImage: $0, scale: baseScale, orientation: baseOrientation)
            }
            guard !Task.isCancelled else { return }
            if let blurredUIImage {
                Self.saveBlurredImageToDisk(blurredUIImage, at: diskCacheURL)
                Self.cleanupBlurredDiskCache(keeping: diskCacheURL)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.enableBackground,
                      self.currentBackgroundImage == expectedName,
                      self.backgroundBlur == expectedRadius else { return }
                if let blurredUIImage {
                    self.blurredBackgroundImageCache.setObject(blurredUIImage, forKey: cacheKey)
                }
                self.currentBackgroundImageBlurredUIImage = blurredUIImage ?? self.currentBackgroundImageUIImage
            }
        }
    }

    nonisolated private static func makeBlurredCGImage(from baseCGImage: CGImage, radius: Double) -> CGImage? {
#if canImport(CoreImage)
        if let cgImage = blurCGImageWithCoreImage(baseCGImage, radius: radius) {
            return cgImage
        }
#endif
#if canImport(Accelerate)
        return blurCGImageWithVImage(baseCGImage, radius: radius)
#else
        return nil
#endif
    }

#if canImport(CoreImage)
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
#endif

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
        UIImage(contentsOfFile: url.path)
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

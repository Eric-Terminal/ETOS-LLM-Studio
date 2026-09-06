// ============================================================================
// CustomAppIconImageProcessor.swift
// ============================================================================
// 自定义主屏幕图标的后台图片准备与 PNG 编码
// ============================================================================

import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated struct PreparedCustomAppIconImage: @unchecked Sendable {
    let image: UIImage
}

nonisolated struct RenderedCustomAppIcon: @unchecked Sendable {
    let image: UIImage
    let pngData: Data
}

nonisolated enum CustomAppIconImageError: Error, Sendable {
    case unreadableImage
    case renderFailed
}

nonisolated enum CustomAppIconImageProcessor {
    static let outputPixelSize = 400
    private static let editingMaximumPixelSize = 2_048

    /// 先在后台完成方向校正和降采样，避免把原始相册大图带进 SwiftUI 渲染链路。
    static func prepareImage(from data: Data) throws -> PreparedCustomAppIconImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CustomAppIconImageError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: editingMaximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CustomAppIconImageError.unreadableImage
        }
        return PreparedCustomAppIconImage(image: UIImage(cgImage: image, scale: 1, orientation: .up))
    }

    /// 输出统一的正方形 PNG，避免快捷指令再次裁切时改变用户确认的构图。
    static func renderIcon(
        from preparedImage: PreparedCustomAppIconImage,
        cropRect: CGRect
    ) throws -> RenderedCustomAppIcon {
        guard let sourceImage = preparedImage.image.cgImage else {
            throw CustomAppIconImageError.renderFailed
        }
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(sourceImage.width),
            height: CGFloat(sourceImage.height)
        )
        let boundedCropRect = cropRect.integral.intersection(imageBounds)
        guard boundedCropRect.width > 1,
              boundedCropRect.height > 1,
              let croppedImage = sourceImage.cropping(to: boundedCropRect) else {
            throw CustomAppIconImageError.renderFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: outputPixelSize,
            height: outputPixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CustomAppIconImageError.renderFailed
        }
        context.interpolationQuality = .high
        context.draw(
            croppedImage,
            in: CGRect(x: 0, y: 0, width: outputPixelSize, height: outputPixelSize)
        )
        guard let renderedImage = context.makeImage() else {
            throw CustomAppIconImageError.renderFailed
        }

        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            pngData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CustomAppIconImageError.renderFailed
        }
        CGImageDestinationAddImage(destination, renderedImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CustomAppIconImageError.renderFailed
        }

        return RenderedCustomAppIcon(
            image: UIImage(cgImage: renderedImage, scale: 1, orientation: .up),
            pngData: pngData as Data
        )
    }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

extension MacBackgroundLibrary {
    func prepareCrop(_ file: MacBackgroundFile) throws -> MacPreparedBackgroundCrop {
        try Task.checkCancellation()
        try validate(file)
        guard !file.isVideo, let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { throw LibraryError.invalidMedia }
        let size = try MacBackgroundImageEditing.pixelSize(source)
        let preview = try MacBackgroundImageEditing.decode(source, maximumDimension: 1600)
        try Task.checkCancellation()
        try validate(file)
        return MacPreparedBackgroundCrop(file: file, pixelSize: size, preview: NSImage(cgImage: preview, size: .zero))
    }

    func saveCrop(_ file: MacBackgroundFile, parameters: MacBackgroundCropParameters) async throws -> MacBackgroundFile {
        try Task.checkCancellation()
        try validate(file)
        guard !file.isVideo, parameters.zoom.isFinite, parameters.horizontal.isFinite, parameters.vertical.isFinite,
              (1...6).contains(parameters.zoom), (0...1).contains(parameters.horizontal), (0...1).contains(parameters.vertical),
              let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { throw LibraryError.invalidMedia }
        let size = try MacBackgroundImageEditing.pixelSize(source)
        let image = try MacBackgroundImageEditing.decode(source, maximumDimension: Int(max(size.width, size.height)))
        let actualSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let rect = parameters.pixelRect(for: actualSize)
        guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else { throw LibraryError.invalidMedia }
        try Task.checkCancellation()
        try validate(file)
        return try await importImage(cropped)
    }

    /// 图片裁切和图库 HEIC 等图片统一输出 PNG，保留透明度，原始文件始终不被覆盖。
    func importImage(_ image: CGImage) async throws -> MacBackgroundFile {
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("background-edit-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LibraryError.invalidMedia
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw LibraryError.invalidMedia }
        try Task.checkCancellation()
        return try await importFile(url)
    }
}

enum MacBackgroundImageEditing {
    static func pixelSize(_ source: CGImageSource) throws -> CGSize {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { throw MacBackgroundLibrary.LibraryError.invalidMedia }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height.doubleValue, height: width.doubleValue)
            : CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    static func decode(_ source: CGImageSource, maximumDimension: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw MacBackgroundLibrary.LibraryError.invalidMedia
        }
        return image
    }
}

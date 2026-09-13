import Foundation
import ImageIO
import UIKit

/// 显示尺寸只决定派生位图的像素数，不限制原始附件的大小或数量。
public struct DisplayImageTarget: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let fillsBounds: Bool

    public init(size: CGSize, scale: CGFloat, fillsBounds: Bool = true) {
        width = max(0, Int((size.width * scale).rounded(.up)))
        height = max(0, Int((size.height * scale).rounded(.up)))
        self.fillsBounds = fillsBounds
    }

    public var isEmpty: Bool { width == 0 || height == 0 }
}

public struct PreparedDisplayImage: @unchecked Sendable {
    public let image: UIImage
    public let sourceRevision: String
    /// 模糊半径原本以源图像素为单位，缩图后按同一比例换算，保持视觉强度。
    public let sourcePixelScale: CGFloat
}

/// 双端共用后台解码和进行中的请求；缓存可由系统回收，不按附件张数拒绝加载。
public actor DisplayImageLoader {
    public static let shared = DisplayImageLoader()

    private struct Request: Hashable {
        let url: URL
        let target: DisplayImageTarget
        let revision: String
    }

    private final class Entry {
        let value: PreparedDisplayImage
        init(_ value: PreparedDisplayImage) { self.value = value }
    }

    private let cache = NSCache<NSString, Entry>()
    private var pending: [Request: Task<PreparedDisplayImage?, Never>] = [:]

    public init() {}

    public func attachment(named fileName: String, target: DisplayImageTarget) async -> PreparedDisplayImage? {
        await image(at: Persistence.getImageDirectory().appendingPathComponent(fileName), target: target)
    }

    public func background(named fileName: String, target: DisplayImageTarget) async -> PreparedDisplayImage? {
        await image(at: ConfigLoader.getBackgroundsDirectory().appendingPathComponent(fileName), target: target)
    }

    public func image(at url: URL, target: DisplayImageTarget) async -> PreparedDisplayImage? {
        guard !target.isEmpty else { return nil }
        var metadataURL = url
        metadataURL.removeAllCachedResourceValues()
        let metadata = try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let revision = "\(metadata?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(metadata?.fileSize ?? 0)"
        let request = Request(url: url, target: target, revision: revision)
        let key = "\(url.absoluteString)|\(target.width)x\(target.height)|\(target.fillsBounds)|\(revision)" as NSString
        if let entry = cache.object(forKey: key) { return entry.value }
        if let task = pending[request] { return await task.value }

        let task = Task.detached(priority: .userInitiated) {
            Self.decode(at: url, target: target, sourceRevision: revision)
        }
        pending[request] = task
        let result = await task.value
        pending[request] = nil
        if let result {
            cache.setObject(Entry(result), forKey: key)
        }
        return result
    }

    /// 高清原图只由正在预览的页面持有，避免滚动过的附件都在缓存中留下原图。
    public nonisolated func original(at url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            Self.decodeOriginal(at: url)
        }.value
    }

    public nonisolated func originalAttachment(named fileName: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let url = Persistence.getImageDirectory().appendingPathComponent(fileName)
            return Self.decodeOriginal(at: url)
        }.value
    }

    nonisolated private static func decodeOriginal(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationValue = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let orientation: UIImage.Orientation
        switch orientationValue {
        case 2: orientation = .upMirrored
        case 3: orientation = .down
        case 4: orientation = .downMirrored
        case 5: orientation = .leftMirrored
        case 6: orientation = .right
        case 7: orientation = .rightMirrored
        case 8: orientation = .left
        default: orientation = .up
        }
        return UIImage(cgImage: image, scale: 1, orientation: orientation)
    }

    nonisolated private static func decode(at url: URL, target: DisplayImageTarget, sourceRevision: String) -> PreparedDisplayImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let sourceWidth = swapsAxes ? height.doubleValue : width.doubleValue
        let sourceHeight = swapsAxes ? width.doubleValue : height.doubleValue
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // 气泡采用 aspect-fill，长图也必须让短边足够清晰；小图不放大解码。
        let widthRatio = Double(target.width) / sourceWidth
        let heightRatio = Double(target.height) / sourceHeight
        let ratio = min(1, target.fillsBounds ? max(widthRatio, heightRatio) : min(widthRatio, heightRatio))
        let maximumDimension = max(1, Int((max(sourceWidth, sourceHeight) * ratio).rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PreparedDisplayImage(
            image: UIImage(cgImage: image),
            sourceRevision: sourceRevision,
            sourcePixelScale: CGFloat(image.width) / sourceWidth
        )
    }
}

// 内联网页的导出只读取当前视图；不重新执行工具或修改聊天记录。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum InlineHTMLExportError: LocalizedError {
    case notReady
    case imageTooLarge
    case imageFailed

    public var errorDescription: String? {
        switch self {
        case .notReady:
            return NSLocalizedString("网页尚未就绪，请打开网页并等待加载完成。", comment: "")
        case .imageTooLarge:
            return NSLocalizedString("网页图片过大，请改为下载 HTML。", comment: "")
        case .imageFailed:
            return NSLocalizedString("无法生成网页图片，请重试。", comment: "")
        }
    }
}

public enum InlineHTMLExportSupport {
    /// 网页尺寸来自不受信任的内容，必须在 WebKit 分配位图之前限制像素预算。
    public static func validateSnapshotSize(_ size: CGSize, scale: CGFloat) throws {
        #if os(watchOS)
        let pixelBudget: CGFloat = 8_000_000
        #else
        let pixelBudget: CGFloat = 32_000_000
        #endif
        guard size.width.isFinite, size.height.isFinite, scale.isFinite,
              size.width > 0, size.height > 0, scale > 0 else {
            throw InlineHTMLExportError.notReady
        }
        guard size.width * scale <= 32_768, size.height * scale <= 32_768,
              size.width * size.height * scale * scale <= pixelBudget else {
            throw InlineHTMLExportError.imageTooLarge
        }
    }

    public static func pngData(image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw InlineHTMLExportError.imageFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw InlineHTMLExportError.imageFailed }
        return data as Data
    }

    public static func write(data: Data, fileExtension: String) throws -> URL {
        // 复用快照临时目录，下一次启动清理；系统分享扩展读取期间不能提前删掉文件。
        let directory = try SyncTemporaryFileCleaner.makeDirectoryURL(prefix: "InlineHTML")
        let url = directory.appendingPathComponent("Inline.\(fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// 代码保留生成方的原文；HTML 保留承载样式。闭包由平台视图提供，并弱引用正在显示的网页。
@MainActor
public final class InlineHTMLContent: Identifiable, Hashable {
    public nonisolated let id = UUID()
    public nonisolated static func == (lhs: InlineHTMLContent, rhs: InlineHTMLContent) -> Bool { lhs.id == rhs.id }
    public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public var messageID: UUID?
    public var versionIndex = 0
    public var title = ""
    public var code = ""
    public var html = ""
    public var capturePNG: (() async throws -> Data)?
    public var readText: (() async throws -> String)?

    public init() {}
}

@MainActor
public final class InlineHTMLContentRegistry {
    public static let shared = InlineHTMLContentRegistry()
    private var contents: [UUID: (order: Int, content: InlineHTMLContent)] = [:]
    private var nextOrder = 0

    public func register(_ content: InlineHTMLContent) {
        guard contents[content.id] == nil else { return }
        contents[content.id] = (nextOrder, content)
        nextOrder += 1
    }

    public func remove(_ content: InlineHTMLContent) {
        contents.removeValue(forKey: content.id)
        content.capturePNG = nil
        content.readText = nil
    }

    public func contents(messageID: UUID, versionIndex: Int) -> [InlineHTMLContent] {
        contents.values
            .filter { $0.content.messageID == messageID && $0.content.versionIndex == versionIndex }
            .sorted { $0.order < $1.order }
            .map(\.content)
    }
}

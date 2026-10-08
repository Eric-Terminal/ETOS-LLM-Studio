import AVFoundation
import ETOSCore
import Foundation
import ImageIO

struct MacBackgroundFile: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let isVideo: Bool
    let size: Int
    let modifiedAt: Date?
    let resourceID: String
}

struct MacBackgroundCatalog: Sendable {
    let files: [MacBackgroundFile]
    let byID: [String: MacBackgroundFile]
    let identifiers: [String]
    let guideValue: JSONValue
    private let rotationFirst: String?
    private let rotationSecond: String?

    init(_ files: [MacBackgroundFile]) {
        self.files = files
        byID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        identifiers = files.map(\.id)
        guideValue = .array(identifiers.map(JSONValue.string))
        let shuffled = identifiers.shuffled()
        rotationFirst = shuffled.first
        rotationSecond = shuffled.dropFirst().first
    }

    /// 两个随机候选在后台准备，主线程选择时不用扫描目录。
    func nextRotatedID(excluding current: String) -> String? { rotationFirst == current ? rotationSecond : rotationFirst }
}

/// 文件操作在 actor 上串行执行。目录仅存相对文件名，和移动端的备份/同步格式一致。
actor MacBackgroundLibrary {
    static let shared = MacBackgroundLibrary()
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    private var root: URL { directory ?? ConfigLoader.getBackgroundsDirectory() }

    func load() throws -> MacBackgroundCatalog {
        try Task.checkCancellation()
        let root = root
        guard FileManager.default.fileExists(atPath: root.path) else { return MacBackgroundCatalog([]) }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])
        return MacBackgroundCatalog(try files.compactMap { url in
            try Task.checkCancellation()
            guard ConfigLoader.isSupportedBackgroundMediaFile(url.lastPathComponent) else { return nil }
            return try Self.describe(url)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending })
    }

    func importFile(_ source: URL) async throws -> MacBackgroundFile {
        try Task.checkCancellation()
        guard source.isFileURL, ConfigLoader.isSupportedBackgroundMediaFile(source.lastPathComponent) else {
            throw LibraryError.invalidMedia
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard try Self.describe(source) != nil else { throw LibraryError.invalidMedia }
        let root = root, manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let suffix = source.pathExtension.lowercased()
        // 自动云同步会读取 Backgrounds 的全部文件，校验中的副本必须放在目录外。
        // 系统替换目录和目标同卷，发布时仍可一次移动，不暴露半份媒体。
        let stagingDirectory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: root, create: true)
        defer { try? manager.removeItem(at: stagingDirectory) }
        let staged = stagingDirectory.appendingPathComponent("background.\(suffix)")
        try Task.checkCancellation()
        try manager.copyItem(at: source, to: staged)
        if ConfigLoader.isVideoBackgroundFile(source.lastPathComponent) {
            let asset = AVURLAsset(url: staged)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard playable, !tracks.isEmpty else { throw LibraryError.invalidMedia }
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 1]
            guard let image = CGImageSourceCreateWithURL(staged as CFURL, nil), CGImageSourceGetCount(image) > 0,
                  CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) != nil else { throw LibraryError.invalidMedia }
        }
        try Task.checkCancellation()
        let destination = root.appendingPathComponent("background-\(UUID().uuidString).\(suffix)")
        try manager.moveItem(at: staged, to: destination)
        var published = false
        defer { if !published { try? manager.removeItem(at: destination) } }
        // 发布前不再检查取消；已完成的原子移动必须返回，让宿主通知目录更新并等待收尾。
        guard let file = try Self.describe(destination) else { throw LibraryError.invalidMedia }
        published = true
        return file
    }

    func delete(_ expected: MacBackgroundFile) throws {
        try Task.checkCancellation()
        try validate(expected)
        try FileManager.default.removeItem(at: expected.url)
    }

    func validate(_ expected: MacBackgroundFile) throws {
        guard expected.id == URL(fileURLWithPath: expected.id).lastPathComponent,
              expected.url.standardizedFileURL == root.appendingPathComponent(expected.id).standardizedFileURL,
              try Self.describe(expected.url) == expected else { throw LibraryError.changed }
    }

    private static func describe(_ url: URL) throws -> MacBackgroundFile? {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular else { return nil }
        let device = (values[.systemNumber] as? NSNumber)?.stringValue ?? ""
        let inode = (values[.systemFileNumber] as? NSNumber)?.stringValue ?? ""
        let created = (values[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return MacBackgroundFile(id: url.lastPathComponent, url: url, isVideo: ConfigLoader.isVideoBackgroundFile(url.lastPathComponent),
                                 size: (values[.size] as? NSNumber)?.intValue ?? 0, modifiedAt: values[.modificationDate] as? Date,
                                 resourceID: "\(device):\(inode)|\(created)")
    }

    enum LibraryError: LocalizedError {
        case invalidMedia, changed
        var errorDescription: String? {
            switch self {
            case .invalidMedia: return NSLocalizedString("无法读取背景媒体，请选择有效的图片或视频。", comment: "")
            case .changed: return NSLocalizedString("背景文件已变化，请刷新列表后重试。", comment: "")
            }
        }
    }
}

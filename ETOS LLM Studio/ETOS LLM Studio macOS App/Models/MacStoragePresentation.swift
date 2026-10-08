import ETOSCore
import Foundation
import ImageIO

struct MacStorageLocation: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let url: URL
    var onlyOther = false
    var category: StorageCategory?
    var isRoot = false
    var displayTitle: String {
        category?.displayName ?? (onlyOther ? NSLocalizedString("其他文件", comment: "") : isRoot ? NSLocalizedString("根目录", comment: "") : title)
    }
}

struct MacStorageOverview: Sendable {
    struct Category: Identifiable, Sendable {
        let id: String, title: String, size: String, symbol: String
        let location: MacStorageLocation
    }
    let root: MacStorageLocation
    let other: MacStorageLocation
    let categories: [Category]
    let total: String, cache: String, orphanDescription: String
    let totalBytes: Int64, cacheBytes: Int64, otherBytes: Int64
    let orphanCount: Int
    let guideCategories: JSONValue

    init(breakdown: StorageBreakdown, orphans: StorageUtility.OrphanedDataCount, root: URL) {
        self.root = MacStorageLocation(title: NSLocalizedString("根目录", comment: ""), url: root, isRoot: true)
        other = MacStorageLocation(title: NSLocalizedString("其他文件", comment: ""), url: root, onlyOther: true)
        totalBytes = breakdown.totalSize; cacheBytes = breakdown.cacheSize; otherBytes = breakdown.otherSize
        total = StorageUtility.formatSize(totalBytes); cache = StorageUtility.formatSize(cacheBytes)
        orphanDescription = orphans.description; orphanCount = orphans.total
        categories = StorageCategory.allCases.map { category in
            Category(id: category.rawValue, title: category.displayName,
                size: StorageUtility.formatSize(breakdown.categorySize[category] ?? 0), symbol: category.systemImage,
                location: MacStorageLocation(title: category.displayName, url: root.appendingPathComponent(category.rawValue), category: category))
        }
        guideCategories = .array(StorageCategory.allCases.map { category in
            .dictionary(["id": .string(category.rawValue), "bytes": .int(Int(clamping: breakdown.categorySize[category] ?? 0))])
        })
    }
    static func load() throws -> Self {
        let breakdown = StorageUtility.getStorageBreakdown()
        try Task.checkCancellation()
        return Self(breakdown: breakdown, orphans: StorageUtility.countAllOrphanedData(), root: StorageUtility.documentsDirectory)
    }
}

struct MacStorageFile: Identifiable, Sendable {
    let item: FileItem
    let size: String, modified: String, symbol: String
    let deletionAllowed: Bool
    let isImage: Bool, isSQLite: Bool
    let inode: UInt64?
    var id: String { item.id }

    init(url: URL, attributes: [FileAttributeKey: Any], access: StorageFileAccess) {
        item = FileItem(url: url, attributes: attributes)
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        size = StorageUtility.formatSize(item.size)
        modified = DateFormatter.localizedString(from: item.modificationDate, dateStyle: .medium, timeStyle: .short)
        deletionAllowed = (try? access.validateDeletion(url)) != nil
        isImage = StorageBrowserSupport.isImageFile(url); isSQLite = StorageBrowserSupport.isSQLiteDatabaseFile(url)
        symbol = item.isDirectory ? "folder" : isImage ? "photo" : isSQLite ? "externaldrive" : "doc"
    }
}

struct MacStorageDirectory: Sendable {
    let rows: [MacStorageFile]
    let byID: [String: MacStorageFile]
    let relativePath: String
    let folderCount: Int, fileCount: Int
    let size: String

    static func load(_ location: MacStorageLocation, access: StorageFileAccess) throws -> Self {
        let directory = try access.readableURL(location.url)
        let manager = FileManager.default
        let urls: [URL]
        // 尚未使用的分类目录可以不存在；实际的权限和读取错误需要显示。
        if manager.fileExists(atPath: directory.path) {
            urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } else { urls = [] }
        let known = Set(StorageCategory.allCases.map(\.rawValue))
        var rows: [MacStorageFile] = []
        for url in urls {
            try Task.checkCancellation()
            let row = MacStorageFile(url: url, attributes: try manager.attributesOfItem(atPath: url.path), access: access)
            if location.onlyOther && row.item.isDirectory && known.contains(row.item.name) { continue }
            rows.append(row)
        }
        rows.sort { $0.item.modificationDate > $1.item.modificationDate }
        let folders = rows.filter { $0.item.isDirectory }.count
        return Self(rows: rows, byID: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) }),
            relativePath: StorageBrowserSupport.relativeDisplayPath(for: directory, rootDirectory: access.root),
            folderCount: folders, fileCount: rows.count - folders,
            size: StorageUtility.formatSize(rows.reduce(0) { $0 + ($1.item.isDirectory ? 0 : $1.item.size) }))
    }
}

struct MacStorageFilePreview: Sendable {
    let image: CGImage?
    let pages: [StorageTextPage]
    let error: String?
    let lineCount: Int

    static func load(_ file: MacStorageFile) throws -> Self {
        let url = try StorageFileAccess.application().readableURL(file.item.url)
        if file.isImage {
            // 提前解码并处理 EXIF 方向，不让绘制阶段读取磁盘或解压原图。
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return Self(image: nil, pages: [], error: NSLocalizedString("无法预览", comment: ""), lineCount: 0)
            }
            return Self(image: decoded, pages: [], error: nil, lineCount: 0)
        }
        let payload = FileAttachmentPreviewLoader.load(fileURL: url)
        try Task.checkCancellation()
        return Self(image: nil, pages: payload.fullText.map { StorageBrowserSupport.paginateText($0) } ?? [],
            error: payload.errorMessage, lineCount: payload.lineCount)
    }
}

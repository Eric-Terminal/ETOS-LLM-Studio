import ETOSCore
import Foundation

enum MacStorageMutation: Sendable {
    case cache, orphans, files([MacStorageFile])

    var kind: String {
        switch self { case .cache: "cache"; case .orphans: "orphans"; case .files: "files" }
    }
    var title: String {
        switch self {
        case .cache: NSLocalizedString("清理所有缓存", comment: "")
        case .orphans: NSLocalizedString("清理孤立数据", comment: "")
        case .files: NSLocalizedString("删除", comment: "")
        }
    }
    var count: Int { if case .files(let files) = self { return files.count }; return 0 }

    func apply(access: StorageFileAccess = .application()) throws -> String {
        switch self {
        case .cache:
            let result = StorageUtility.clearCacheFiles()
            return String(format: NSLocalizedString("已删除 %d 个语音文件和 %d 个图片文件。", comment: ""), result.audioDeleted, result.imageDeleted)
        case .orphans:
            return String(format: NSLocalizedString("已清理：%@", comment: ""), StorageUtility.cleanupAllOrphans().description)
        case .files(let files):
            let manager = FileManager.default
            // 在删除任何文件之前检查整组原件；数据库维护等待期间的变化不能被旧确认覆盖。
            for file in files {
                try access.validateDeletion(file.item.url)
                let attributes = try manager.attributesOfItem(atPath: file.item.url.path)
                let current = FileItem(url: file.item.url, attributes: attributes)
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
                guard current.size == file.item.size, current.modificationDate == file.item.modificationDate,
                      current.isDirectory == file.item.isDirectory, inode == file.inode else { throw StorageFileAccessError.changed }
            }
            let result = StorageUtility.deleteFiles(files.map { $0.item.url })
            return String(format: NSLocalizedString("成功删除 %d 个文件，%d 个失败。", comment: ""), result.success, result.failed)
        }
    }
}

struct MacStorageConfirmation: Identifiable {
    let id = UUID()
    let mutation: MacStorageMutation
    let detail: String

    static func files(_ files: [MacStorageFile]) -> Self {
        Self(mutation: .files(files), detail: files.map { $0.item.name }.joined(separator: "\n"))
    }
}

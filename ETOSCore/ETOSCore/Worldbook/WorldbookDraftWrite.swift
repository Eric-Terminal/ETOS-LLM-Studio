import Foundation

public enum WorldbookDraftWriteError: LocalizedError {
    case emptyName
    case changedExternally
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .emptyName: return NSLocalizedString("名称不能为空。", comment: "世界书草稿错误")
        case .changedExternally: return NSLocalizedString("世界书已被修改或删除，请重新打开后再试。", comment: "世界书草稿错误")
        case .writeFailed: return NSLocalizedString("无法写入世界书，请稍后重试。", comment: "世界书草稿错误")
        }
    }
}

extension WorldbookStore {
    public func reorderDraft(_ orderedIDs: [UUID], replacing originals: [Worldbook]) throws {
        try queue.sync {
            let current = loadWorldbooksUnlocked()
            guard current == originals, orderedIDs.count == current.count,
                  Set(orderedIDs) == Set(current.map(\.id)) else { throw WorldbookDraftWriteError.changedExternally }
            let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            let now = Date()
            let reordered = orderedIDs.enumerated().compactMap { index, id -> Worldbook? in
                guard var book = byID[id] else { return nil }
                // 沿用现有数据库以更新时间保存列表顺序的约定，一次写完避免中途重排。
                book.updatedAt = now.addingTimeInterval(-Double(index))
                return book
            }
            guard saveWorldbooksUnlocked(reordered) else { throw WorldbookDraftWriteError.writeFailed }
        }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }

    /// 版本检查与写入使用同一队列，防止详情页或另一编辑器覆盖保存期间的新内容。
    public func saveDraft(_ draft: Worldbook, replacing original: Worldbook?) throws {
        try queue.sync {
            var all = loadWorldbooksUnlocked()
            guard original?.id == nil || original?.id == draft.id,
                  all.first(where: { $0.id == draft.id }) == original else {
                throw WorldbookDraftWriteError.changedExternally
            }
            var saved = draft
            saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !saved.name.isEmpty else { throw WorldbookDraftWriteError.emptyName }
            saved.updatedAt = Date()
            saved.settings = WorldbookSettings(
                scanDepth: draft.settings.scanDepth, maxRecursionDepth: draft.settings.maxRecursionDepth,
                maxInjectedEntries: draft.settings.maxInjectedEntries, maxInjectedCharacters: draft.settings.maxInjectedCharacters,
                fallbackPosition: draft.settings.fallbackPosition
            )
            if let index = all.firstIndex(where: { $0.id == saved.id }) { all[index] = saved }
            else { all.append(saved) }
            guard saveWorldbooksUnlocked(all) else { throw WorldbookDraftWriteError.writeFailed }
        }
        WatchDatabaseSyncService.markDatabaseChanged(.config)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }
}

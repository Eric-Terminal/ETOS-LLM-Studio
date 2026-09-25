// ============================================================================
// FileProviderEnumerator.swift
// ETOS Workspace Provider
// ============================================================================

import ETOSCore
import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let identifier: NSFileProviderItemIdentifier
    private let domainIdentifier: NSFileProviderDomainIdentifier

    init(identifier: NSFileProviderItemIdentifier, domainIdentifier: NSFileProviderDomainIdentifier) {
        self.identifier = identifier
        self.domainIdentifier = domainIdentifier
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        FileProviderStorage.queue.async { [self] in
            do {
                let storage = try FileProviderStorage()
                observer.didEnumerate(try storage.items(in: identifier))
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        FileProviderStorage.queue.async { [self] in
            do {
                let storage = try FileProviderStorage()
                let anchors = anchorStore(storage: storage)
                let previous = try anchors.load(anchor.rawValue)
                let items = try storage.items(in: identifier)
                let current = snapshot(items)
                // 先持久化本轮快照，失败时不向系统发布半套增量。
                let newAnchor = try anchors.save(current)
                let deleted = current.deletedIdentifiers(since: previous).map { NSFileProviderItemIdentifier($0) }
                let updated = current.updatedIdentifiers(since: previous)
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                let changedItems = items.filter { updated.contains($0.itemIdentifier.rawValue) }
                if !changedItems.isEmpty { observer.didUpdate(changedItems) }
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(newAnchor), moreComing: false)
                // 系统只保证工作集有单个消费者；普通目录可能同时被多个 App 枚举。
                if identifier == .workingSet {
                    try? anchors.prune(keeping: [anchor.rawValue, newAnchor])
                }
            } catch ETOSWorkspaceSyncAnchorStore.AnchorError.expired {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        FileProviderStorage.queue.async { [self] in
            do {
                let storage = try FileProviderStorage()
                let current = snapshot(try storage.items(in: identifier))
                completionHandler(NSFileProviderSyncAnchor(try anchorStore(storage: storage).save(current)))
            } catch {
                // 目录读取失败不能伪装成空快照，否则会漏报删除或覆盖系统的同步基线。
                NSLog("无法创建 ETOS 工作区同步锚点：%@", error.localizedDescription)
                completionHandler(nil)
            }
        }
    }

    private func anchorStore(storage: FileProviderStorage) -> ETOSWorkspaceSyncAnchorStore {
        ETOSWorkspaceSyncAnchorStore(
            receipts: storage.layout.receipts,
            // iOS 的默认域与显式工作区域可能共用扩展进程，不能互相回收同步锚点。
            containerIdentifier: domainIdentifier.rawValue + "/" + identifier.rawValue,
            fileManager: storage.fileManager
        )
    }

    private func snapshot(_ items: [FileProviderItem]) -> ETOSWorkspaceSyncSnapshot {
        ETOSWorkspaceSyncSnapshot(versions: Dictionary(uniqueKeysWithValues: items.map { item in
            let version = item.itemVersion
            // 长度前缀确保任意二进制版本的组合也不会产生歧义。
            let prefix = Data("\(version.contentVersion.count):".utf8)
            return (item.itemIdentifier.rawValue, prefix + version.contentVersion + version.metadataVersion)
        }))
    }
}

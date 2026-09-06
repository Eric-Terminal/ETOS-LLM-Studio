// ============================================================================
// FileProviderEnumerator.swift
// ETOS Workspace Provider
// ============================================================================

import ETOSCore
import FileProvider
import Foundation

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let identifier: NSFileProviderItemIdentifier
    private let storage: FileProviderStorage

    init(identifier: NSFileProviderItemIdentifier, storage: FileProviderStorage) {
        self.identifier = identifier
        self.storage = storage
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        do {
            observer.didEnumerate(try storage.children(of: normalizedContainerIdentifier))
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        do {
            let current = try storage.children(of: normalizedContainerIdentifier)
            let previous = try loadManifest(anchor: anchor)
            let currentIDs = Set(current.map { $0.itemIdentifier.rawValue })
            let deleted = previous.subtracting(currentIDs).map { NSFileProviderItemIdentifier($0) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            if !current.isEmpty { observer.didUpdate(current) }
            let newAnchor = try saveManifest(currentIDs)
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let identifiers = (try? storage.children(of: normalizedContainerIdentifier))?.map {
            $0.itemIdentifier.rawValue
        } ?? []
        completionHandler(try? saveManifest(Set(identifiers)))
    }

    private var normalizedContainerIdentifier: NSFileProviderItemIdentifier {
        if identifier == .workingSet { return .rootContainer }
        return identifier
    }

    private func saveManifest(_ identifiers: Set<String>) throws -> NSFileProviderSyncAnchor {
        let token = UUID().uuidString
        let directory = storage.layout.receipts.appendingPathComponent("FileProviderAnchors", isDirectory: true)
        let url = directory.appendingPathComponent("\(token).json")
        try ETOSSharedFileStore.write(Array(identifiers).sorted(), to: url, fileManager: storage.fileManager)
        return NSFileProviderSyncAnchor(Data(token.utf8))
    }

    private func loadManifest(anchor: NSFileProviderSyncAnchor) throws -> Set<String> {
        guard let token = String(data: anchor.rawValue, encoding: .utf8),
              UUID(uuidString: token) != nil else { return [] }
        let url = storage.layout.receipts
            .appendingPathComponent("FileProviderAnchors", isDirectory: true)
            .appendingPathComponent("\(token).json")
        guard storage.fileManager.fileExists(atPath: url.path) else { return [] }
        return Set(try ETOSSharedFileStore.read([String].self, from: url, maximumBytes: 2 * 1_024 * 1_024))
    }
}

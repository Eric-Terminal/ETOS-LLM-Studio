// ============================================================================
// FileProviderItem.swift
// ETOS Workspace Provider
// ============================================================================

import ETOSCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .creationDateKey, .fileSizeKey,
        .contentTypeKey
    ]

    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let itemVersion: NSFileProviderItemVersion
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let childItemCount: NSNumber?

    init(rootStorage _: FileProviderStorage) {
        itemIdentifier = .rootContainer
        parentItemIdentifier = .rootContainer
        filename = NSLocalizedString("ETOS 工作区", comment: "File Provider root folder name")
        contentType = .folder
        documentSize = nil
        creationDate = nil
        contentModificationDate = nil
        childItemCount = 2
        let version = Data("root-v1".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
        super.init()
    }

    init(url: URL, storage: FileProviderStorage) throws {
        let values = try url.resourceValues(forKeys: Self.resourceKeys)
        guard values.isSymbolicLink != true,
              values.isDirectory == true || values.isRegularFile == true else {
            throw NSFileProviderError(.noSuchItem)
        }
        itemIdentifier = try storage.identifier(for: url)
        let parentURL = url.deletingLastPathComponent()
        parentItemIdentifier = parentURL.standardizedFileURL == storage.layout.container.standardizedFileURL
            ? .rootContainer
            : try storage.identifier(for: parentURL)
        filename = url.lastPathComponent
        contentType = values.isDirectory == true ? .folder : (values.contentType ?? .data)
        documentSize = values.fileSize.map(NSNumber.init(value:))
        creationDate = values.creationDate
        contentModificationDate = values.contentModificationDate
        childItemCount = values.isDirectory == true
            ? (try? storage.fileManager.contentsOfDirectory(atPath: url.path).count).map(NSNumber.init(value:))
            : nil
        let stamp = "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
        let version = Data(stamp.utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
        super.init()
    }

    var capabilities: NSFileProviderItemCapabilities {
        if itemIdentifier == .rootContainer {
            return [.allowsReading, .allowsContentEnumerating]
        }
        if contentType == .folder {
            var capabilities: NSFileProviderItemCapabilities = [
                .allowsReading,
                .allowsContentEnumerating,
                .allowsAddingSubItems
            ]
            if parentItemIdentifier != .rootContainer {
                capabilities.formUnion([.allowsRenaming, .allowsReparenting, .allowsTrashing, .allowsDeleting])
            }
            return capabilities
        }
        return [
            .allowsReading,
            .allowsWriting,
            .allowsRenaming,
            .allowsReparenting,
            .allowsTrashing,
            .allowsDeleting
        ]
    }
}

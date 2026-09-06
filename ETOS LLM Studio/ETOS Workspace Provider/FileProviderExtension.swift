// ============================================================================
// FileProviderExtension.swift
// ETOS Workspace Provider
// ============================================================================

import ETOSCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let storage: FileProviderStorage

    required init(domain: NSFileProviderDomain) {
        do {
            storage = try FileProviderStorage()
        } catch {
            fatalError("无法准备 ETOS 工作区：\(error.localizedDescription)")
        }
        super.init()
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            if identifier == .rootContainer {
                completionHandler(FileProviderItem(rootStorage: storage), nil)
                return Progress(totalUnitCount: 0)
            }
            completionHandler(try FileProviderItem(url: storage.url(for: identifier), storage: storage), nil)
        } catch {
            completionHandler(nil, error)
        }
        return Progress(totalUnitCount: 0)
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        do {
            let url = try storage.url(for: itemIdentifier)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw NSFileProviderError(.noSuchItem) }
            completionHandler(url, try FileProviderItem(url: url, storage: storage), nil)
        } catch {
            completionHandler(nil, nil, error)
        }
        return Progress(totalUnitCount: 0)
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents source: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        do {
            let parent = itemTemplate.parentItemIdentifier == .rootContainer
                ? storage.layout.container
                : try storage.url(for: itemTemplate.parentItemIdentifier)
            let name = try storage.validatedName(itemTemplate.filename)
            let destination = parent.appendingPathComponent(name)
            _ = try storage.url(
                forRelativePath: try destinationRelativePath(destination),
                allowMissingLeaf: true
            )
            guard !storage.fileManager.fileExists(atPath: destination.path) else {
                throw NSFileProviderError(.filenameCollision)
            }
            if itemTemplate.contentType == .folder {
                try storage.fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
            } else if let source {
                let staged = storage.layout.staging.appendingPathComponent(UUID().uuidString)
                try storage.fileManager.copyItem(at: source, to: staged)
                try storage.fileManager.moveItem(at: staged, to: destination)
            } else {
                try Data().write(to: destination, options: [.atomic, .completeFileProtection])
            }
            completionHandler(try FileProviderItem(url: destination, storage: storage), [], false, nil)
        } catch {
            completionHandler(nil, fields, false, error)
        }
        return Progress(totalUnitCount: 0)
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        do {
            let current = try storage.url(for: item.itemIdentifier)
            guard current.standardizedFileURL != storage.layout.shared.standardizedFileURL,
                  current.standardizedFileURL != storage.layout.exports.standardizedFileURL else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let targetParent = item.parentItemIdentifier == .rootContainer
                ? storage.layout.container
                : try storage.url(for: item.parentItemIdentifier)
            let target = targetParent.appendingPathComponent(try storage.validatedName(item.filename))
            _ = try storage.url(forRelativePath: try destinationRelativePath(target), allowMissingLeaf: true)
            var published = current
            if current.standardizedFileURL != target.standardizedFileURL {
                guard !storage.fileManager.fileExists(atPath: target.path) else {
                    throw NSFileProviderError(.filenameCollision)
                }
                try storage.fileManager.moveItem(at: current, to: target)
                published = target
            }
            if let newContents {
                let values = try published.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw NSFileProviderError(.noSuchItem) }
                let staged = storage.layout.staging.appendingPathComponent(UUID().uuidString)
                try storage.fileManager.copyItem(at: newContents, to: staged)
                _ = try storage.fileManager.replaceItemAt(published, withItemAt: staged)
            }
            completionHandler(try FileProviderItem(url: published, storage: storage), [], false, nil)
        } catch {
            completionHandler(nil, changedFields, false, error)
        }
        return Progress(totalUnitCount: 0)
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        do {
            let target = try storage.url(for: identifier)
            guard target.standardizedFileURL != storage.layout.shared.standardizedFileURL,
                  target.standardizedFileURL != storage.layout.exports.standardizedFileURL else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try storage.fileManager.removeItem(at: target)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
        return Progress(totalUnitCount: 0)
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(identifier: containerItemIdentifier, storage: storage)
    }

    private func destinationRelativePath(_ url: URL) throws -> String {
        let root = storage.layout.container.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { throw NSFileProviderError(.noSuchItem) }
        return String(path.dropFirst(root.count))
    }
}

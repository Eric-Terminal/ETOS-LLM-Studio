// ============================================================================
// FileProviderExtension.swift
// ETOS Workspace Provider
// ============================================================================

import ETOSCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        FileProviderStorage.perform { progress in
            do {
                guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
                let storage = try FileProviderStorage()
                if identifier == .rootContainer {
                    completionHandler(FileProviderItem(rootStorage: storage), nil)
                    return
                }
                completionHandler(try FileProviderItem(url: storage.url(for: identifier), storage: storage), nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        FileProviderStorage.perform { [domain] progress in
            do {
                guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
                let storage = try FileProviderStorage()
                let url = try storage.url(for: itemIdentifier)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { throw NSFileProviderError(.noSuchItem) }
                let item = try FileProviderItem(url: url, storage: storage)
                if let requestedVersion, requestedVersion.contentVersion != item.itemVersion.contentVersion {
                    throw CocoaError(.fileReadUnknown)
                }
                guard let manager = NSFileProviderManager(for: domain) else {
                    throw NSFileProviderError(.providerNotFound)
                }
                let copy = try storage.files.copyContents(
                    at: url, toTemporaryDirectory: manager.temporaryDirectoryURL()
                )
                do {
                    guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
                    // Linux 可以同时写入源文件；不能把复制期间变化的内容标成旧版本交付。
                    var latestURL = url
                    latestURL.removeAllCachedResourceValues()
                    let latest = try FileProviderItem(url: latestURL, storage: storage)
                    guard latest.itemVersion.contentVersion == item.itemVersion.contentVersion else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    completionHandler(copy, item, nil)
                } catch {
                    try? storage.fileManager.removeItem(at: copy)
                    throw error
                }
            } catch {
                completionHandler(nil, nil, error)
            }
        }
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents source: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        FileProviderStorage.perform { [domain] progress in
            do {
                guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
                let storage = try FileProviderStorage()
                let parent = itemTemplate.parentItemIdentifier == .rootContainer
                    ? storage.layout.container
                    : try storage.url(for: itemTemplate.parentItemIdentifier)
                let name = try storage.validatedName(itemTemplate.filename)
                let destination = parent.appendingPathComponent(name)
                _ = try storage.url(
                    forRelativePath: try Self.destinationRelativePath(destination, storage: storage),
                    allowMissingLeaf: true
                )
                guard !storage.fileManager.fileExists(atPath: destination.path) else {
                    throw NSFileProviderError(.filenameCollision)
                }
                if itemTemplate.contentType == .folder {
                    try storage.fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
                } else if let source {
                    let staged = storage.layout.staging.appendingPathComponent(UUID().uuidString)
                    defer { try? storage.fileManager.removeItem(at: staged) }
                    try storage.fileManager.copyItem(at: source, to: staged)
                    try storage.fileManager.moveItem(at: staged, to: destination)
                } else {
                    try Data().write(to: destination, options: [.atomic, .completeFileProtection])
                }
                completionHandler(try FileProviderItem(url: destination, storage: storage), [], false, nil)
                Self.signalWorkingSet(in: domain)
            } catch {
                completionHandler(nil, fields, false, error)
            }
        }
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
        FileProviderStorage.perform { [domain] progress in
            do {
                guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
                let storage = try FileProviderStorage()
                let current = try storage.url(for: item.itemIdentifier)
                guard current.standardizedFileURL != storage.layout.shared.standardizedFileURL,
                      current.standardizedFileURL != storage.layout.exports.standardizedFileURL else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let targetParent = item.parentItemIdentifier == .rootContainer
                    ? storage.layout.container
                    : try storage.url(for: item.parentItemIdentifier)
                let target = targetParent.appendingPathComponent(try storage.validatedName(item.filename))
                _ = try storage.url(
                    forRelativePath: try Self.destinationRelativePath(target, storage: storage), allowMissingLeaf: true
                )
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
                    defer { try? storage.fileManager.removeItem(at: staged) }
                    try storage.fileManager.copyItem(at: newContents, to: staged)
                    _ = try storage.fileManager.replaceItemAt(published, withItemAt: staged)
                }
                completionHandler(try FileProviderItem(url: published, storage: storage), [], false, nil)
                Self.signalWorkingSet(in: domain)
            } catch {
                completionHandler(nil, changedFields, false, error)
            }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        FileProviderStorage.perform { [domain] progress in
            do {
                guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
                let storage = try FileProviderStorage()
                let target = try storage.url(for: identifier)
                guard target.standardizedFileURL != storage.layout.shared.standardizedFileURL,
                      target.standardizedFileURL != storage.layout.exports.standardizedFileURL else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try storage.fileManager.removeItem(at: target)
                completionHandler(nil)
                Self.signalWorkingSet(in: domain)
            } catch {
                completionHandler(error)
            }
        }
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(identifier: containerItemIdentifier, domainIdentifier: domain.identifier)
    }

    private static func signalWorkingSet(in domain: NSFileProviderDomain) {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { error in
            if let error { NSLog("无法刷新 ETOS 工作区：%@", error.localizedDescription) }
        }
    }

    private static func destinationRelativePath(_ url: URL, storage: FileProviderStorage) throws -> String {
        let root = storage.layout.container.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { throw NSFileProviderError(.noSuchItem) }
        return String(path.dropFirst(root.count))
    }
}

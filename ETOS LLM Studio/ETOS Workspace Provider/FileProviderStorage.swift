// ============================================================================
// FileProviderStorage.swift
// ETOS Workspace Provider
// ============================================================================

import ETOSCore
import FileProvider
import Foundation

struct FileProviderStorage {
    let layout: ETOSSharedStorageLayout
    let fileManager: FileManager

    init(fileManager: FileManager = .default) throws {
        guard let layout = ETOSSharedStorageLayout.resolve(fileManager: fileManager) else {
            throw NSFileProviderError(.providerNotFound)
        }
        self.layout = layout
        self.fileManager = fileManager
        try layout.prepare(fileManager: fileManager)
    }

    func identifier(for url: URL) throws -> NSFileProviderItemIdentifier {
        let relative = try relativePath(for: url)
        return identifier(forRelativePath: relative)
    }

    func identifier(forRelativePath relative: String) -> NSFileProviderItemIdentifier {
        let encoded = Data(relative.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return NSFileProviderItemIdentifier("path:\(encoded)")
    }

    func url(for identifier: NSFileProviderItemIdentifier, allowMissingLeaf: Bool = false) throws -> URL {
        guard identifier != .rootContainer,
              identifier.rawValue.hasPrefix("path:") else {
            throw NSFileProviderError(.noSuchItem)
        }
        var encoded = String(identifier.rawValue.dropFirst(5))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count.isMultiple(of: 4) == false { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded),
              let relative = String(data: data, encoding: .utf8) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return try url(forRelativePath: relative, allowMissingLeaf: allowMissingLeaf)
    }

    func url(forRelativePath relative: String, allowMissingLeaf: Bool = false) throws -> URL {
        let components: [String]
        do {
            components = try ETOSSharedWorkspacePathValidator.components(for: relative)
        } catch {
            throw NSFileProviderError(.noSuchItem)
        }
        var result = layout.container
        for (index, component) in components.enumerated() {
            result.appendPathComponent(component)
            if allowMissingLeaf && index == components.count - 1 && !fileManager.fileExists(atPath: result.path) {
                continue
            }
            let values = try result.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw NSFileProviderError(.noSuchItem) }
        }
        let rootPath = layout.container.standardizedFileURL.path + "/"
        guard result.standardizedFileURL.path.hasPrefix(rootPath) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return result
    }

    func relativePath(for url: URL) throws -> String {
        let path = url.standardizedFileURL.path
        let root = layout.container.standardizedFileURL.path + "/"
        guard path.hasPrefix(root) else { throw NSFileProviderError(.noSuchItem) }
        let relative = String(path.dropFirst(root.count))
        _ = try self.url(forRelativePath: relative)
        return relative
    }

    func children(of identifier: NSFileProviderItemIdentifier) throws -> [FileProviderItem] {
        if identifier == .rootContainer {
            return try [layout.shared, layout.exports].map { try FileProviderItem(url: $0, storage: self) }
        }
        let directory = try url(for: identifier)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw NSFileProviderError(.noSuchItem) }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(FileProviderItem.resourceKeys),
            options: [.skipsHiddenFiles]
        )
        .prefix(10_000)
        .compactMap { url in
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            return values.isSymbolicLink == true ? nil : try FileProviderItem(url: url, storage: self)
        }
        .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    func validatedName(_ name: String) throws -> String {
        do {
            return try ETOSSharedWorkspacePathValidator.fileName(name)
        } catch {
            throw NSFileProviderError(.filenameCollision)
        }
    }
}

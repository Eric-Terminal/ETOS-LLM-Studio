// ============================================================================
// ETOSAppGroupStorageMigrator.swift
// ETOS LLM Studio
// ============================================================================

import Foundation

public struct ETOSAppGroupMigrationReceipt: Codable, Equatable, Sendable {
    public let version: Int
    public let migratedAt: Date
    public let migratedFileCount: Int

    public init(version: Int = 1, migratedAt: Date = Date(), migratedFileCount: Int) {
        self.version = version
        self.migratedAt = migratedAt
        self.migratedFileCount = migratedFileCount
    }
}

public enum ETOSAppGroupStorageMigrator {
    public static func migrateLegacyLinuxDirectories(
        layout: LocalLinuxStorageLayout,
        sharedLayout providedSharedLayout: ETOSSharedStorageLayout? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard let sharedLayout = providedSharedLayout
            ?? ETOSSharedStorageLayout.resolve(fileManager: fileManager) else { return }
        try sharedLayout.prepare(fileManager: fileManager)
        let receiptURL = sharedLayout.receipts.appendingPathComponent("linux-shared-migration-v1.json")
        if fileManager.fileExists(atPath: receiptURL.path) { return }

        var migratedCount = 0
        migratedCount += try migrateDirectory(
            from: layout.legacyShared,
            to: layout.shared,
            expectedParent: layout.root,
            staging: sharedLayout.staging,
            fileManager: fileManager
        )
        migratedCount += try migrateDirectory(
            from: layout.legacyExports,
            to: layout.exports,
            expectedParent: layout.root,
            staging: sharedLayout.staging,
            fileManager: fileManager
        )
        try ETOSSharedFileStore.write(
            ETOSAppGroupMigrationReceipt(migratedFileCount: migratedCount),
            to: receiptURL,
            fileManager: fileManager
        )
    }

    private static func migrateDirectory(
        from source: URL,
        to destination: URL,
        expectedParent: URL,
        staging: URL,
        fileManager: FileManager
    ) throws -> Int {
        let sourcePath = source.standardizedFileURL.path
        let parentPath = expectedParent.standardizedFileURL.path + "/"
        guard sourcePath.hasPrefix(parentPath), sourcePath != expectedParent.standardizedFileURL.path else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard fileManager.fileExists(atPath: sourcePath) else { return 0 }
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }

        var directories: [URL] = []
        var files: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            if values.isDirectory == true { directories.append(item) }
            else if values.isRegularFile == true { files.append(item) }
        }

        for directory in directories {
            let relative = relativePath(of: directory, below: source)
            try fileManager.createDirectory(
                at: destination.appendingPathComponent(relative, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        for file in files {
            let relative = relativePath(of: file, below: source)
            var target = destination.appendingPathComponent(relative, isDirectory: false)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                if try filesMatch(file, target, fileManager: fileManager) { continue }
                let stem = target.deletingPathExtension().lastPathComponent
                let suffix = target.pathExtension
                let name = suffix.isEmpty
                    ? "\(stem)-migrated-\(UUID().uuidString)"
                    : "\(stem)-migrated-\(UUID().uuidString).\(suffix)"
                target = target.deletingLastPathComponent().appendingPathComponent(name)
            }
            let staged = staging.appendingPathComponent(UUID().uuidString)
            try fileManager.copyItem(at: file, to: staged)
            try fileManager.moveItem(at: staged, to: target)
        }

        // 仅在完整枚举且所有文件发布成功后清理已验证的旧目录。
        try fileManager.removeItem(at: source)
        return files.count
    }

    private static func relativePath(of item: URL, below root: URL) -> String {
        String(item.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private static func filesMatch(_ lhs: URL, _ rhs: URL, fileManager: FileManager) throws -> Bool {
        let lhsSize = try lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let rhsSize = try rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard lhsSize == rhsSize else { return false }
        let left = try FileHandle(forReadingFrom: lhs)
        let right = try FileHandle(forReadingFrom: rhs)
        defer {
            try? left.close()
            try? right.close()
        }
        while true {
            let leftData = try left.read(upToCount: 64 * 1_024) ?? Data()
            let rightData = try right.read(upToCount: 64 * 1_024) ?? Data()
            guard leftData == rightData else { return false }
            if leftData.isEmpty { return true }
        }
    }
}

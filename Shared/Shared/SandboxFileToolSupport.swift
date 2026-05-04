// ============================================================================
// SandboxFileToolSupport.swift
// ============================================================================
// 沙盒文件工具辅助。
// - 仅允许访问 Documents 根目录及其子路径
// - 提供列目录、读文本、写文本能力
// ============================================================================

import Foundation

public enum SandboxFileToolSupport {
    public static func listDirectory(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> [SandboxFileEntry] {
        let directoryURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: directoryURL, rootDirectory: rootDirectory))
        }
        guard isDirectory.boolValue else {
            throw SandboxFileToolError.directoryExpected(normalizedDisplayPath(for: directoryURL, rootDirectory: rootDirectory))
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let formatter = ISO8601DateFormatter()
        return contents.compactMap { url in
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return SandboxFileEntry(
                    path: normalizedDisplayPath(for: url, rootDirectory: rootDirectory),
                    name: url.lastPathComponent,
                    isDirectory: values.isDirectory ?? false,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate.map(formatter.string(from:))
                )
            } catch {
                return nil
            }
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func readTextFile(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> String {
        let fileURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }
        guard !isDirectory.boolValue else {
            throw SandboxFileToolError.fileExpected(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }

        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            throw SandboxFileToolError.unsupportedEncoding(normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory))
        }
        return content
    }

    public static func writeTextFile(
        relativePath: String,
        content: String,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileWriteResult {
        let fileURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        let parentDirectory = fileURL.deletingLastPathComponent()
        let displayPath = normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory)

        var isDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory)
        var createdDirectories = false

        if parentExists {
            guard isDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("父路径“%@”不是目录，无法写入文件。", comment: "Sandbox tool parent path not directory"),
                        normalizedDisplayPath(for: parentDirectory, rootDirectory: rootDirectory)
                    )
                )
            }
        } else if createIntermediateDirectories {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            createdDirectories = true
        } else {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox tool parent missing"),
                    normalizedDisplayPath(for: parentDirectory, rootDirectory: rootDirectory)
                )
            )
        }

        var targetIsDirectory: ObjCBool = false
        let existedBeforeWrite = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &targetIsDirectory)
        if existedBeforeWrite && targetIsDirectory.boolValue {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("路径“%@”是目录，不能按文件写入。", comment: "Sandbox tool target is directory"),
                    displayPath
                )
            )
        }

        let previousData = existedBeforeWrite ? (try? Data(contentsOf: fileURL)) : nil

        let data = Data(content.utf8)
        do {
            try data.write(to: fileURL, options: [.atomic])
            StorageUtility.notifyFilesystemMutation(at: fileURL)

            if existedBeforeWrite {
                let restoreData = previousData
                pushUndoEntry(
                    rootDirectory: rootDirectory,
                    operation: "write_sandbox_file"
                ) {
                    if let restoreData {
                        try restoreData.write(to: fileURL, options: [.atomic])
                        StorageUtility.notifyFilesystemMutation(at: fileURL)
                    } else if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                        StorageUtility.notifyFilesystemMutation(at: fileURL)
                    }
                }
            } else {
                pushUndoEntry(
                    rootDirectory: rootDirectory,
                    operation: "write_sandbox_file"
                ) {
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        try FileManager.default.removeItem(at: fileURL)
                        StorageUtility.notifyFilesystemMutation(at: fileURL)
                    }
                }
            }

            return SandboxFileWriteResult(
                path: displayPath,
                size: Int64(data.count),
                createdParentDirectories: createdDirectories
            )
        } catch {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("写入文件“%@”失败：%@", comment: "Sandbox tool write failed"),
                    normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory),
                    error.localizedDescription
                )
            )
        }
    }

    public static func diffTextFile(
        relativePath: String,
        updatedContent: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> String {
        let currentContent = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        let diff = simpleUnifiedDiff(
            original: currentContent,
            updated: updatedContent
        )
        return diff.isEmpty
            ? NSLocalizedString("内容没有变化。", comment: "Sandbox diff no changes")
            : diff
    }

    public static func replaceText(
        relativePath: String,
        oldText: String,
        newText: String,
        replaceAll: Bool = false,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileEditResult {
        let currentContent = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        guard !oldText.isEmpty else {
            throw SandboxFileToolError.emptyMatchText
        }

        let matchCount = occurrenceCount(of: oldText, in: currentContent)
        guard matchCount > 0 else {
            throw SandboxFileToolError.oldTextNotFound
        }
        if matchCount > 1 && !replaceAll {
            throw SandboxFileToolError.ambiguousMatch(count: matchCount)
        }

        let nextContent: String
        let replacements: Int
        if replaceAll {
            nextContent = currentContent.replacingOccurrences(of: oldText, with: newText)
            replacements = matchCount
        } else {
            nextContent = currentContent.replacingOccurrences(of: oldText, with: newText, options: [], range: currentContent.range(of: oldText))
            replacements = 1
        }

        let writeResult = try writeTextFile(
            relativePath: relativePath,
            content: nextContent,
            createIntermediateDirectories: true,
            rootDirectory: rootDirectory
        )
        return SandboxFileEditResult(
            path: writeResult.path,
            replacements: replacements,
            size: writeResult.size
        )
    }

    public static func deleteItem(
        relativePath: String,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileDeleteResult {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Documents" || trimmed == "/" {
            throw SandboxFileToolError.deletingRootDirectory
        }

        let targetURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: targetURL, rootDirectory: rootDirectory))
        }

        let backupURL = try backupItem(at: targetURL)
        let displayPath = normalizedDisplayPath(for: targetURL, rootDirectory: rootDirectory)
        try FileManager.default.removeItem(at: targetURL)
        StorageUtility.notifyFilesystemMutation(at: targetURL)
        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "delete_sandbox_item",
            discard: { try? FileManager.default.removeItem(at: backupURL) }
        ) {
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                throw SandboxFileToolError.destinationAlreadyExists(displayPath)
            }
            try FileManager.default.copyItem(at: backupURL, to: targetURL)
            StorageUtility.notifyFilesystemMutation(at: targetURL)
            try? FileManager.default.removeItem(at: backupURL)
        }

        return SandboxFileDeleteResult(
            path: displayPath,
            wasDirectory: isDirectory.boolValue
        )
    }

    public static func createDirectory(
        relativePath: String,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxDirectoryCreateResult {
        let directoryURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
        let displayPath = normalizedDisplayPath(for: directoryURL, rootDirectory: rootDirectory)

        var isDirectory: ObjCBool = false
        let alreadyExists = FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
        if alreadyExists {
            guard isDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("路径“%@”已存在且不是目录。", comment: "Sandbox create directory path exists"),
                        displayPath
                    )
                )
            }
            return SandboxDirectoryCreateResult(
                path: displayPath,
                created: false,
                createdParentDirectories: false
            )
        }

        let parentURL = directoryURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &parentIsDirectory)
        let createdParentDirectories = !parentExists && createIntermediateDirectories

        if parentExists {
            guard parentIsDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("父路径“%@”不是目录，无法创建目录。", comment: "Sandbox create directory parent not directory"),
                        normalizedDisplayPath(for: parentURL, rootDirectory: rootDirectory)
                    )
                )
            }
        } else if !createIntermediateDirectories {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox create directory parent missing"),
                    normalizedDisplayPath(for: parentURL, rootDirectory: rootDirectory)
                )
            )
        }

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: createIntermediateDirectories
        )
        StorageUtility.notifyFilesystemMutation(at: directoryURL)

        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "create_sandbox_directory"
        ) {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.removeItem(at: directoryURL)
                StorageUtility.notifyFilesystemMutation(at: directoryURL)
            }
        }

        return SandboxDirectoryCreateResult(
            path: displayPath,
            created: true,
            createdParentDirectories: createdParentDirectories
        )
    }

    public static func copyItem(
        from sourceRelativePath: String,
        to destinationRelativePath: String,
        overwrite: Bool = false,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileCopyResult {
        let sourceURL = try resolveURL(relativePath: sourceRelativePath, rootDirectory: rootDirectory, allowRoot: false)
        let destinationURL = try resolveURL(relativePath: destinationRelativePath, rootDirectory: rootDirectory, allowRoot: false)

        let sourceDisplayPath = normalizedDisplayPath(for: sourceURL, rootDirectory: rootDirectory)
        let destinationDisplayPath = normalizedDisplayPath(for: destinationURL, rootDirectory: rootDirectory)
        guard sourceURL.path != destinationURL.path else {
            throw SandboxFileToolError.sourceAndDestinationSame
        }

        var sourceIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory) else {
            throw SandboxFileToolError.fileNotFound(sourceDisplayPath)
        }

        if sourceIsDirectory.boolValue {
            let sourcePath = sourceURL.standardizedFileURL.path
            let destinationPath = destinationURL.standardizedFileURL.path
            if destinationPath.hasPrefix(sourcePath + "/") {
                throw SandboxFileToolError.cannotCopyIntoSelf
            }
        }

        let destinationParent = destinationURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: destinationParent.path, isDirectory: &parentIsDirectory)
        var createdParentDirectories = false
        if parentExists {
            guard parentIsDirectory.boolValue else {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("父路径“%@”不是目录，无法复制。", comment: "Sandbox copy parent not directory"),
                        normalizedDisplayPath(for: destinationParent, rootDirectory: rootDirectory)
                    )
                )
            }
        } else if createIntermediateDirectories {
            try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
            createdParentDirectories = true
        } else {
            throw SandboxFileToolError.writeFailed(
                String(
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox copy parent missing"),
                    normalizedDisplayPath(for: destinationParent, rootDirectory: rootDirectory)
                )
            )
        }

        let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
        var overwrittenBackupURL: URL?
        if destinationExists {
            guard overwrite else {
                throw SandboxFileToolError.destinationAlreadyExists(destinationDisplayPath)
            }
            overwrittenBackupURL = try backupItem(at: destinationURL)
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        StorageUtility.notifyFilesystemMutation(at: destinationURL)

        let backupURLForUndo = overwrittenBackupURL
        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "copy_sandbox_item",
            discard: {
                if let backupURLForUndo {
                    try? FileManager.default.removeItem(at: backupURLForUndo)
                }
            }
        ) {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
                StorageUtility.notifyFilesystemMutation(at: destinationURL)
            }
            if let backupURLForUndo {
                try FileManager.default.copyItem(at: backupURLForUndo, to: destinationURL)
                try? FileManager.default.removeItem(at: backupURLForUndo)
                StorageUtility.notifyFilesystemMutation(at: destinationURL)
            }
        }

        return SandboxFileCopyResult(
            sourcePath: sourceDisplayPath,
            destinationPath: destinationDisplayPath,
            wasDirectory: sourceIsDirectory.boolValue,
            createdParentDirectories: createdParentDirectories,
            overwroteDestination: destinationExists
        )
    }

    public static func batchReplaceText(
        relativePath: String,
        rules: [SandboxBatchEditRule],
        replaceAll: Bool = false,
        ignoreMissing: Bool = false,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileBatchEditResult {
        guard !rules.isEmpty else {
            throw SandboxFileToolError.emptyBatchRules
        }
        let originalContent = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        var currentContent = originalContent

        var totalReplacements = 0
        var appliedRules = 0
        for rule in rules {
            guard !rule.oldText.isEmpty else {
                throw SandboxFileToolError.emptyMatchText
            }

            let matchCount = occurrenceCount(of: rule.oldText, in: currentContent)
            if matchCount == 0 {
                if ignoreMissing {
                    continue
                }
                throw SandboxFileToolError.oldTextNotFound
            }
            if matchCount > 1 && !replaceAll {
                throw SandboxFileToolError.ambiguousMatch(count: matchCount)
            }

            if replaceAll {
                currentContent = currentContent.replacingOccurrences(of: rule.oldText, with: rule.newText)
                totalReplacements += matchCount
            } else if let firstRange = currentContent.range(of: rule.oldText) {
                currentContent = currentContent.replacingCharacters(in: firstRange, with: rule.newText)
                totalReplacements += 1
            }
            appliedRules += 1
        }

        if currentContent == originalContent {
            let fileURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false)
            let data = try Data(contentsOf: fileURL)
            return SandboxFileBatchEditResult(
                path: normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory),
                replacements: totalReplacements,
                rulesApplied: appliedRules,
                size: Int64(data.count)
            )
        }

        let writeResult = try writeTextFile(
            relativePath: relativePath,
            content: currentContent,
            createIntermediateDirectories: true,
            rootDirectory: rootDirectory
        )
        return SandboxFileBatchEditResult(
            path: writeResult.path,
            replacements: totalReplacements,
            rulesApplied: appliedRules,
            size: writeResult.size
        )
    }
}

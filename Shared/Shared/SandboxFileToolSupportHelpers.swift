// ============================================================================
// SandboxFileToolSupportHelpers.swift
// ============================================================================
// 沙盒文件工具辅助的撤销、搜索、分块、移动和路径支撑。
// ============================================================================

import Foundation

extension SandboxFileToolSupport {
    struct SandboxUndoEntry {
        let rootPath: String
        let operation: String
        let recordedAt: Date
        let undo: () throws -> Void
        let discard: () -> Void
    }

    private static let undoDateFormatter = ISO8601DateFormatter()
    private static let undoLock = NSLock()
    private static var undoStack: [SandboxUndoEntry] = []
    private static let maxUndoEntries = 64

    public static func undoLastMutation(
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileUndoResult {
        let rootPath = rootDirectory.standardizedFileURL.path
        guard let entry = popUndoEntry(for: rootPath) else {
            throw SandboxFileToolError.noUndoHistory
        }

        do {
            try entry.undo()
            entry.discard()
            return SandboxFileUndoResult(
                operation: entry.operation,
                recordedAt: undoDateFormatter.string(from: entry.recordedAt)
            )
        } catch {
            restoreUndoEntry(entry)
            throw error
        }
    }

    public static func searchItems(
        relativePath: String,
        nameQuery: String?,
        contentQuery: String?,
        maxResults: Int = 20,
        includeDirectories: Bool = false,
        caseSensitive: Bool = false,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> [SandboxFileSearchResult] {
        let baseURL = try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(normalizedDisplayPath(for: baseURL, rootDirectory: rootDirectory))
        }
        guard isDirectory.boolValue else {
            throw SandboxFileToolError.directoryExpected(normalizedDisplayPath(for: baseURL, rootDirectory: rootDirectory))
        }

        let trimmedNameQuery = nameQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContentQuery = contentQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNameQuery = !(trimmedNameQuery ?? "").isEmpty
        let hasContentQuery = !(trimmedContentQuery ?? "").isEmpty
        guard hasNameQuery || hasContentQuery else {
            throw SandboxFileToolError.missingSearchQuery
        }

        let resolvedLimit = min(max(1, maxResults), 200)
        let nameNeedle = hasNameQuery ? (trimmedNameQuery ?? "") : nil
        let contentNeedle = hasContentQuery ? (trimmedContentQuery ?? "") : nil
        let formatter = ISO8601DateFormatter()

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [SandboxFileSearchResult] = []

        for case let itemURL as URL in enumerator {
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isCurrentDirectory = values.isDirectory ?? false
            if isCurrentDirectory && !includeDirectories {
                continue
            }

            let displayPath = normalizedDisplayPath(for: itemURL, rootDirectory: rootDirectory)
            let matchedByName = nameNeedle.map {
                contains(haystack: displayPath, needle: $0, caseSensitive: caseSensitive)
                || contains(haystack: itemURL.lastPathComponent, needle: $0, caseSensitive: caseSensitive)
            } ?? false
            let nameMatched = nameNeedle == nil || matchedByName

            var matchedByContent = false
            if let contentNeedle, !isCurrentDirectory {
                if let data = try? Data(contentsOf: itemURL),
                   let text = String(data: data, encoding: .utf8) {
                    matchedByContent = contains(haystack: text, needle: contentNeedle, caseSensitive: caseSensitive)
                }
            }
            let contentMatched = contentNeedle == nil || matchedByContent

            guard nameMatched && contentMatched else { continue }

            results.append(
                SandboxFileSearchResult(
                    path: displayPath,
                    name: itemURL.lastPathComponent,
                    isDirectory: isCurrentDirectory,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate.map(formatter.string(from:)),
                    matchedByName: matchedByName,
                    matchedByContent: matchedByContent
                )
            )
            if results.count >= resolvedLimit {
                break
            }
        }

        return results.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    public static func readTextFileChunk(
        relativePath: String,
        startLine: Int = 1,
        maxLines: Int = 200,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileChunkReadResult {
        guard startLine >= 1, maxLines >= 1 else {
            throw SandboxFileToolError.invalidChunkRange
        }
        let resolvedMaxLines = min(maxLines, 1000)
        let content = try readTextFile(relativePath: relativePath, rootDirectory: rootDirectory)
        let lines = normalizedTextLines(content)
        let totalLines = lines.count
        let displayPath = normalizedDisplayPath(
            for: try resolveURL(relativePath: relativePath, rootDirectory: rootDirectory, allowRoot: false),
            rootDirectory: rootDirectory
        )

        guard totalLines > 0 else {
            return SandboxFileChunkReadResult(
                path: displayPath,
                startLine: 1,
                endLine: 0,
                totalLines: 0,
                hasMore: false,
                content: ""
            )
        }
        guard startLine <= totalLines else {
            throw SandboxFileToolError.invalidChunkRange
        }

        let startIndex = startLine - 1
        let endExclusive = min(startIndex + resolvedMaxLines, totalLines)
        let selected = Array(lines[startIndex..<endExclusive])
        let endLine = startLine + selected.count - 1

        return SandboxFileChunkReadResult(
            path: displayPath,
            startLine: startLine,
            endLine: endLine,
            totalLines: totalLines,
            hasMore: endExclusive < totalLines,
            content: selected.joined(separator: "\n")
        )
    }

    public static func moveItem(
        from sourceRelativePath: String,
        to destinationRelativePath: String,
        overwrite: Bool = false,
        createIntermediateDirectories: Bool = true,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileMoveResult {
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
                throw SandboxFileToolError.cannotMoveIntoSelf
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
                        format: NSLocalizedString("父路径“%@”不是目录，无法移动。", comment: "Sandbox tool move parent not directory"),
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
                    format: NSLocalizedString("父目录“%@”不存在，且当前未允许自动创建。", comment: "Sandbox tool move parent missing"),
                    normalizedDisplayPath(for: destinationParent, rootDirectory: rootDirectory)
                )
            )
        }

        var destinationIsDirectory: ObjCBool = false
        let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory)
        var overwrittenBackupURL: URL?
        if destinationExists {
            guard overwrite else {
                throw SandboxFileToolError.destinationAlreadyExists(destinationDisplayPath)
            }
            overwrittenBackupURL = try backupItem(at: destinationURL)
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        StorageUtility.notifyFilesystemMutation(at: sourceURL)
        StorageUtility.notifyFilesystemMutation(at: destinationURL)

        let backupURLForUndo = overwrittenBackupURL
        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "move_sandbox_item",
            discard: {
                if let backupURLForUndo {
                    try? FileManager.default.removeItem(at: backupURLForUndo)
                }
            }
        ) {
            guard !FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw SandboxFileToolError.destinationAlreadyExists(sourceDisplayPath)
            }
            guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw SandboxFileToolError.fileNotFound(destinationDisplayPath)
            }

            try FileManager.default.moveItem(at: destinationURL, to: sourceURL)
            StorageUtility.notifyFilesystemMutation(at: destinationURL)
            StorageUtility.notifyFilesystemMutation(at: sourceURL)

            if let backupURLForUndo {
                try FileManager.default.copyItem(at: backupURLForUndo, to: destinationURL)
                try? FileManager.default.removeItem(at: backupURLForUndo)
                StorageUtility.notifyFilesystemMutation(at: destinationURL)
            }
        }

        return SandboxFileMoveResult(
            sourcePath: sourceDisplayPath,
            destinationPath: destinationDisplayPath,
            wasDirectory: sourceIsDirectory.boolValue,
            createdParentDirectories: createdParentDirectories,
            overwroteDestination: destinationExists
        )
    }

    internal static func resolveURL(
        relativePath: String,
        rootDirectory: URL,
        allowRoot: Bool
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInput = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if normalizedInput.isEmpty {
            guard allowRoot else {
                throw SandboxFileToolError.invalidPath
            }
            return rootDirectory.standardizedFileURL
        }

        let strippedInput: String
        if normalizedInput == "Documents" {
            strippedInput = ""
        } else if normalizedInput.hasPrefix("Documents/") {
            strippedInput = String(normalizedInput.dropFirst("Documents/".count))
        } else {
            strippedInput = normalizedInput
        }

        let pathComponents = strippedInput
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !pathComponents.isEmpty else {
            guard allowRoot else {
                throw SandboxFileToolError.invalidPath
            }
            return rootDirectory.standardizedFileURL
        }

        guard !pathComponents.contains("..") else {
            throw SandboxFileToolError.escapedSandbox
        }

        let targetURL = pathComponents.reduce(rootDirectory) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL

        let rootPath = rootDirectory.standardizedFileURL.path
        let targetPath = targetURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            throw SandboxFileToolError.escapedSandbox
        }

        return targetURL
    }

    internal static func normalizedDisplayPath(
        for url: URL,
        rootDirectory: URL
    ) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path

        if targetPath == rootPath {
            return "Documents"
        }

        let relative = String(targetPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "Documents" : "Documents/\(relative)"
    }

    internal static func pushUndoEntry(
        rootDirectory: URL,
        operation: String,
        discard: @escaping () -> Void = {},
        undo: @escaping () throws -> Void
    ) {
        let entry = SandboxUndoEntry(
            rootPath: rootDirectory.standardizedFileURL.path,
            operation: operation,
            recordedAt: Date(),
            undo: undo,
            discard: discard
        )

        undoLock.lock()
        undoStack.append(entry)
        if undoStack.count > maxUndoEntries {
            let stale = undoStack.removeFirst()
            stale.discard()
        }
        undoLock.unlock()
    }

    internal static func popUndoEntry(for rootPath: String) -> SandboxUndoEntry? {
        undoLock.lock()
        defer { undoLock.unlock() }
        guard let index = undoStack.lastIndex(where: { $0.rootPath == rootPath }) else {
            return nil
        }
        return undoStack.remove(at: index)
    }

    internal static func restoreUndoEntry(_ entry: SandboxUndoEntry) {
        undoLock.lock()
        undoStack.append(entry)
        undoLock.unlock()
    }

    internal static func backupItem(at url: URL) throws -> URL {
        let backupRoot = try backupRootDirectory()
        let backupURL = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.copyItem(at: url, to: backupURL)
        return backupURL
    }

    internal static func backupRootDirectory() throws -> URL {
        let root = StorageUtility.documentsDirectory
            .appendingPathComponent(".sandbox-file-tool-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    internal static func occurrenceCount(of token: String, in text: String) -> Int {
        guard !token.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<text.endIndex
        }
        return count
    }

    internal static func simpleUnifiedDiff(original: String, updated: String) -> String {
        let originalLines = normalizeLines(original)
        let updatedLines = normalizeLines(updated)
        let difference = updatedLines.difference(from: originalLines)

        guard !difference.isEmpty else { return "" }

        let orderedChanges = difference.sorted { lhs, rhs in
            let lhsOffset: Int
            let rhsOffset: Int
            switch lhs {
            case .remove(let offset, _, _), .insert(let offset, _, _):
                lhsOffset = offset
            }
            switch rhs {
            case .remove(let offset, _, _), .insert(let offset, _, _):
                rhsOffset = offset
            }
            if lhsOffset == rhsOffset {
                switch (lhs, rhs) {
                case (.remove, .insert):
                    return true
                case (.insert, .remove):
                    return false
                default:
                    return true
                }
            }
            return lhsOffset < rhsOffset
        }

        var lines: [String] = ["--- current", "+++ proposed"]
        for change in orderedChanges {
            switch change {
            case .remove(let offset, let element, _):
                lines.append("@@ line \(offset + 1) @@")
                lines.append("-\(element)")
            case .insert(let offset, let element, _):
                lines.append("@@ line \(offset + 1) @@")
                lines.append("+\(element)")
            }
        }

        return lines.joined(separator: "\n")
    }

    internal static func normalizeLines(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    internal static func normalizedTextLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return normalizeLines(text)
    }

    internal static func contains(
        haystack: String,
        needle: String,
        caseSensitive: Bool
    ) -> Bool {
        if caseSensitive {
            return haystack.range(of: needle) != nil
        }
        return haystack.range(of: needle, options: .caseInsensitive) != nil
    }
}

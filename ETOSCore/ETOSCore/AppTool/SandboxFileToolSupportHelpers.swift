// ============================================================================
// SandboxFileToolSupportHelpers.swift
// ============================================================================
// 沙盒文件工具辅助的撤销、搜索、分块、移动和路径支撑。
// ============================================================================

import Foundation

extension SandboxFileToolSupport {
    struct SandboxUndoContext: Sendable {
        let runID: UUID
        let mutationID: UUID
    }

    @TaskLocal internal static var undoContext: SandboxUndoContext?

    struct SandboxUndoEntry {
        let rootPath: String
        let context: SandboxUndoContext?
        let operation: String
        let recordedAt: Date
        let rollbackURLs: [URL]
        let undo: () throws -> Void
        let discard: () -> Void
    }

    private struct SandboxUndoRollbackSnapshot {
        let targetURL: URL
        let backupURL: URL?
    }

    private static let undoDateFormatter = ISO8601DateFormatter()
    private static let undoLock = NSLock()
    private static var undoStack: [SandboxUndoEntry] = []
    private static let maxUndoEntries = 64

    public static func undoLastMutation(
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileUndoResult {
        let rootPath = rootDirectory.standardizedFileURL.path
        guard let reserved = reserveUndoEntry(for: rootPath, context: nil) else {
            throw SandboxFileToolError.noUndoHistory
        }
        let entry = reserved.entry

        do {
            try performTransactionalUndo(entry)
            entry.discard()
            return SandboxFileUndoResult(
                operation: entry.operation,
                recordedAt: undoDateFormatter.string(from: entry.recordedAt)
            )
        } catch {
            restoreUndoEntry(entry, at: reserved.index)
            throw error
        }
    }

    /// Agent 文件工具使用精确 mutation ID，避免不同 Run 共用 Documents 撤销栈。
    static func undoMutation(
        id: UUID,
        runID: UUID,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileUndoResult {
        let context = SandboxUndoContext(runID: runID, mutationID: id)
        let rootPath = rootDirectory.standardizedFileURL.path
        guard let reserved = reserveUndoEntry(for: rootPath, context: context) else {
            throw SandboxFileToolError.noUndoHistory
        }
        do {
            try performTransactionalUndo(reserved.entry)
            reserved.entry.discard()
            return SandboxFileUndoResult(
                operation: reserved.entry.operation,
                recordedAt: undoDateFormatter.string(from: reserved.entry.recordedAt)
            )
        } catch {
            restoreUndoEntry(reserved.entry, at: reserved.index)
            throw error
        }
    }

    static func hasUndoMutation(id: UUID, runID: UUID) -> Bool {
        undoLock.lock()
        defer { undoLock.unlock() }
        return undoStack.contains {
            $0.context?.runID == runID && $0.context?.mutationID == id
        }
    }

    static func discardUndoMutations(runID: UUID) {
        undoLock.lock()
        let discarded = undoStack.filter { $0.context?.runID == runID }
        undoStack.removeAll { $0.context?.runID == runID }
        undoLock.unlock()
        discarded.forEach { $0.discard() }
    }

    static func discardUndoMutation(id: UUID, runID: UUID) {
        undoLock.lock()
        let index = undoStack.lastIndex {
            $0.context?.runID == runID && $0.context?.mutationID == id
        }
        let discarded = index.map { undoStack.remove(at: $0) }
        undoLock.unlock()
        discarded?.discard()
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
        byteOffset: UInt64? = nil,
        maxBytes: Int = 262_144,
        rootDirectory: URL = StorageUtility.documentsDirectory
    ) throws -> SandboxFileChunkReadResult {
        guard startLine >= 1, maxLines >= 1 else {
            throw SandboxFileToolError.invalidChunkRange
        }
        let resolvedMaxLines = min(maxLines, 1_000)
        let resolvedMaxBytes = min(1_048_576, max(4, maxBytes))
        let fileURL = try resolveURL(
            relativePath: relativePath,
            rootDirectory: rootDirectory,
            allowRoot: false
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw SandboxFileToolError.fileNotFound(
                normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory)
            )
        }
        guard !isDirectory.boolValue else {
            throw SandboxFileToolError.fileExpected(
                normalizedDisplayPath(for: fileURL, rootDirectory: rootDirectory)
            )
        }
        let displayPath = normalizedDisplayPath(
            for: fileURL,
            rootDirectory: rootDirectory
        )
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset = byteOffset ?? 0
        try handle.seek(toOffset: offset)
        var currentLine = byteOffset == nil ? 1 : startLine
        var completedSelectedLines = 0
        var lastSelectedLine: Int?
        var content = Data()
        var previousWasCarriageReturn = false
        var pendingStopAfterCarriageReturn = false
        var pendingStopIsTruncated = false

        while true {
            let page = try handle.read(upToCount: 256 * 1_024) ?? Data()
            var index = page.startIndex
            while index < page.endIndex {
                let byte = page[index]
                let absoluteOffset = offset + UInt64(page.distance(from: page.startIndex, to: index))
                if pendingStopAfterCarriageReturn {
                    let nextOffset = byte == 0x0A ? absoluteOffset + 1 : absoluteOffset
                    return try sandboxChunkResult(
                        path: displayPath,
                        startLine: startLine,
                        currentLine: currentLine,
                        lastSelectedLine: lastSelectedLine,
                        content: content,
                        totalLines: nil,
                        contentTruncated: pendingStopIsTruncated,
                        nextByteOffset: nextOffset,
                        nextStartLine: currentLine
                    )
                }
                if byte == 0x0A, previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                    index = page.index(after: index)
                    continue
                }
                previousWasCarriageReturn = false

                if byte == 0x0A || byte == 0x0D {
                    if currentLine >= startLine {
                        lastSelectedLine = currentLine
                        if completedSelectedLines < resolvedMaxLines {
                            completedSelectedLines += 1
                        }
                    }
                    if currentLine < Int.max {
                        currentLine += 1
                    }
                    if completedSelectedLines >= resolvedMaxLines {
                        if byte == 0x0D {
                            pendingStopAfterCarriageReturn = true
                            pendingStopIsTruncated = false
                            previousWasCarriageReturn = true
                            index = page.index(after: index)
                            continue
                        }
                        return try sandboxChunkResult(
                            path: displayPath,
                            startLine: startLine,
                            currentLine: currentLine,
                            lastSelectedLine: lastSelectedLine,
                            content: content,
                            totalLines: nil,
                            contentTruncated: false,
                            nextByteOffset: absoluteOffset + 1,
                            nextStartLine: currentLine
                        )
                    }
                    if currentLine > startLine {
                        if content.count == resolvedMaxBytes {
                            if byte == 0x0D {
                                pendingStopAfterCarriageReturn = true
                                pendingStopIsTruncated = true
                                previousWasCarriageReturn = true
                                index = page.index(after: index)
                                continue
                            }
                            return try sandboxChunkResult(
                                path: displayPath,
                                startLine: startLine,
                                currentLine: currentLine,
                                lastSelectedLine: lastSelectedLine,
                                content: content,
                                totalLines: nil,
                                contentTruncated: true,
                                nextByteOffset: absoluteOffset + 1,
                                nextStartLine: currentLine
                            )
                        }
                        content.append(0x0A)
                    }
                    previousWasCarriageReturn = byte == 0x0D
                } else if currentLine >= startLine {
                    if content.count == resolvedMaxBytes {
                        return try sandboxChunkResult(
                            path: displayPath,
                            startLine: startLine,
                            currentLine: currentLine,
                            lastSelectedLine: currentLine,
                            content: content,
                            totalLines: nil,
                            contentTruncated: true,
                            nextByteOffset: absoluteOffset,
                            nextStartLine: currentLine
                        )
                    }
                    content.append(byte)
                    lastSelectedLine = currentLine
                }
                index = page.index(after: index)
            }
            offset += UInt64(page.count)
            if page.isEmpty {
                if pendingStopAfterCarriageReturn {
                    return try sandboxChunkResult(
                        path: displayPath,
                        startLine: startLine,
                        currentLine: currentLine,
                        lastSelectedLine: lastSelectedLine,
                        content: content,
                        totalLines: nil,
                        contentTruncated: pendingStopIsTruncated,
                        nextByteOffset: offset,
                        nextStartLine: currentLine
                    )
                }
                if currentLine >= startLine, completedSelectedLines < resolvedMaxLines {
                    lastSelectedLine = currentLine
                }
                return try sandboxChunkResult(
                    path: displayPath,
                    startLine: startLine,
                    currentLine: currentLine,
                    lastSelectedLine: lastSelectedLine,
                    content: content,
                    totalLines: byteOffset == nil ? currentLine : nil,
                    contentTruncated: false,
                    nextByteOffset: nil,
                    nextStartLine: nil
                )
            }
        }
    }

    private static func sandboxChunkResult(
        path: String,
        startLine: Int,
        currentLine: Int,
        lastSelectedLine: Int?,
        content: Data,
        totalLines: Int?,
        contentTruncated: Bool,
        nextByteOffset: UInt64?,
        nextStartLine: Int?
    ) throws -> SandboxFileChunkReadResult {
        let decoded = try decodeSandboxChunkContent(
            content,
            displayPath: path,
            mayTrimIncompleteSuffix: contentTruncated
        )
        let adjustedNextOffset = nextByteOffset.map { $0 - UInt64(decoded.removedBytes) }
        return SandboxFileChunkReadResult(
            path: path,
            startLine: startLine,
            endLine: lastSelectedLine ?? min(currentLine, startLine - 1),
            totalLines: totalLines,
            hasMore: adjustedNextOffset != nil,
            content: decoded.text,
            contentTruncated: contentTruncated || decoded.removedBytes != 0,
            nextByteOffset: adjustedNextOffset,
            nextStartLine: nextStartLine
        )
    }

    private static func decodeSandboxChunkContent(
        _ data: Data,
        displayPath: String,
        mayTrimIncompleteSuffix: Bool
    ) throws -> (text: String, removedBytes: Int) {
        let maximumTrim = mayTrimIncompleteSuffix ? min(3, data.count) : 0
        for removed in 0 ... maximumTrim {
            let end = data.index(data.endIndex, offsetBy: -removed)
            if let text = String(data: data[..<end], encoding: .utf8) {
                return (text, removed)
            }
        }
        throw SandboxFileToolError.unsupportedEncoding(displayPath)
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
        if sourceURL.standardizedFileURL.path.hasPrefix(destinationURL.standardizedFileURL.path + "/") {
            throw SandboxFileToolError.destinationContainsSource
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
            overwrittenBackupURL = try replaceItemKeepingBackup(
                at: destinationURL,
                with: sourceURL
            )
        } else {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }
        StorageUtility.notifyFilesystemMutation(at: sourceURL)
        StorageUtility.notifyFilesystemMutation(at: destinationURL)

        let backupURLForUndo = overwrittenBackupURL
        pushUndoEntry(
            rootDirectory: rootDirectory,
            operation: "move_sandbox_item",
            rollbackURLs: [sourceURL, destinationURL],
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
        rollbackURLs: [URL],
        discard: @escaping () -> Void = {},
        undo: @escaping () throws -> Void
    ) {
        let entry = SandboxUndoEntry(
            rootPath: rootDirectory.standardizedFileURL.path,
            context: undoContext,
            operation: operation,
            recordedAt: Date(),
            rollbackURLs: rollbackURLs,
            undo: undo,
            discard: discard
        )

        undoLock.lock()
        undoStack.append(entry)
        let unscopedIndices = undoStack.indices.filter { undoStack[$0].context == nil }
        let stale: SandboxUndoEntry?
        if unscopedIndices.count > maxUndoEntries, let first = unscopedIndices.first {
            stale = undoStack.remove(at: first)
        } else {
            stale = nil
        }
        undoLock.unlock()
        stale?.discard()
    }

    private static func reserveUndoEntry(
        for rootPath: String,
        context: SandboxUndoContext?
    ) -> (entry: SandboxUndoEntry, index: Int)? {
        undoLock.lock()
        defer { undoLock.unlock() }
        guard let index = undoStack.lastIndex(where: {
            $0.rootPath == rootPath && $0.context?.runID == context?.runID &&
                $0.context?.mutationID == context?.mutationID
        }) else {
            return nil
        }
        return (undoStack.remove(at: index), index)
    }

    private static func restoreUndoEntry(_ entry: SandboxUndoEntry, at index: Int) {
        undoLock.lock()
        undoStack.insert(entry, at: min(index, undoStack.count))
        undoLock.unlock()
    }

    private static func performTransactionalUndo(_ entry: SandboxUndoEntry) throws {
        let rollback = try prepareRollbackSnapshots(entry.rollbackURLs)
        do {
            try entry.undo()
            discardRollbackSnapshots(rollback)
        } catch {
            let undoError = error
            do {
                try restoreRollbackSnapshots(rollback)
                discardRollbackSnapshots(rollback)
            } catch let rollbackError {
                discardRollbackSnapshots(rollback)
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("撤销文件修改失败（%@），恢复撤销前状态也失败（%@）。", comment: "Sandbox undo and undo rollback failure"),
                        undoError.localizedDescription,
                        rollbackError.localizedDescription
                    )
                )
            }
            throw undoError
        }
    }

    private static func prepareRollbackSnapshots(_ urls: [URL]) throws -> [SandboxUndoRollbackSnapshot] {
        var snapshots: [SandboxUndoRollbackSnapshot] = []
        do {
            for url in urls {
                let standardized = url.standardizedFileURL
                guard !snapshots.contains(where: { $0.targetURL.path == standardized.path }) else { continue }
                let backup: URL?
                if FileManager.default.fileExists(atPath: standardized.path) {
                    backup = try backupRollbackItem(at: standardized)
                } else {
                    backup = nil
                }
                snapshots.append(.init(targetURL: standardized, backupURL: backup))
            }
            return snapshots
        } catch {
            discardRollbackSnapshots(snapshots)
            throw error
        }
    }

    private static func restoreRollbackSnapshots(_ snapshots: [SandboxUndoRollbackSnapshot]) throws {
        for snapshot in snapshots.sorted(by: { $0.targetURL.path.count > $1.targetURL.path.count })
            where FileManager.default.fileExists(atPath: snapshot.targetURL.path) {
            try FileManager.default.removeItem(at: snapshot.targetURL)
        }
        for snapshot in snapshots {
            guard let backupURL = snapshot.backupURL else { continue }
            try FileManager.default.copyItem(at: backupURL, to: snapshot.targetURL)
            StorageUtility.notifyFilesystemMutation(at: snapshot.targetURL)
        }
    }

    private static func discardRollbackSnapshots(_ snapshots: [SandboxUndoRollbackSnapshot]) {
        for backupURL in snapshots.compactMap(\.backupURL) {
            try? FileManager.default.removeItem(at: backupURL)
        }
    }

    private static func backupRollbackItem(at url: URL) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-sandbox-undo-rollback", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backupURL = root.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.copyItem(at: url, to: backupURL)
        return backupURL
    }

    internal static func backupItem(at url: URL) throws -> URL {
        let backupRoot = try backupRootDirectory()
        let backupURL = backupRoot.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.copyItem(at: url, to: backupURL)
        return backupURL
    }

    internal static func replaceItemKeepingBackup(
        at destinationURL: URL,
        with replacementURL: URL,
        replacementOperation: (URL, URL, String) throws -> Void = { destination, replacement, backupName in
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: replacement,
                backupItemName: backupName,
                options: [.withoutDeletingBackupItem]
            )
        }
    ) throws -> URL {
        let backupName = ".etos-replaced-\(UUID().uuidString)"
        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(backupName, isDirectory: false)
        do {
            try replacementOperation(destinationURL, replacementURL, backupName)
            return backupURL
        } catch {
            let replacementError = error
            guard FileManager.default.fileExists(atPath: backupURL.path) else {
                throw replacementError
            }
            do {
                if !FileManager.default.fileExists(atPath: replacementURL.path),
                   FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.moveItem(at: destinationURL, to: replacementURL)
                } else if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: backupURL, to: destinationURL)
            } catch let restoreError {
                throw SandboxFileToolError.writeFailed(
                    String(
                        format: NSLocalizedString("替换目标失败（%@），恢复旧目标也失败（%@）。", comment: "Sandbox replacement and restore failure"),
                        replacementError.localizedDescription,
                        restoreError.localizedDescription
                    )
                )
            }
            throw replacementError
        }
    }

    internal static func copyItemThroughStaging(
        from sourceURL: URL,
        to destinationURL: URL,
        destinationExists: Bool,
        sourceIsDirectory: Bool,
        copyOperation: (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    ) throws -> URL? {
        let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".etos-copy-staging-\(UUID().uuidString)",
            isDirectory: sourceIsDirectory
        )
        defer {
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }
        try copyOperation(sourceURL, stagingURL)
        if destinationExists {
            return try replaceItemKeepingBackup(at: destinationURL, with: stagingURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        return nil
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

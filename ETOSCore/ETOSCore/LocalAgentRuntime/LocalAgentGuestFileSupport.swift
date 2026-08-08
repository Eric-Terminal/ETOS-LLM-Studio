// ============================================================================
// LocalAgentGuestFileSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// Linux guest 文件工具的流式分页、原子复制与精确撤销快照。所有文件数据都
// 通过 iSH 公共 guest API 访问，不把 fakefs 的宿主 data 目录当普通文件修改。
// ============================================================================

import Foundation

protocol LocalAgentGuestFileSystem: Sendable {
    func localAgentStat(path: String, requestID: UInt64) async throws -> LocalLinuxGuestFileInfo
    func localAgentList(path: String, requestID: UInt64, cursor: UInt64, limit: UInt32) async throws -> LocalLinuxGuestDirectoryPage
    func localAgentRead(path: String, requestID: UInt64, offset: UInt64, limit: UInt32) async throws -> LocalLinuxGuestFileReadResult
    func localAgentWrite(path: String, requestID: UInt64, data: Data, mode: UInt32) async throws
    func localAgentCopy(source: String, destination: String, requestID: UInt64) async throws
    func localAgentRemove(path: String, requestID: UInt64, recursive: Bool) async throws
    func localAgentCreateDirectory(path: String, requestID: UInt64, mode: UInt32) async throws
}

extension iSHAppleBridgeAdapter: LocalAgentGuestFileSystem {
    func localAgentStat(path: String, requestID: UInt64) async throws -> LocalLinuxGuestFileInfo {
        try statGuestFile(path: path, requestID: requestID, noFollow: true)
    }

    func localAgentList(
        path: String,
        requestID: UInt64,
        cursor: UInt64,
        limit: UInt32
    ) async throws -> LocalLinuxGuestDirectoryPage {
        try listGuestDirectory(
            path: path,
            requestID: requestID,
            cursor: cursor,
            maximumEntryCount: limit,
            noFollow: true
        )
    }

    func localAgentRead(
        path: String,
        requestID: UInt64,
        offset: UInt64,
        limit: UInt32
    ) async throws -> LocalLinuxGuestFileReadResult {
        try readGuestFile(
            path: path,
            requestID: requestID,
            offset: offset,
            maximumByteCount: limit,
            noFollow: true
        )
    }

    func localAgentWrite(path: String, requestID: UInt64, data: Data, mode: UInt32) async throws {
        try writeGuestFile(path: path, requestID: requestID, data: data, mode: mode, noFollow: true)
    }

    func localAgentCopy(source: String, destination: String, requestID: UInt64) async throws {
        try copyGuestFile(
            path: source,
            destination: destination,
            requestID: requestID,
            noFollow: true
        )
    }

    func localAgentRemove(path: String, requestID: UInt64, recursive: Bool) async throws {
        try removeGuestFile(path: path, requestID: requestID, recursive: recursive, noFollow: true)
    }

    func localAgentCreateDirectory(path: String, requestID: UInt64, mode: UInt32) async throws {
        try createGuestDirectory(
            path: path,
            requestID: requestID,
            mode: mode,
            createParents: true,
            noFollow: true
        )
    }
}

struct LocalAgentGuestTextChunk: Equatable, Sendable {
    let startLine: Int
    let endLine: Int
    let totalLines: Int?
    let hasMore: Bool
    let content: String
    let contentTruncated: Bool
    let nextByteOffset: UInt64?
    let nextStartLine: Int?
}

struct LocalAgentGuestUndoPreparation: Sendable {
    fileprivate struct Snapshot: Sendable {
        let path: String
        let backupPath: String?
    }

    let operation: String
    let recordedAt: Date
    let backupDirectory: String?
    fileprivate let snapshots: [Snapshot]
    let unavailableReason: String?
}

struct LocalAgentGuestUndoResult: Equatable, Sendable {
    let operation: String
    let recordedAt: Date
}

actor LocalAgentGuestFileSupport {
    private enum SnapshotError: Error {
        case unsupportedNode(String)
    }

    private let fileSystem: any LocalAgentGuestFileSystem
    private var requestCounter = UInt64(Date().timeIntervalSince1970 * 1_000_000)

    init(fileSystem: any LocalAgentGuestFileSystem) {
        self.fileSystem = fileSystem
    }

    /// 行数限制约束结构，字节预算约束模型输出；cursor 可继续读取超长单行。
    func readTextChunk(
        path: String,
        startLine: Int,
        maximumLines: Int,
        byteOffset: UInt64? = nil,
        maximumBytes: Int = 1_048_576
    ) async throws -> LocalAgentGuestTextChunk {
        let resolvedStartLine = max(1, startLine)
        let resolvedLineLimit = max(1, maximumLines)
        let resolvedByteLimit = min(1_048_576, max(4, maximumBytes))
        var offset = byteOffset ?? 0
        var currentLine = byteOffset == nil ? 1 : resolvedStartLine
        var completedSelectedLines = 0
        var lastSelectedLine: Int?
        var content = Data()
        content.reserveCapacity(min(resolvedByteLimit, 64 * 1_024))
        var pendingStopAfterCarriageReturn = false
        var pendingStopIsTruncated = false
        var previousWasCarriageReturn = false

        while true {
            let page = try await fileSystem.localAgentRead(
                path: path,
                requestID: nextRequestID(),
                offset: offset,
                limit: 256 * 1_024
            )
            guard !page.data.isEmpty || page.isComplete else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 分块读取没有取得进度。", comment: "Linux chunk read made no progress")
                )
            }

            var index = page.data.startIndex
            while index < page.data.endIndex {
                let byte = page.data[index]
                let absoluteOffset = offset + UInt64(page.data.distance(from: page.data.startIndex, to: index))

                if pendingStopAfterCarriageReturn {
                    if byte == 0x0A {
                        let nextOffset = absoluteOffset + 1
                        return try chunkResult(
                            startLine: resolvedStartLine,
                            currentLine: currentLine,
                            lastSelectedLine: lastSelectedLine,
                            content: content,
                            totalLines: nil,
                            contentTruncated: pendingStopIsTruncated,
                            nextByteOffset: nextOffset,
                            nextStartLine: currentLine
                        )
                    }
                    return try chunkResult(
                        startLine: resolvedStartLine,
                        currentLine: currentLine,
                        lastSelectedLine: lastSelectedLine,
                        content: content,
                        totalLines: nil,
                        contentTruncated: pendingStopIsTruncated,
                        nextByteOffset: absoluteOffset,
                        nextStartLine: currentLine
                    )
                }

                if byte == 0x0A, previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                    index = page.data.index(after: index)
                    continue
                }
                previousWasCarriageReturn = false

                if byte == 0x0A || byte == 0x0D {
                    if currentLine >= resolvedStartLine {
                        lastSelectedLine = currentLine
                        if completedSelectedLines < resolvedLineLimit {
                            completedSelectedLines += 1
                        }
                    }
                    if currentLine < Int.max {
                        currentLine += 1
                    }
                    if completedSelectedLines >= resolvedLineLimit {
                        if byte == 0x0D {
                            pendingStopAfterCarriageReturn = true
                            pendingStopIsTruncated = false
                            previousWasCarriageReturn = true
                            index = page.data.index(after: index)
                            continue
                        }
                        return try chunkResult(
                            startLine: resolvedStartLine,
                            currentLine: currentLine,
                            lastSelectedLine: lastSelectedLine,
                            content: content,
                            totalLines: nil,
                            contentTruncated: false,
                            nextByteOffset: absoluteOffset + 1,
                            nextStartLine: currentLine
                        )
                    }
                    if currentLine > resolvedStartLine {
                        if content.count == resolvedByteLimit {
                            if byte == 0x0D {
                                pendingStopAfterCarriageReturn = true
                                pendingStopIsTruncated = true
                                previousWasCarriageReturn = true
                                index = page.data.index(after: index)
                                continue
                            }
                            return try chunkResult(
                                startLine: resolvedStartLine,
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
                } else if currentLine >= resolvedStartLine {
                    if content.count == resolvedByteLimit {
                        return try chunkResult(
                            startLine: resolvedStartLine,
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
                index = page.data.index(after: index)
            }

            offset += UInt64(page.data.count)
            if page.isComplete {
                if pendingStopAfterCarriageReturn {
                    return try chunkResult(
                        startLine: resolvedStartLine,
                        currentLine: currentLine,
                        lastSelectedLine: lastSelectedLine,
                        content: content,
                        totalLines: nil,
                        contentTruncated: pendingStopIsTruncated,
                        nextByteOffset: offset,
                        nextStartLine: currentLine
                    )
                }
                if currentLine >= resolvedStartLine, completedSelectedLines < resolvedLineLimit {
                    lastSelectedLine = currentLine
                }
                return try chunkResult(
                    startLine: resolvedStartLine,
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

    /// 目录逐页遍历，普通文件交给 iSH 的固定缓冲区原子 copy。
    func copyItem(from source: String, to destination: String) async throws {
        let info = try await fileSystem.localAgentStat(path: source, requestID: nextRequestID())
        do {
            try await copyItem(from: source, to: destination, info: info)
        } catch SnapshotError.unsupportedNode(let path) {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                String(
                    format: NSLocalizedString("Linux 文件复制遇到不支持的特殊节点（%@）。", comment: "Linux copy unsupported special node"),
                    path
                )
            )
        }
    }

    func prepareUndo(
        operation: String,
        paths: [String],
        unavailableReason: String? = nil
    ) async throws -> LocalAgentGuestUndoPreparation {
        let uniquePaths = paths.reduce(into: [String]()) { result, path in
            if !result.contains(path) { result.append(path) }
        }
        let rootReason = uniquePaths.contains("/")
            ? NSLocalizedString("修改 Linux 根目录无法在根目录内部创建安全快照，因此不能自动撤销。", comment: "Linux root mutation undo unavailable")
            : nil
        if let reason = unavailableReason ?? rootReason {
            return unavailablePreparation(operation: operation, paths: uniquePaths, reason: reason)
        }

        let backupDirectory = backupRoot(avoiding: uniquePaths) + "/" + UUID().uuidString.lowercased()
        try await fileSystem.localAgentCreateDirectory(
            path: backupDirectory,
            requestID: nextRequestID(),
            mode: 0o700
        )
        do {
            var snapshots: [LocalAgentGuestUndoPreparation.Snapshot] = []
            for (index, path) in uniquePaths.enumerated() {
                guard let info = try await statIfPresent(path) else {
                    snapshots.append(.init(path: path, backupPath: nil))
                    continue
                }
                let backupPath = backupDirectory + "/" + String(index)
                try await copyItem(from: path, to: backupPath, info: info)
                snapshots.append(.init(path: path, backupPath: backupPath))
            }
            return LocalAgentGuestUndoPreparation(
                operation: operation,
                recordedAt: Date(),
                backupDirectory: backupDirectory,
                snapshots: snapshots,
                unavailableReason: nil
            )
        } catch SnapshotError.unsupportedNode(let path) {
            try? await removeIfPresent(backupDirectory)
            return unavailablePreparation(
                operation: operation,
                paths: uniquePaths,
                reason: String(
                    format: NSLocalizedString("最近一次修改包含无法快照的 Linux 特殊节点（%@），不能自动撤销。", comment: "Linux undo unsupported node"),
                    path
                )
            )
        } catch {
            try? await removeIfPresent(backupDirectory)
            throw error
        }
    }

    /// 撤销前再快照当前状态；原恢复中途失败时，先回到撤销前状态再向上抛错。
    func restore(_ preparation: LocalAgentGuestUndoPreparation) async throws -> LocalAgentGuestUndoResult {
        if let unavailableReason = preparation.unavailableReason {
            throw LocalLinuxRuntimeError.runtimeUnavailable(unavailableReason)
        }
        let rollback = try await prepareUndo(
            operation: "undo_sandbox_mutation_rollback",
            paths: preparation.snapshots.map(\.path)
        )
        if let unavailableReason = rollback.unavailableReason {
            throw LocalLinuxRuntimeError.runtimeUnavailable(unavailableReason)
        }
        do {
            try await restoreSnapshots(preparation)
        } catch {
            let undoError = error
            do {
                try await restoreSnapshots(rollback)
                await discard(rollback)
            } catch let rollbackError {
                await discard(rollback)
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    String(
                        format: NSLocalizedString("撤销 Linux 文件修改失败（%@），恢复撤销前状态也失败（%@）。", comment: "Linux undo and undo rollback failure"),
                        undoError.localizedDescription,
                        rollbackError.localizedDescription
                    )
                )
            }
            throw undoError
        }
        await discard(rollback)
        return LocalAgentGuestUndoResult(
            operation: preparation.operation,
            recordedAt: preparation.recordedAt
        )
    }

    private func restoreSnapshots(_ preparation: LocalAgentGuestUndoPreparation) async throws {
        for snapshot in preparation.snapshots.sorted(by: { $0.path.count > $1.path.count }) {
            try await removeIfPresent(snapshot.path)
        }
        for snapshot in preparation.snapshots {
            guard let backupPath = snapshot.backupPath else { continue }
            try await copyItem(from: backupPath, to: snapshot.path)
        }
    }

    func discard(_ preparation: LocalAgentGuestUndoPreparation) async {
        guard let backupDirectory = preparation.backupDirectory else { return }
        try? await removeIfPresent(backupDirectory)
    }

    private func copyItem(
        from source: String,
        to destination: String,
        info: LocalLinuxGuestFileInfo
    ) async throws {
        if info.isDirectory {
            try await fileSystem.localAgentCreateDirectory(
                path: destination,
                requestID: nextRequestID(),
                mode: info.mode & 0o7777
            )
            var cursor: UInt64 = 0
            repeat {
                let page = try await fileSystem.localAgentList(
                    path: source,
                    requestID: nextRequestID(),
                    cursor: cursor,
                    limit: 256
                )
                for child in page.entries {
                    guard let name = child.name, name != ".", name != ".." else { continue }
                    let childSource = source == "/" ? "/" + name : source + "/" + name
                    let childDestination = destination == "/" ? "/" + name : destination + "/" + name
                    try await copyItem(from: childSource, to: childDestination, info: child)
                }
                cursor = page.isComplete ? 0 : page.nextCursor
            } while cursor != 0
            return
        }
        guard info.isRegularFile else { throw SnapshotError.unsupportedNode(source) }
        try await fileSystem.localAgentCopy(
            source: source,
            destination: destination,
            requestID: nextRequestID()
        )
    }

    private func chunkResult(
        startLine: Int,
        currentLine: Int,
        lastSelectedLine: Int?,
        content: Data,
        totalLines: Int?,
        contentTruncated: Bool,
        nextByteOffset: UInt64?,
        nextStartLine: Int?
    ) throws -> LocalAgentGuestTextChunk {
        let decoded = try decodeChunkContent(content, mayTrimIncompleteSuffix: contentTruncated)
        let adjustedNextOffset = nextByteOffset.map { $0 - UInt64(decoded.removedBytes) }
        return LocalAgentGuestTextChunk(
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

    private func decodeChunkContent(
        _ data: Data,
        mayTrimIncompleteSuffix: Bool
    ) throws -> (text: String, removedBytes: Int) {
        let maximumTrim = mayTrimIncompleteSuffix ? min(3, data.count) : 0
        for removed in 0 ... maximumTrim {
            let end = data.index(data.endIndex, offsetBy: -removed)
            if let text = String(data: data[..<end], encoding: .utf8) {
                return (text, removed)
            }
        }
        throw LocalLinuxRuntimeError.runtimeUnavailable(
            NSLocalizedString("Linux 文件不是有效的 UTF-8 文本。", comment: "Linux chunk invalid UTF-8")
        )
    }

    private func unavailablePreparation(
        operation: String,
        paths: [String],
        reason: String
    ) -> LocalAgentGuestUndoPreparation {
        LocalAgentGuestUndoPreparation(
            operation: operation,
            recordedAt: Date(),
            backupDirectory: nil,
            snapshots: paths.map { .init(path: $0, backupPath: nil) },
            unavailableReason: reason
        )
    }

    private func statIfPresent(_ path: String) async throws -> LocalLinuxGuestFileInfo? {
        do {
            return try await fileSystem.localAgentStat(path: path, requestID: nextRequestID())
        } catch LocalLinuxRuntimeError.bridgeFailure(_, let linuxError) where linuxError == -2 {
            return nil
        }
    }

    private func removeIfPresent(_ path: String) async throws {
        guard let info = try await statIfPresent(path) else { return }
        try await fileSystem.localAgentRemove(
            path: path,
            requestID: nextRequestID(),
            recursive: info.isDirectory
        )
    }

    private func backupRoot(avoiding paths: [String]) -> String {
        let candidates = [
            "/var/tmp/.etos-file-tool-undo",
            "/home/etos/.etos-file-tool-undo",
            "/tmp/.etos-file-tool-undo",
            "/mnt/etos/home/.etos-file-tool-undo"
        ]
        return candidates.first { candidate in
            !paths.contains { path in
                path == "/" || candidate == path || candidate.hasPrefix(path + "/")
            }
        } ?? "/var/tmp/.etos-file-tool-undo"
    }

    private func nextRequestID() -> UInt64 {
        requestCounter &+= 1
        if requestCounter == 0 { requestCounter = 1 }
        return requestCounter
    }
}

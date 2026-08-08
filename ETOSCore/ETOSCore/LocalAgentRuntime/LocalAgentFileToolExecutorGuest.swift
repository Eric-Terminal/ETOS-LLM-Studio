// ============================================================================
// LocalAgentFileToolExecutorGuest.swift
// ============================================================================
// ETOS LLM Studio
//
// Linux guest 文件工具的具体读写、搜索与目录操作；URI 路由、授权和撤销历史
// 留在主 executor，避免把不同职责继续堆进同一个超千行文件。
// ============================================================================

import Foundation

extension LocalAgentFileToolExecutor {
    func executeGuestTool(
        toolName: String,
        arguments: [String: Any],
        paths: [String: String]
    ) async throws -> String {
        switch toolName {
        case AppToolKind.listSandboxDirectory.toolName:
            let path = paths["path"] ?? "/"
            let items = try await listDirectory(path)
            return try encode([
                "path": path,
                "items": items.map(filePayload)
            ])

        case AppToolKind.readSandboxFile.toolName:
            let path = try requiredPath("path", paths: paths)
            let data = try await readFile(path)
            return try encode([
                "path": path,
                "characterCount": String(decoding: data, as: UTF8.self).count,
                "content": String(decoding: data, as: UTF8.self)
            ])

        case AppToolKind.writeSandboxFile.toolName:
            let path = try requiredPath("path", paths: paths)
            let content = try requiredString("content", arguments: arguments)
            let createParents = arguments["create_parent_directories"] as? Bool ?? true
            if createParents { try await createParentDirectory(of: path) }
            try await bridge.writeGuestFile(path: path, requestID: nextRequestID(), data: Data(content.utf8))
            return try encode([
                "path": path,
                "size": Data(content.utf8).count,
                "createdParentDirectories": createParents
            ])

        case AppToolKind.searchSandboxFiles.toolName:
            let path = paths["path"] ?? "/"
            let results = try await search(
                path: path,
                nameQuery: arguments["name_query"] as? String,
                contentQuery: arguments["content_query"] as? String,
                maximumResults: min(200, max(1, arguments["max_results"] as? Int ?? 20)),
                includeDirectories: arguments["include_directories"] as? Bool ?? false,
                caseSensitive: arguments["case_sensitive"] as? Bool ?? false
            )
            return try encode(["path": path, "count": results.count, "items": results])

        case AppToolKind.readSandboxFileChunk.toolName:
            let path = try requiredPath("path", paths: paths)
            let startLine = max(1, arguments["start_line"] as? Int ?? 1)
            let maximumLines = min(1_000, max(1, arguments["max_lines"] as? Int ?? 200))
            let maximumBytes = min(1_048_576, max(1, arguments["max_bytes"] as? Int ?? 262_144))
            let byteOffset = (arguments["byte_offset"] as? NSNumber)?.uint64Value
            let chunk = try await guestFileSupport.readTextChunk(
                path: path,
                startLine: startLine,
                maximumLines: maximumLines,
                byteOffset: byteOffset,
                maximumBytes: maximumBytes
            )
            return try encode([
                "path": path,
                "startLine": chunk.startLine,
                "endLine": chunk.endLine,
                "totalLines": chunk.totalLines.map { $0 as Any } ?? NSNull(),
                "hasMore": chunk.hasMore,
                "content": chunk.content,
                "contentTruncated": chunk.contentTruncated,
                "nextByteOffset": chunk.nextByteOffset.map { $0 as Any } ?? NSNull(),
                "nextStartLine": chunk.nextStartLine.map { $0 as Any } ?? NSNull()
            ])

        case AppToolKind.moveSandboxItem.toolName:
            let source = try requiredPath("source_path", paths: paths)
            let destination = try requiredPath("destination_path", paths: paths)
            let info = try await bridge.statGuestFile(path: source, requestID: nextRequestID(), noFollow: true)
            let overwroteDestination = try await prepareDestination(
                destination,
                arguments: arguments,
                removeExisting: false
            )
            try await bridge.renameGuestFile(path: source, destination: destination, requestID: nextRequestID(), noFollow: true)
            return try encode([
                "sourcePath": source,
                "destinationPath": destination,
                "wasDirectory": info.isDirectory,
                "createdParentDirectories": arguments["create_parent_directories"] as? Bool ?? true,
                "overwroteDestination": overwroteDestination
            ])

        case AppToolKind.copySandboxItem.toolName:
            let source = try requiredPath("source_path", paths: paths)
            let destination = try requiredPath("destination_path", paths: paths)
            let info = try await bridge.statGuestFile(path: source, requestID: nextRequestID(), noFollow: true)
            let overwroteDestination = try await prepareDestination(
                destination,
                arguments: arguments,
                removeExisting: info.isDirectory
            )
            try await guestFileSupport.copyItem(from: source, to: destination)
            return try encode([
                "sourcePath": source,
                "destinationPath": destination,
                "wasDirectory": info.isDirectory,
                "createdParentDirectories": arguments["create_parent_directories"] as? Bool ?? true,
                "overwroteDestination": overwroteDestination
            ])

        case AppToolKind.createSandboxDirectory.toolName:
            let path = try requiredPath("path", paths: paths)
            try await bridge.createGuestDirectory(
                path: path,
                requestID: nextRequestID(),
                createParents: arguments["create_parent_directories"] as? Bool ?? true
            )
            return try encode(["path": path, "created": true])

        case AppToolKind.batchEditSandboxFile.toolName:
            let path = try requiredPath("path", paths: paths)
            guard let rules = arguments["rules"] as? [[String: Any]], !rules.isEmpty else {
                throw invalidArguments("rules")
            }
            let replaceAll = arguments["replace_all"] as? Bool ?? false
            let ignoreMissing = arguments["ignore_missing"] as? Bool ?? false
            var content = String(decoding: try await readFile(path), as: UTF8.self)
            var replacements = 0
            var applied = 0
            for rule in rules {
                guard let old = rule["old_text"] as? String, !old.isEmpty,
                      let new = rule["new_text"] as? String else { throw invalidArguments("rules") }
                let count = content.components(separatedBy: old).count - 1
                if count == 0 {
                    if ignoreMissing { continue }
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 文件中找不到要替换的文本。", comment: "Linux edit missing text error")
                    )
                }
                if !replaceAll, count > 1 {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("Linux 文件中的替换文本不唯一。", comment: "Linux edit ambiguous text error")
                    )
                }
                content = replaceAll
                    ? content.replacingOccurrences(of: old, with: new)
                    : replacingFirst(old, with: new, in: content)
                replacements += replaceAll ? count : 1
                applied += 1
            }
            try await bridge.writeGuestFile(path: path, requestID: nextRequestID(), data: Data(content.utf8))
            return try encode(["path": path, "replacements": replacements, "rulesApplied": applied, "size": Data(content.utf8).count])

        case AppToolKind.diffSandboxFile.toolName:
            let path = try requiredPath("path", paths: paths)
            let current = String(decoding: try await readFile(path), as: UTF8.self)
            let updated = try requiredString("updated_content", arguments: arguments)
            return simpleDiff(path: path, current: current, updated: updated)

        case AppToolKind.editSandboxFile.toolName:
            let path = try requiredPath("path", paths: paths)
            let old = try requiredString("old_text", arguments: arguments)
            let new = try requiredString("new_text", arguments: arguments)
            let replaceAll = arguments["replace_all"] as? Bool ?? false
            var content = String(decoding: try await readFile(path), as: UTF8.self)
            guard !old.isEmpty else { throw invalidArguments("old_text") }
            let count = content.components(separatedBy: old).count - 1
            guard count > 0 else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 文件中找不到要替换的文本。", comment: "Linux edit missing text error")
                )
            }
            guard replaceAll || count == 1 else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 文件中的替换文本不唯一。", comment: "Linux edit ambiguous text error")
                )
            }
            content = replaceAll
                ? content.replacingOccurrences(of: old, with: new)
                : replacingFirst(old, with: new, in: content)
            try await bridge.writeGuestFile(path: path, requestID: nextRequestID(), data: Data(content.utf8))
            return try encode(["path": path, "replacements": replaceAll ? count : 1, "size": Data(content.utf8).count])

        case AppToolKind.deleteSandboxItem.toolName:
            let path = try requiredPath("path", paths: paths)
            let info = try await bridge.statGuestFile(path: path, requestID: nextRequestID(), noFollow: true)
            try await bridge.removeGuestFile(path: path, requestID: nextRequestID(), recursive: info.isDirectory, noFollow: true)
            return try encode(["path": path, "wasDirectory": info.isDirectory])

        default:
            throw AppToolExecutionError.unknownTool
        }
    }

    func listDirectory(_ path: String) async throws -> [LocalLinuxGuestFileInfo] {
        var cursor: UInt64 = 0
        var values: [LocalLinuxGuestFileInfo] = []
        repeat {
            let page = try await bridge.listGuestDirectory(
                path: path,
                requestID: nextRequestID(),
                cursor: cursor,
                maximumEntryCount: 256,
                noFollow: true
            )
            values.append(contentsOf: page.entries.filter { $0.name != "." && $0.name != ".." })
            cursor = page.isComplete ? 0 : page.nextCursor
        } while cursor != 0 && values.count < 10_000
        return values
    }

    func readFile(_ path: String, maximumBytes: Int = 8 * 1_024 * 1_024) async throws -> Data {
        var result = Data()
        var offset: UInt64 = 0
        while result.count < maximumBytes {
            let read = try await bridge.readGuestFile(
                path: path,
                requestID: nextRequestID(),
                offset: offset,
                maximumByteCount: UInt32(min(256 * 1_024, maximumBytes - result.count)),
                noFollow: true
            )
            result.append(read.data)
            offset += UInt64(read.data.count)
            if read.isComplete { return result }
            guard !read.data.isEmpty else { break }
        }
        throw LocalLinuxRuntimeError.runtimeUnavailable(
            NSLocalizedString("Linux 文件超过单次工具读取上限，请使用分块读取。", comment: "Linux file read limit error")
        )
    }

    func search(
        path: String,
        nameQuery: String?,
        contentQuery: String?,
        maximumResults: Int,
        includeDirectories: Bool,
        caseSensitive: Bool
    ) async throws -> [[String: Any]] {
        var pending = [path]
        var results: [[String: Any]] = []
        while let directory = pending.popLast(), results.count < maximumResults, pending.count < 10_000 {
            for info in try await listDirectory(directory) {
                guard let name = info.name else { continue }
                let itemPath = directory == "/" ? "/\(name)" : "\(directory)/\(name)"
                if info.isDirectory { pending.append(itemPath) }
                let matchedName = matches(name, query: nameQuery, caseSensitive: caseSensitive)
                var matchedContent = false
                if info.isRegularFile, let contentQuery, !contentQuery.isEmpty, info.size <= 1_048_576,
                   let data = try? await readFile(itemPath, maximumBytes: 1_048_577) {
                    matchedContent = matches(String(decoding: data, as: UTF8.self), query: contentQuery, caseSensitive: caseSensitive)
                }
                if (info.isDirectory ? includeDirectories : true), matchedName || matchedContent {
                    var payload = filePayload(info)
                    payload["path"] = itemPath
                    payload["matchedByName"] = matchedName
                    payload["matchedByContent"] = matchedContent
                    results.append(payload)
                    if results.count == maximumResults { break }
                }
            }
        }
        return results
    }

    func matches(_ value: String, query: String?, caseSensitive: Bool) -> Bool {
        guard let query, !query.isEmpty else { return false }
        if caseSensitive { return value.contains(query) }
        return value.localizedCaseInsensitiveContains(query)
    }

    func prepareDestination(
        _ path: String,
        arguments: [String: Any],
        removeExisting: Bool
    ) async throws -> Bool {
        if arguments["create_parent_directories"] as? Bool ?? true { try await createParentDirectory(of: path) }
        if let _ = try? await bridge.statGuestFile(path: path, requestID: nextRequestID(), noFollow: true) {
            guard arguments["overwrite"] as? Bool == true else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 目标路径已经存在。", comment: "Linux destination exists error")
                )
            }
            if removeExisting {
                try await bridge.removeGuestFile(path: path, requestID: nextRequestID(), recursive: true, noFollow: true)
            }
            return true
        }
        return false
    }

    func createParentDirectory(of path: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return }
        try await bridge.createGuestDirectory(path: parent, requestID: nextRequestID(), createParents: true, noFollow: true)
    }

    func filePayload(_ info: LocalLinuxGuestFileInfo) -> [String: Any] {
        [
            "name": info.name ?? "",
            "isDirectory": info.isDirectory,
            "isSymbolicLink": info.isSymbolicLink,
            "size": info.size,
            "modifiedAt": ISO8601DateFormatter().string(from: info.modificationTime)
        ]
    }

}

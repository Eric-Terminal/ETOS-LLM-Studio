// ============================================================================
// LocalAgentFileToolExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// 复用现有文件工具名称，并按 URI 路由到 Documents、Linux guest 或公开挂载。
// Linux 路径始终经过 iSH guest API，不能直接修改 fakefs 的宿主 data 目录。
// ============================================================================

import Foundation

public actor LocalAgentFileToolExecutor {
    public static let shared = LocalAgentFileToolExecutor()

    private enum Backend: Equatable {
        case app
        case linux
        case mount(UUID)

        var requiresLinux: Bool {
            switch self {
            case .app: return false
            case .linux, .mount: return true
            }
        }
    }

    private struct RoutedPath: Equatable {
        let backend: Backend
        let original: String
        let path: String
    }

    private struct TrustedContext {
        let sessionID: UUID
        let runID: UUID
        let triggeringMessageID: UUID?
        let toolCallID: String
        let selectedMCPServerIDs: [UUID]
    }

    private let bridge: iSHAppleBridgeAdapter
    private let runtime: LocalLinuxRuntimeController
    private let contextManager: LocalAgentRuntimeContextManager
    private var requestCounter = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    private var lastMutationBackendByRunID: [UUID: Backend] = [:]

    public init(
        bridge: iSHAppleBridgeAdapter = .shared,
        runtime: LocalLinuxRuntimeController = .shared,
        contextManager: LocalAgentRuntimeContextManager = .shared
    ) {
        self.bridge = bridge
        self.runtime = runtime
        self.contextManager = contextManager
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        var arguments = try decode(argumentsJSON)
        let trustedContext = removeTrustedContext(from: &arguments)
        let routedPaths = try pathArguments(in: arguments).map { key, value in
            (key, try route(value))
        }

        if toolName == AppToolKind.undoSandboxMutation.toolName,
           let runID = trustedContext?.runID,
           let backend = lastMutationBackendByRunID[runID],
           backend.requiresLinux {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("最近一次文件修改发生在 Linux guest；该后端没有隐式全局撤销记录，请使用明确的反向编辑。", comment: "Linux file undo unavailable error")
            )
        }

        guard routedPaths.contains(where: { $0.1.backend.requiresLinux }) else {
            for (key, routed) in routedPaths where routed.backend == .app {
                arguments[key] = routed.path
            }
            let result = try await executeAppTool(toolName: toolName, arguments: arguments)
            if isMutatingFileTool(toolName), let runID = trustedContext?.runID {
                lastMutationBackendByRunID[runID] = .app
            }
            return result
        }

        guard let trustedContext else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 文件 URI 只能在启用本地 Linux 的 Agent Run 中使用。", comment: "Linux file URI requires Agent context")
            )
        }
        guard !routedPaths.contains(where: { $0.1.backend == .app }) else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("一次移动或复制不能跨越应用沙盒与 Linux 文件系统。", comment: "Cross backend file operation error")
            )
        }

        let frozen = try await contextManager.beginRun(
            sessionID: trustedContext.sessionID,
            triggeringMessageID: trustedContext.triggeringMessageID,
            toolCallID: trustedContext.toolCallID,
            runID: trustedContext.runID,
            selectedMCPServerIDs: trustedContext.selectedMCPServerIDs
        ).context
        _ = try await runtime.ensureReady(trigger: .guestFileBrowser)
        let guestPaths = try Dictionary(uniqueKeysWithValues: routedPaths.map { key, routed in
            (key, try guestPath(for: routed, context: frozen))
        })
        try await authorizeMountedWrites(
            toolName: toolName,
            arguments: arguments,
            routedPaths: routedPaths,
            guestPaths: guestPaths,
            context: trustedContext
        )
        let result = try await executeGuestTool(toolName: toolName, arguments: arguments, paths: guestPaths)
        if toolName == AppToolKind.deleteSandboxItem.toolName,
           let deletedPath = guestPaths["path"],
           isCriticalSystemPath(deletedPath) {
            try await runtime.markSystemDamaged(
                reason: NSLocalizedString("Agent 删除了关键 Linux 系统路径。重新打开 App 后会从内置系统恢复。", comment: "Agent deleted critical Linux system path")
            )
        }
        if isMutatingFileTool(toolName), let firstBackend = routedPaths.first?.1.backend {
            lastMutationBackendByRunID[trustedContext.runID] = firstBackend
        }
        return result
    }

    private func authorizeMountedWrites(
        toolName: String,
        arguments: [String: Any],
        routedPaths: [(String, RoutedPath)],
        guestPaths: [String: String],
        context: TrustedContext
    ) async throws {
        let mutatingTools: Set<String> = [
            AppToolKind.writeSandboxFile.toolName,
            AppToolKind.moveSandboxItem.toolName,
            AppToolKind.copySandboxItem.toolName,
            AppToolKind.createSandboxDirectory.toolName,
            AppToolKind.batchEditSandboxFile.toolName,
            AppToolKind.editSandboxFile.toolName,
            AppToolKind.deleteSandboxItem.toolName
        ]
        guard mutatingTools.contains(toolName) else { return }

        let mountRecords = Dictionary(uniqueKeysWithValues: Persistence.loadLocalLinuxMounts().map { ($0.id, $0) })
        var writableMounts = Set(routedPaths.compactMap { _, routed -> UUID? in
            guard case .mount(let id) = routed.backend,
                  ![LocalLinuxMountManager.homeMountID,
                    LocalLinuxMountManager.workspaceMountID,
                    LocalLinuxMountManager.iCloudMountID].contains(id),
                  let record = mountRecords[id],
                  record.access == .readWrite else {
                return nil
            }
            return id
        })
        if toolName == AppToolKind.deleteSandboxItem.toolName,
           guestPaths["path"] == "/" {
            for record in mountRecords.values where
                record.access == .readWrite &&
                record.isEnabled &&
                record.authorizationState == .available &&
                ![LocalLinuxMountManager.homeMountID,
                  LocalLinuxMountManager.workspaceMountID].contains(record.id) {
                writableMounts.insert(record.id)
            }
        }
        for mountID in writableMounts.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let record = mountRecords[mountID] else { continue }
            var affectedPaths = routedPaths.compactMap { key, routed -> String? in
                guard routed.backend == .mount(mountID) else { return nil }
                return guestPaths[key]
            }
            if affectedPaths.isEmpty, guestPaths["path"] == "/" {
                affectedPaths = [record.guestPath]
            }
            let details = try encode([
                "operation": toolName,
                "mount_id": mountID.uuidString,
                "mount_name": record.displayName,
                "guest_paths": affectedPaths,
                "change_preview": await mutationPreview(
                    toolName: toolName,
                    arguments: arguments,
                    guestPaths: guestPaths
                )
            ])
            let decision = await ToolPermissionCenter.shared.requestPermission(
                toolName: "local_linux.mount.write.\(mountID.uuidString.lowercased())",
                displayName: String(
                    format: NSLocalizedString("写入外部挂载：%@", comment: "External Linux mount write approval title"),
                    record.displayName
                ),
                arguments: details,
                sourceSessionID: context.sessionID,
                toolCallID: context.toolCallID
            )
            let wasDenied: Bool
            switch decision {
            case .deny, .supplement:
                wasDenied = true
            case .allowOnce, .allowForTool, .allowAll:
                wasDenied = false
            }
            _ = Persistence.saveLocalLinuxAudit(
                LocalLinuxAuditRecord(
                    sessionID: context.sessionID,
                    runID: context.runID,
                    jobID: nil,
                    action: toolName,
                    decision: wasDenied ? "denied" : "user_approved",
                    scope: "mount_write",
                    matchedRuleID: nil,
                    redactedSummary: "mount=\(mountID.uuidString), paths=\(affectedPaths.joined(separator: ", "))",
                    executorDeviceID: UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
                )
            )
            if wasDenied {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("用户未允许写入这个外部 Linux 挂载。", comment: "External Linux mount write denied")
                )
            }
        }
    }

    private func isMutatingFileTool(_ toolName: String) -> Bool {
        [
            AppToolKind.writeSandboxFile.toolName,
            AppToolKind.moveSandboxItem.toolName,
            AppToolKind.copySandboxItem.toolName,
            AppToolKind.createSandboxDirectory.toolName,
            AppToolKind.batchEditSandboxFile.toolName,
            AppToolKind.editSandboxFile.toolName,
            AppToolKind.deleteSandboxItem.toolName
        ].contains(toolName)
    }

    private func mutationPreview(
        toolName: String,
        arguments: [String: Any],
        guestPaths: [String: String]
    ) async -> String {
        let path = guestPaths["path"]
        switch toolName {
        case AppToolKind.writeSandboxFile.toolName:
            guard let path, let updated = arguments["content"] as? String else { return toolName }
            return simpleDiff(path: path, current: await previewText(path), updated: limitedPreview(updated))
        case AppToolKind.editSandboxFile.toolName:
            guard let path,
                  let old = arguments["old_text"] as? String,
                  let new = arguments["new_text"] as? String else { return toolName }
            let current = await previewText(path)
            let updated = (arguments["replace_all"] as? Bool ?? false)
                ? current.replacingOccurrences(of: old, with: new)
                : replacingFirst(old, with: new, in: current)
            return simpleDiff(path: path, current: current, updated: limitedPreview(updated))
        case AppToolKind.batchEditSandboxFile.toolName:
            guard let path, let rules = arguments["rules"] as? [[String: Any]] else { return toolName }
            let current = await previewText(path)
            var updated = current
            for rule in rules {
                guard let old = rule["old_text"] as? String,
                      let new = rule["new_text"] as? String else { continue }
                updated = (arguments["replace_all"] as? Bool ?? false)
                    ? updated.replacingOccurrences(of: old, with: new)
                    : replacingFirst(old, with: new, in: updated)
            }
            return simpleDiff(path: path, current: current, updated: limitedPreview(updated))
        case AppToolKind.deleteSandboxItem.toolName:
            guard let path else { return toolName }
            let preview = await previewText(path)
            return String(
                format: NSLocalizedString("删除 %@\n%@", comment: "External mount delete preview"),
                path,
                preview
            )
        case AppToolKind.moveSandboxItem.toolName:
            return String(
                format: NSLocalizedString("移动 %@ → %@", comment: "External mount move preview"),
                guestPaths["source_path"] ?? "?",
                guestPaths["destination_path"] ?? "?"
            )
        case AppToolKind.copySandboxItem.toolName:
            return String(
                format: NSLocalizedString("复制 %@ → %@", comment: "External mount copy preview"),
                guestPaths["source_path"] ?? "?",
                guestPaths["destination_path"] ?? "?"
            )
        case AppToolKind.createSandboxDirectory.toolName:
            return String(
                format: NSLocalizedString("创建目录 %@", comment: "External mount mkdir preview"),
                path ?? "?"
            )
        default:
            return toolName
        }
    }

    private func previewText(_ path: String) async -> String {
        do {
            let info = try await bridge.statGuestFile(path: path, requestID: nextRequestID(), noFollow: true)
            guard info.isRegularFile else {
                return String(
                    format: NSLocalizedString("现有项目不是普通文件（%llu 字节）", comment: "External mount non-regular preview"),
                    info.size
                )
            }
            let read = try await bridge.readGuestFile(
                path: path,
                requestID: nextRequestID(),
                offset: 0,
                maximumByteCount: 32 * 1_024,
                noFollow: true
            )
            if read.data.contains(0) {
                return String(
                    format: NSLocalizedString("现有二进制文件（%llu 字节）", comment: "External mount binary preview"),
                    read.totalSize
                )
            }
            var text = String(decoding: read.data, as: UTF8.self)
            if !read.isComplete {
                text.append(NSLocalizedString("\n[预览已截断]", comment: "External mount preview truncated"))
            }
            return text
        } catch {
            return NSLocalizedString("[目标当前不存在]", comment: "External mount target missing preview")
        }
    }

    private func limitedPreview(_ text: String) -> String {
        guard text.utf8.count > 32 * 1_024 else { return text }
        let index = text.utf8.index(text.utf8.startIndex, offsetBy: 32 * 1_024)
        return String(decoding: text.utf8[..<index], as: UTF8.self)
            + NSLocalizedString("\n[预览已截断]", comment: "External mount preview truncated")
    }

    private func executeAppTool(toolName: String, arguments: [String: Any]) async throws -> String {
        try await AppToolManager.shared.executeToolForBuiltInMCP(
            toolName: toolName,
            argumentsJSON: try encode(arguments)
        )
    }

    private func executeGuestTool(
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
            let content = String(decoding: try await readFile(path), as: UTF8.self)
            let lines = content.components(separatedBy: .newlines)
            let startLine = max(1, arguments["start_line"] as? Int ?? 1)
            let maximumLines = min(1_000, max(1, arguments["max_lines"] as? Int ?? 200))
            let startIndex = min(lines.count, startLine - 1)
            let endIndex = min(lines.count, startIndex + maximumLines)
            return try encode([
                "path": path,
                "startLine": startLine,
                "endLine": endIndex,
                "totalLines": lines.count,
                "hasMore": endIndex < lines.count,
                "content": lines[startIndex ..< endIndex].joined(separator: "\n")
            ])

        case AppToolKind.moveSandboxItem.toolName:
            let source = try requiredPath("source_path", paths: paths)
            let destination = try requiredPath("destination_path", paths: paths)
            try await prepareDestination(destination, arguments: arguments)
            let info = try await bridge.statGuestFile(path: source, requestID: nextRequestID(), noFollow: true)
            try await bridge.renameGuestFile(path: source, destination: destination, requestID: nextRequestID(), noFollow: true)
            return try encode([
                "sourcePath": source,
                "destinationPath": destination,
                "wasDirectory": info.isDirectory,
                "createdParentDirectories": arguments["create_parent_directories"] as? Bool ?? true,
                "overwroteDestination": arguments["overwrite"] as? Bool ?? false
            ])

        case AppToolKind.copySandboxItem.toolName:
            let source = try requiredPath("source_path", paths: paths)
            let destination = try requiredPath("destination_path", paths: paths)
            try await prepareDestination(destination, arguments: arguments)
            let info = try await bridge.statGuestFile(path: source, requestID: nextRequestID(), noFollow: true)
            try await copyGuestItem(from: source, to: destination, info: info)
            return try encode([
                "sourcePath": source,
                "destinationPath": destination,
                "wasDirectory": info.isDirectory,
                "createdParentDirectories": arguments["create_parent_directories"] as? Bool ?? true,
                "overwroteDestination": arguments["overwrite"] as? Bool ?? false
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

        case AppToolKind.undoSandboxMutation.toolName:
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux guest 修改没有隐式全局撤销记录；请使用明确的反向编辑，或在终端中恢复。", comment: "Linux file undo unavailable error")
            )

        default:
            throw AppToolExecutionError.unknownTool
        }
    }

    private func route(_ rawPath: String) throws -> RoutedPath {
        let value = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("linux://") {
            return RoutedPath(backend: .linux, original: rawPath, path: try normalizedGuestPath(String(value.dropFirst("linux://".count))))
        }
        if value.hasPrefix("mount://") {
            let remainder = String(value.dropFirst("mount://".count))
            let parts = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawID = parts.first, let id = UUID(uuidString: String(rawID)) else {
                throw LocalLinuxRuntimeError.invalidPath(rawPath)
            }
            let relativePath = parts.count > 1 ? String(parts[1]) : ""
            return RoutedPath(backend: .mount(id), original: rawPath, path: try normalizedGuestPath("/" + relativePath))
        }
        if value.hasPrefix("app://") {
            let relative = String(value.dropFirst("app://".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return RoutedPath(backend: .app, original: rawPath, path: relative)
        }
        return RoutedPath(backend: .app, original: rawPath, path: rawPath)
    }

    private func guestPath(for routed: RoutedPath, context: AgentRuntimeContext) throws -> String {
        switch routed.backend {
        case .linux:
            return routed.path
        case .app:
            throw LocalLinuxRuntimeError.invalidPath(routed.original)
        case .mount(let id):
            let base: String
            switch id {
            case LocalLinuxMountManager.homeMountID:
                base = LocalLinuxMountManager.homeMountGuestPath
            case LocalLinuxMountManager.workspaceMountID:
                base = LocalLinuxMountManager.workspaceMountGuestPath
            case LocalLinuxMountManager.sharedMountID:
                base = LocalLinuxMountManager.sharedMountGuestPath
            case LocalLinuxMountManager.iCloudMountID:
                base = LocalLinuxMountManager.iCloudGuestPath
            default:
                guard context.mountIDs.contains(id),
                      let record = Persistence.loadLocalLinuxMounts().first(where: { $0.id == id && $0.isEnabled }) else {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(
                        NSLocalizedString("该挂载不属于当前 Agent Run，或需要重新授权。", comment: "Mount missing from Agent context error")
                    )
                }
                base = record.guestPath
            }
            return routed.path == "/" ? base : base + routed.path
        }
    }

    private func normalizedGuestPath(_ rawPath: String) throws -> String {
        let withSlash = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
        let normalized = (withSlash as NSString).standardizingPath
        guard normalized.hasPrefix("/"), !normalized.contains("\0") else {
            throw LocalLinuxRuntimeError.invalidPath(rawPath)
        }
        return normalized
    }

    private func pathArguments(in arguments: [String: Any]) throws -> [(String, String)] {
        let keys = ["path", "source_path", "destination_path"]
        return keys.compactMap { key in
            guard let value = arguments[key] else { return nil }
            guard let path = value as? String else { return (key, "") }
            return (key, path)
        }
    }

    private func removeTrustedContext(from arguments: inout [String: Any]) -> TrustedContext? {
        let sessionID = (arguments.removeValue(forKey: MCPBuiltInAppToolServer.conversationSourceSessionIDArgument) as? String)
            .flatMap(UUID.init(uuidString:))
        let runID = (arguments.removeValue(forKey: MCPBuiltInAppToolServer.localAgentRunIDArgument) as? String)
            .flatMap(UUID.init(uuidString:))
        let triggeringMessageID = (arguments.removeValue(forKey: MCPBuiltInAppToolServer.localAgentTriggeringMessageIDArgument) as? String)
            .flatMap(UUID.init(uuidString:))
        let toolCallID = arguments.removeValue(forKey: MCPBuiltInAppToolServer.conversationToolCallIDArgument) as? String
        let selectedIDs = (arguments.removeValue(forKey: MCPBuiltInAppToolServer.localAgentSelectedMCPServerIDsArgument) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
        guard let sessionID, let runID, let toolCallID, !toolCallID.isEmpty else { return nil }
        return TrustedContext(
            sessionID: sessionID,
            runID: runID,
            triggeringMessageID: triggeringMessageID,
            toolCallID: toolCallID,
            selectedMCPServerIDs: selectedIDs
        )
    }

    private func listDirectory(_ path: String) async throws -> [LocalLinuxGuestFileInfo] {
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

    private func readFile(_ path: String, maximumBytes: Int = 8 * 1_024 * 1_024) async throws -> Data {
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

    private func search(
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

    private func matches(_ value: String, query: String?, caseSensitive: Bool) -> Bool {
        guard let query, !query.isEmpty else { return false }
        if caseSensitive { return value.contains(query) }
        return value.localizedCaseInsensitiveContains(query)
    }

    private func isCriticalSystemPath(_ path: String) -> Bool {
        ["/", "/bin", "/etc", "/lib", "/sbin", "/usr"].contains(path)
    }

    private func prepareDestination(_ path: String, arguments: [String: Any]) async throws {
        if arguments["create_parent_directories"] as? Bool ?? true { try await createParentDirectory(of: path) }
        if let _ = try? await bridge.statGuestFile(path: path, requestID: nextRequestID(), noFollow: true) {
            guard arguments["overwrite"] as? Bool == true else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("Linux 目标路径已经存在。", comment: "Linux destination exists error")
                )
            }
            try await bridge.removeGuestFile(path: path, requestID: nextRequestID(), recursive: true, noFollow: true)
        }
    }

    private func createParentDirectory(of path: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return }
        try await bridge.createGuestDirectory(path: parent, requestID: nextRequestID(), createParents: true, noFollow: true)
    }

    private func copyGuestItem(from source: String, to destination: String, info: LocalLinuxGuestFileInfo) async throws {
        if info.isDirectory {
            try await bridge.createGuestDirectory(path: destination, requestID: nextRequestID(), createParents: true, noFollow: true)
            for child in try await listDirectory(source) {
                guard let name = child.name else { continue }
                try await copyGuestItem(from: source + "/" + name, to: destination + "/" + name, info: child)
            }
            return
        }
        guard info.isRegularFile else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("文件工具暂不复制 Linux 符号链接或设备节点。", comment: "Linux special file copy error")
            )
        }
        let data = try await readFile(source)
        try await bridge.writeGuestFile(path: destination, requestID: nextRequestID(), data: data)
    }

    private func filePayload(_ info: LocalLinuxGuestFileInfo) -> [String: Any] {
        [
            "name": info.name ?? "",
            "isDirectory": info.isDirectory,
            "isSymbolicLink": info.isSymbolicLink,
            "size": info.size,
            "modifiedAt": ISO8601DateFormatter().string(from: info.modificationTime)
        ]
    }

    private func simpleDiff(path: String, current: String, updated: String) -> String {
        if current == updated { return "--- \(path)\n+++ \(path)\n" }
        return "--- \(path)\n+++ \(path)\n@@ -1 +1 @@\n-\(current)\n+\(updated)"
    }

    private func replacingFirst(_ old: String, with new: String, in content: String) -> String {
        guard let range = content.range(of: old) else { return content }
        var result = content
        result.replaceSubrange(range, with: new)
        return result
    }

    private func requiredPath(_ key: String, paths: [String: String]) throws -> String {
        guard let value = paths[key], !value.isEmpty else { throw invalidArguments(key) }
        return value
    }

    private func requiredString(_ key: String, arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else { throw invalidArguments(key) }
        return value
    }

    private func invalidArguments(_ key: String) -> AppToolExecutionError {
        .invalidArguments(
            String(
                format: NSLocalizedString("错误：文件工具缺少或无法解析参数 %@。", comment: "Local file tool invalid argument"),
                key
            )
        )
    }

    private func decode(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidArguments("JSON")
        }
        return object
    }

    private func encode(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else { throw invalidArguments("JSON") }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else { throw invalidArguments("JSON") }
        return string
    }

    private func nextRequestID() -> UInt64 {
        requestCounter &+= 1
        if requestCounter == 0 { requestCounter = 1 }
        return requestCounter
    }
}

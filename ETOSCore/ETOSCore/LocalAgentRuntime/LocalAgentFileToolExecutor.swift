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

    enum Backend: Equatable {
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

    struct RoutedPath: Equatable {
        let backend: Backend
        let original: String
        let path: String
    }

    struct TrustedContext: Sendable {
        let sessionID: UUID
        let runID: UUID
        let triggeringMessageID: UUID?
        let toolCallID: String
        let selectedMCPServerIDs: [UUID]
    }

    struct MountedTarget: Equatable, Sendable {
        let id: UUID
        let guestPaths: [String]
    }

    private enum MutationPayload: Sendable {
        case app(mutationID: UUID)
        case guest(preparation: LocalAgentGuestUndoPreparation, mounts: [MountedTarget])
    }

    private struct MutationEntry: Sendable {
        let id: UUID
        let operation: String
        let payload: MutationPayload
    }

    let bridge: iSHAppleBridgeAdapter
    private let runtime: LocalLinuxRuntimeController
    private let contextManager: LocalAgentRuntimeContextManager
    private let mountManager: LocalLinuxMountManager
    private let trustedRunValidator: @Sendable (UUID, UUID) throws -> Void
    let guestFileSupport: LocalAgentGuestFileSupport
    var requestCounter = UInt64(Date().timeIntervalSince1970 * 1_000_000)
    private var mutationsByRunID: [UUID: [MutationEntry]] = [:]
    private var activeRunOperations = Set<UUID>()
    private var runOperationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private let maximumUndoEntriesPerRun = 64

    public init(
        bridge: iSHAppleBridgeAdapter = .shared,
        runtime: LocalLinuxRuntimeController = .shared,
        contextManager: LocalAgentRuntimeContextManager = .shared,
        mountManager: LocalLinuxMountManager = .shared
    ) {
        self.bridge = bridge
        self.runtime = runtime
        self.contextManager = contextManager
        self.mountManager = mountManager
        self.guestFileSupport = LocalAgentGuestFileSupport(fileSystem: bridge)
        self.trustedRunValidator = { runID, sessionID in
            try Self.validateTrustedConversationRun(
                Persistence.loadConversationRun(id: runID),
                sessionID: sessionID
            )
        }
    }

    init(
        bridge: iSHAppleBridgeAdapter = .shared,
        runtime: LocalLinuxRuntimeController = .shared,
        contextManager: LocalAgentRuntimeContextManager = .shared,
        mountManager: LocalLinuxMountManager = .shared,
        guestFileSupport: LocalAgentGuestFileSupport? = nil,
        trustedRunValidator: @escaping @Sendable (UUID, UUID) throws -> Void
    ) {
        self.bridge = bridge
        self.runtime = runtime
        self.contextManager = contextManager
        self.mountManager = mountManager
        self.guestFileSupport = guestFileSupport ?? LocalAgentGuestFileSupport(fileSystem: bridge)
        self.trustedRunValidator = trustedRunValidator
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        var arguments = try decode(argumentsJSON)
        let trustedContext = removeTrustedContext(from: &arguments)
        let acquiredRunID = trustedContext?.runID
        if let acquiredRunID {
            await acquireRunOperation(acquiredRunID)
        }
        defer {
            if let acquiredRunID {
                releaseRunOperation(acquiredRunID)
            }
        }
        if let trustedContext {
            try trustedRunValidator(trustedContext.runID, trustedContext.sessionID)
        }
        let routedPaths = try pathArguments(in: arguments).map { key, value in
            (key, try route(value))
        }

        if toolName == AppToolKind.undoSandboxMutation.toolName, let trustedContext {
            return try await executeUndo(context: trustedContext)
        }

        guard routedPaths.contains(where: { $0.1.backend.requiresLinux }) else {
            for (key, routed) in routedPaths where routed.backend == .app {
                arguments[key] = routed.path
            }
            guard isMutatingFileTool(toolName), let trustedContext else {
                return try await executeAppTool(toolName: toolName, arguments: arguments)
            }
            let mutationID = UUID()
            let result = try await executeAppTool(
                toolName: toolName,
                arguments: arguments,
                undoContext: .init(runID: trustedContext.runID, mutationID: mutationID)
            )
            if SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: trustedContext.runID) {
                await commitMutation(
                    MutationEntry(
                        id: mutationID,
                        operation: toolName,
                        payload: .app(mutationID: mutationID)
                    ),
                    runID: trustedContext.runID
                )
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
        let nativeMounts = try await bridge.mounts()
        let mountRecords = Persistence.loadLocalLinuxMounts()
        var operationMounts = mountedTargets(
            routedPaths: routedPaths,
            guestPaths: guestPaths,
            nativeMounts: nativeMounts,
            records: mountRecords
        )
        if toolName == AppToolKind.deleteSandboxItem.toolName, guestPaths["path"] == "/" {
            operationMounts = mergeMountedTargets(
                operationMounts,
                nativeMounts.map { MountedTarget(id: $0.id, guestPaths: [$0.guestDirectory]) }
                    + [MountedTarget(
                        id: LocalLinuxMountManager.sharedMountID,
                        guestPaths: [LocalLinuxMountManager.sharedMountGuestPath]
                    )]
            )
        }
        try validateMountedTargets(
            operationMounts,
            context: frozen,
            nativeMounts: nativeMounts,
            records: mountRecords
        )
        let mutationMounts: [MountedTarget]
        if isMutatingFileTool(toolName) {
            if toolName == AppToolKind.deleteSandboxItem.toolName, guestPaths["path"] == "/" {
                mutationMounts = operationMounts
            } else {
                mutationMounts = mountedTargets(
                    routedPaths: routedPaths.filter { guestMutationArgumentKeys(toolName).contains($0.0) },
                    guestPaths: guestPaths,
                    nativeMounts: nativeMounts,
                    records: mountRecords
                )
            }
            try validateMountedTargets(
                mutationMounts,
                context: frozen,
                nativeMounts: nativeMounts,
                records: mountRecords,
                requiresWrite: true
            )
        } else {
            mutationMounts = []
        }
        let leases = try await mountManager.acquireLeases(ids: dynamicLeaseIDs(for: operationMounts))
        try await authorizeMountedWrites(
            toolName: toolName,
            arguments: arguments,
            mounts: mutationMounts,
            guestPaths: guestPaths,
            context: trustedContext
        )
        let undoPreparation: LocalAgentGuestUndoPreparation?
        let undoMounts: [MountedTarget]
        let damagesCriticalSystem: Bool
        if isMutatingFileTool(toolName) {
            try await validateGuestMutation(toolName: toolName, paths: guestPaths)
            let undoPaths = guestMutationPaths(toolName: toolName, paths: guestPaths)
            damagesCriticalSystem = undoPaths.contains(where: isCriticalSystemPath)
            let unavailableReason = damagesCriticalSystem
                ? NSLocalizedString(
                    "最近一次修改涉及关键 Linux 系统路径，Runtime 已要求重新打开，不能在当前进程中自动撤销。",
                    comment: "Critical Linux mutation undo unavailable"
                )
                : nil
            undoPreparation = try await guestFileSupport.prepareUndo(
                operation: toolName,
                paths: undoPaths,
                unavailableReason: unavailableReason
            )
            undoMounts = mutationMounts
        } else {
            undoPreparation = nil
            undoMounts = []
            damagesCriticalSystem = false
        }

        var result = try await performGuestMutation(
            preparation: undoPreparation,
            damagesCriticalSystem: damagesCriticalSystem
        ) {
            try await executeGuestTool(toolName: toolName, arguments: arguments, paths: guestPaths)
        }
        if let undoPreparation {
            await commitMutation(
                MutationEntry(
                    id: UUID(),
                    operation: toolName,
                    payload: .guest(preparation: undoPreparation, mounts: undoMounts)
                ),
                runID: trustedContext.runID
            )
            result = try augmentResult(
                result,
                values: [
                    "undoAvailable": undoPreparation.unavailableReason == nil,
                    "undoUnavailableReason": undoPreparation.unavailableReason.map { $0 as Any } ?? NSNull()
                ]
            )
        }
        if damagesCriticalSystem {
            let persisted = await markCriticalSystemDamaged()
            result = try augmentResult(
                result,
                values: [
                    "requiresRelaunch": true,
                    "damageMarkerPersisted": persisted
                ]
            )
        }
        withExtendedLifetime(leases) {}
        return result
    }

    /// guest mutation 与快照提交形成同一事务；这里也是故障注入测试的真实生产边界。
    func performGuestMutation(
        preparation: LocalAgentGuestUndoPreparation?,
        damagesCriticalSystem: Bool,
        operation: () async throws -> String
    ) async throws -> String {
        do {
            return try await operation()
        } catch {
            guard let preparation else { throw error }
            do {
                _ = try await guestFileSupport.restore(preparation)
                await guestFileSupport.discard(preparation)
            } catch let rollbackError {
                await guestFileSupport.discard(preparation)
                if damagesCriticalSystem {
                    _ = await markCriticalSystemDamaged()
                }
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    String(
                        format: NSLocalizedString("Linux 文件操作失败（%@），自动回滚也失败（%@）。", comment: "Linux file mutation and rollback failure"),
                        error.localizedDescription,
                        rollbackError.localizedDescription
                    )
                )
            }
            throw error
        }
    }

    private func guestMutationPaths(toolName: String, paths: [String: String]) -> [String] {
        switch toolName {
        case AppToolKind.moveSandboxItem.toolName:
            return [paths["source_path"], paths["destination_path"]].compactMap { $0 }
        case AppToolKind.copySandboxItem.toolName:
            return [paths["destination_path"]].compactMap { $0 }
        default:
            return [paths["path"]].compactMap { $0 }
        }
    }

    private func guestMutationArgumentKeys(_ toolName: String) -> Set<String> {
        switch toolName {
        case AppToolKind.moveSandboxItem.toolName:
            return ["source_path", "destination_path"]
        case AppToolKind.copySandboxItem.toolName:
            return ["destination_path"]
        default:
            return ["path"]
        }
    }

    private func executeUndo(context: TrustedContext) async throws -> String {
        guard var entries = mutationsByRunID[context.runID], let entry = entries.popLast() else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("当前 Agent Run 没有可撤销的文件修改。", comment: "Agent file undo history empty")
            )
        }
        if entries.isEmpty {
            mutationsByRunID.removeValue(forKey: context.runID)
        } else {
            mutationsByRunID[context.runID] = entries
        }

        var shouldRestoreHistory = true
        do {
            switch entry.payload {
            case .app(let mutationID):
                guard SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: context.runID) else {
                    shouldRestoreHistory = false
                    throw SandboxFileToolError.noUndoHistory
                }
                let result = try SandboxFileToolSupport.undoMutation(
                    id: mutationID,
                    runID: context.runID
                )
                return try encode([
                    "operation": result.operation,
                    "recordedAt": result.recordedAt
                ])

            case .guest(let preparation, let mounts):
                if let reason = preparation.unavailableReason {
                    throw LocalLinuxRuntimeError.runtimeUnavailable(reason)
                }
                let frozen = try await contextManager.beginRun(
                    sessionID: context.sessionID,
                    triggeringMessageID: context.triggeringMessageID,
                    toolCallID: context.toolCallID,
                    runID: context.runID,
                    selectedMCPServerIDs: context.selectedMCPServerIDs
                ).context
                _ = try await runtime.ensureReady(trigger: .guestFileBrowser)
                let nativeMounts = try await bridge.mounts()
                try validateMountedTargets(
                    mounts,
                    context: frozen,
                    nativeMounts: nativeMounts,
                    records: Persistence.loadLocalLinuxMounts(),
                    requiresWrite: true
                )
                let leases = try await mountManager.acquireLeases(ids: dynamicLeaseIDs(for: mounts))
                try await authorizeUndoMountedWrites(
                    operation: entry.operation,
                    mounts: mounts,
                    context: context
                )
                let result = try await guestFileSupport.restore(preparation)
                await guestFileSupport.discard(preparation)
                withExtendedLifetime(leases) {}
                return try encode([
                    "operation": result.operation,
                    "recordedAt": ISO8601DateFormatter().string(from: result.recordedAt)
                ])
            }
        } catch {
            if shouldRestoreHistory {
                var restored = mutationsByRunID[context.runID] ?? []
                restored.append(entry)
                mutationsByRunID[context.runID] = restored
            }
            throw error
        }
    }

    private func commitMutation(_ entry: MutationEntry, runID: UUID) async {
        var entries = mutationsByRunID[runID] ?? []
        entries.append(entry)
        let stale: MutationEntry?
        if entries.count > maximumUndoEntriesPerRun {
            stale = entries.removeFirst()
        } else {
            stale = nil
        }
        mutationsByRunID[runID] = entries
        if let stale {
            await discardMutation(stale, runID: runID)
        }
    }

    private func discardMutation(_ entry: MutationEntry, runID: UUID) async {
        switch entry.payload {
        case .app(let mutationID):
            SandboxFileToolSupport.discardUndoMutation(id: mutationID, runID: runID)
        case .guest(let preparation, _):
            await guestFileSupport.discard(preparation)
        }
    }

    /// Run 结束后，撤销入口已不再可达，因此同步清理内存记录与 guest/app 快照。
    public func finishRun(id runID: UUID) async {
        await acquireRunOperation(runID)
        defer { releaseRunOperation(runID) }
        let entries = mutationsByRunID.removeValue(forKey: runID) ?? []
        SandboxFileToolSupport.discardUndoMutations(runID: runID)
        for entry in entries {
            if case .guest(let preparation, _) = entry.payload {
                await guestFileSupport.discard(preparation)
            }
        }
    }

    static func validateTrustedConversationRun(_ run: ConversationRun?, sessionID: UUID) throws {
        guard let run, !run.status.isTerminal else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 已经结束，不能再次执行迟到的工具调用。", comment: "Terminal Agent run cannot be resumed")
            )
        }
        guard run.sessionID == sessionID else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Agent Run 标识不属于当前会话。", comment: "Agent run session mismatch")
            )
        }
    }

    private func acquireRunOperation(_ runID: UUID) async {
        guard activeRunOperations.contains(runID) else {
            activeRunOperations.insert(runID)
            return
        }
        await withCheckedContinuation { continuation in
            runOperationWaiters[runID, default: []].append(continuation)
        }
    }

    private func releaseRunOperation(_ runID: UUID) {
        if var waiters = runOperationWaiters[runID], !waiters.isEmpty {
            let next = waiters.removeFirst()
            if waiters.isEmpty {
                runOperationWaiters.removeValue(forKey: runID)
            } else {
                runOperationWaiters[runID] = waiters
            }
            next.resume()
            return
        }
        activeRunOperations.remove(runID)
    }

    private func validateGuestMutation(toolName: String, paths: [String: String]) async throws {
        guard toolName == AppToolKind.moveSandboxItem.toolName ||
                toolName == AppToolKind.copySandboxItem.toolName else { return }
        let source = try requiredPath("source_path", paths: paths)
        let destination = try requiredPath("destination_path", paths: paths)
        let info = try await bridge.statGuestFile(path: source, requestID: nextRequestID(), noFollow: true)
        try Self.validateGuestPathRelationship(
            source: source,
            destination: destination,
            sourceIsDirectory: info.isDirectory
        )
    }

    static func validateGuestPathRelationship(
        source: String,
        destination: String,
        sourceIsDirectory: Bool
    ) throws {
        guard source != destination else {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("Linux 文件的源路径和目标路径不能相同。", comment: "Linux file source destination same")
            )
        }
        if isDescendant(destination, of: source), sourceIsDirectory {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("不能把 Linux 目录移动或复制到自身内部。", comment: "Linux directory mutation into itself")
            )
        }
        if isDescendant(source, of: destination) {
            throw LocalLinuxRuntimeError.runtimeUnavailable(
                NSLocalizedString("目标路径是源路径的父目录，覆盖它会同时删除源项目。", comment: "Linux destination contains source")
            )
        }
    }

    private static func isDescendant(_ candidate: String, of parent: String) -> Bool {
        if parent == "/" { return candidate != "/" && candidate.hasPrefix("/") }
        return candidate.hasPrefix(parent + "/")
    }

    private func markCriticalSystemDamaged() async -> Bool {
        let reason = NSLocalizedString(
            "Agent 修改了关键 Linux 系统路径。重新打开 App 后会从内置系统恢复。",
            comment: "Agent mutated critical Linux system path"
        )
        do {
            try await runtime.markSystemDamaged(reason: reason)
            return true
        } catch {
            await runtime.markRequiresRelaunch(reason: reason)
            return false
        }
    }

    private func augmentResult(_ result: String, values: [String: Any]) throws -> String {
        var payload = try decode(result)
        for (key, value) in values {
            payload[key] = value
        }
        return try encode(payload)
    }

    func isMutatingFileTool(_ toolName: String) -> Bool {
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

    func mutationPreview(
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

    private func executeAppTool(
        toolName: String,
        arguments: [String: Any],
        undoContext: SandboxFileToolSupport.SandboxUndoContext? = nil
    ) async throws -> String {
        let argumentsJSON = try encode(arguments)
        return try await SandboxFileToolSupport.$undoContext.withValue(undoContext) {
            try await AppToolManager.shared.executeToolForBuiltInMCP(
                toolName: toolName,
                argumentsJSON: argumentsJSON
            )
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

    private func isCriticalSystemPath(_ path: String) -> Bool {
        ["/", "/bin", "/etc", "/lib", "/sbin", "/usr"].contains(path)
    }

    func simpleDiff(path: String, current: String, updated: String) -> String {
        if current == updated { return "--- \(path)\n+++ \(path)\n" }
        return "--- \(path)\n+++ \(path)\n@@ -1 +1 @@\n-\(current)\n+\(updated)"
    }

    func replacingFirst(_ old: String, with new: String, in content: String) -> String {
        guard let range = content.range(of: old) else { return content }
        var result = content
        result.replaceSubrange(range, with: new)
        return result
    }

    func requiredPath(_ key: String, paths: [String: String]) throws -> String {
        guard let value = paths[key], !value.isEmpty else { throw invalidArguments(key) }
        return value
    }

    func requiredString(_ key: String, arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else { throw invalidArguments(key) }
        return value
    }

    func invalidArguments(_ key: String) -> AppToolExecutionError {
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

    func encode(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else { throw invalidArguments("JSON") }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else { throw invalidArguments("JSON") }
        return string
    }

    func nextRequestID() -> UInt64 {
        requestCounter &+= 1
        if requestCounter == 0 { requestCounter = 1 }
        return requestCounter
    }
}

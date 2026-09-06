// ============================================================================
// LocalAgentFileToolExecutorMounts.swift
// ============================================================================
// ETOS LLM Studio
//
// 文件 URI 只负责定位路径；真正的挂载归属始终按最终 guest 路径反查，避免
// linux:// 绕过 mount:// 的冻结上下文、写入审批与动态租约。
// ============================================================================

import Foundation

extension LocalAgentFileToolExecutor {
    func mountedTargets(
        routedPaths: [(String, RoutedPath)],
        guestPaths: [String: String],
        nativeMounts: [LocalLinuxBridgeMountInfo],
        records: [LocalLinuxMountRecord]
    ) -> [MountedTarget] {
        var grouped: [UUID: [String]] = [:]
        for (key, routed) in routedPaths {
            guard let guestPath = guestPaths[key] else { continue }
            if case .mount(let explicitID) = routed.backend {
                appendMountedPath(guestPath, id: explicitID, grouped: &grouped)
            }
            if let inferredID = Self.inferredMountID(
                for: guestPath,
                nativeMounts: nativeMounts,
                records: records
            ) {
                appendMountedPath(guestPath, id: inferredID, grouped: &grouped)
            }
        }
        return grouped.keys.sorted { $0.uuidString < $1.uuidString }.map {
            MountedTarget(id: $0, guestPaths: grouped[$0] ?? [])
        }
    }

    static func inferredMountID(
        for guestPath: String,
        nativeMounts: [LocalLinuxBridgeMountInfo],
        records: [LocalLinuxMountRecord]
    ) -> UUID? {
        var candidates = nativeMounts.map { ($0.id, $0.guestDirectory) }
        candidates.append(contentsOf: records.map { ($0.id, $0.guestPath) })
        candidates.append((LocalLinuxMountManager.sharedMountID, LocalLinuxMountManager.sharedMountGuestPath))

        if let matched = candidates
            .filter({ path(guestPath, belongsTo: $0.1) })
            .max(by: { $0.1.count < $1.1.count }) {
            return matched.0
        }

        let etosRoot = "/mnt/etos/"
        guard guestPath.hasPrefix(etosRoot) else { return nil }
        let rawID = guestPath.dropFirst(etosRoot.count).split(separator: "/", maxSplits: 1).first
        return rawID.flatMap { UUID(uuidString: String($0)) }
    }

    static func requiresDynamicLease(mountID: UUID) -> Bool {
        mountID != LocalLinuxMountManager.sharedMountID
    }

    func dynamicLeaseIDs(for targets: [MountedTarget]) -> [UUID] {
        targets.map(\.id)
            .filter { Self.requiresDynamicLease(mountID: $0) }
            .reduce(into: [UUID]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func mergeMountedTargets(_ left: [MountedTarget], _ right: [MountedTarget]) -> [MountedTarget] {
        var grouped: [UUID: [String]] = [:]
        for target in left + right {
            for guestPath in target.guestPaths {
                appendMountedPath(guestPath, id: target.id, grouped: &grouped)
            }
        }
        return grouped.keys.sorted { $0.uuidString < $1.uuidString }.map {
            MountedTarget(id: $0, guestPaths: grouped[$0] ?? [])
        }
    }

    func validateMountedTargets(
        _ targets: [MountedTarget],
        context: AgentRuntimeContext,
        nativeMounts: [LocalLinuxBridgeMountInfo],
        records: [LocalLinuxMountRecord],
        requiresWrite: Bool = false
    ) throws {
        let nativeByID = Dictionary(uniqueKeysWithValues: nativeMounts.map { ($0.id, $0) })
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let internalDynamicIDs: Set<UUID> = [
            LocalLinuxMountManager.homeMountID,
            LocalLinuxMountManager.workspaceMountID,
            LocalLinuxMountManager.iCloudMountID
        ]

        for target in targets {
            if target.id == LocalLinuxMountManager.sharedMountID {
                guard target.guestPaths.allSatisfy({
                    Self.path($0, belongsTo: LocalLinuxMountManager.sharedMountGuestPath)
                }) else {
                    throw unavailableMountError()
                }
                continue
            }

            guard let native = nativeByID[target.id],
                  native.state == 2,
                  !requiresWrite || native.access == .readWrite,
                  target.guestPaths.allSatisfy({ Self.path($0, belongsTo: native.guestDirectory) }) else {
                throw unavailableMountError()
            }
            if internalDynamicIDs.contains(target.id) {
                continue
            }
            guard context.mountIDs.contains(target.id),
                  let record = recordsByID[target.id],
                  record.isEnabled,
                  record.authorizationState == .available,
                  !requiresWrite || record.access == .readWrite,
                  native.guestDirectory == record.guestPath,
                  target.guestPaths.allSatisfy({ Self.path($0, belongsTo: record.guestPath) }) else {
                throw unavailableMountError()
            }
        }
    }

    func authorizeMountedWrites(
        toolName: String,
        arguments: [String: Any],
        mounts: [MountedTarget],
        guestPaths: [String: String],
        context: TrustedContext
    ) async throws {
        guard isMutatingFileTool(toolName) else { return }
        let builtInIDs: Set<UUID> = [
            LocalLinuxMountManager.homeMountID,
            LocalLinuxMountManager.workspaceMountID,
            LocalLinuxMountManager.sharedMountID,
            LocalLinuxMountManager.iCloudMountID
        ]
        let records = Dictionary(uniqueKeysWithValues: Persistence.loadLocalLinuxMounts().map { ($0.id, $0) })
        for mount in mounts where !builtInIDs.contains(mount.id) {
            guard let record = records[mount.id], record.access == .readWrite else {
                throw unavailableMountError()
            }
            let details = try encode([
                "operation": toolName,
                "mount_id": mount.id.uuidString,
                "mount_name": record.displayName,
                "guest_paths": mount.guestPaths,
                "change_preview": await mutationPreview(
                    toolName: toolName,
                    arguments: arguments,
                    guestPaths: guestPaths
                )
            ])
            let denied = await mountedWriteWasDenied(
                operation: toolName,
                mount: mount,
                record: record,
                details: details,
                context: context
            )
            if denied {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("用户未允许写入这个外部 Linux 挂载。", comment: "External Linux mount write denied")
                )
            }
        }
    }

    func authorizeUndoMountedWrites(
        operation: String,
        mounts: [MountedTarget],
        context: TrustedContext
    ) async throws {
        let builtInIDs: Set<UUID> = [
            LocalLinuxMountManager.homeMountID,
            LocalLinuxMountManager.workspaceMountID,
            LocalLinuxMountManager.sharedMountID,
            LocalLinuxMountManager.iCloudMountID
        ]
        let records = Dictionary(uniqueKeysWithValues: Persistence.loadLocalLinuxMounts().map { ($0.id, $0) })
        for mount in mounts where !builtInIDs.contains(mount.id) {
            guard let record = records[mount.id], record.access == .readWrite else {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("外部 Linux 挂载当前不允许写入，无法执行撤销。", comment: "Linux mount undo is no longer writable")
                )
            }
            let details = try encode([
                "operation": AppToolKind.undoSandboxMutation.toolName,
                "original_operation": operation,
                "mount_id": mount.id.uuidString,
                "mount_name": record.displayName,
                "guest_paths": mount.guestPaths
            ])
            let denied = await mountedWriteWasDenied(
                operation: AppToolKind.undoSandboxMutation.toolName,
                mount: mount,
                record: record,
                details: details,
                context: context
            )
            if denied {
                throw LocalLinuxRuntimeError.runtimeUnavailable(
                    NSLocalizedString("用户未允许撤销操作写入这个外部 Linux 挂载。", comment: "External Linux mount undo denied")
                )
            }
        }
    }

    private func mountedWriteWasDenied(
        operation: String,
        mount: MountedTarget,
        record: LocalLinuxMountRecord,
        details: String,
        context: TrustedContext
    ) async -> Bool {
        let decision = await ToolPermissionCenter.shared.requestPermission(
            toolName: "local_linux.mount.write.\(mount.id.uuidString.lowercased())",
            displayName: String(
                format: NSLocalizedString("写入外部挂载：%@", comment: "External Linux mount write approval title"),
                record.displayName
            ),
            arguments: details,
            sourceSessionID: context.sessionID,
            toolCallID: context.toolCallID
        )
        let denied: Bool
        switch decision {
        case .deny, .supplement:
            denied = true
        case .allowOnce, .allowForTool, .allowAll:
            denied = false
        }
        _ = Persistence.saveLocalLinuxAudit(
            LocalLinuxAuditRecord(
                sessionID: context.sessionID,
                runID: context.runID,
                jobID: nil,
                action: operation,
                decision: denied ? "denied" : "user_approved",
                scope: "mount_write",
                matchedRuleID: nil,
                redactedSummary: "mount=\(mount.id.uuidString), paths=\(mount.guestPaths.joined(separator: ", "))",
                executorDeviceID: UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
            )
        )
        return denied
    }

    private func appendMountedPath(
        _ guestPath: String,
        id: UUID,
        grouped: inout [UUID: [String]]
    ) {
        if grouped[id]?.contains(guestPath) != true {
            grouped[id, default: []].append(guestPath)
        }
    }

    private static func path(_ path: String, belongsTo root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func unavailableMountError() -> LocalLinuxRuntimeError {
        .runtimeUnavailable(
            NSLocalizedString(
                "该 Linux 挂载已停用、撤销授权或不再允许写入；没有向底层挂载点执行文件操作。",
                comment: "Linux mount unavailable during file operation"
            )
        )
    }
}

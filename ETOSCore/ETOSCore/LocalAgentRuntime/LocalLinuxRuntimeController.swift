// ============================================================================
// LocalLinuxRuntimeController.swift
// ============================================================================
// ETOS LLM Studio
//
// 一个宿主进程只有一个 iSH kernel。开总开关或停留在 Chat 不启动；只有
// Agent 请求、用户终端、Linux 文件、recipe 或本地 MCP 明确操作才懒准备。
// ============================================================================

import Darwin
import Foundation

private final class LocalLinuxInstallCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
}

public enum LocalLinuxRuntimeTrigger: String, Sendable {
    case agentRequest = "agent_request"
    case userTerminal = "user_terminal"
    case guestFileBrowser = "guest_file_browser"
    case recipe
    case localMCP = "local_mcp"
}

public actor LocalLinuxRuntimeController {
    public static let shared = LocalLinuxRuntimeController()

    private let bridge: iSHAppleBridgeAdapter
    private let storage: LocalLinuxStorageManager
    private let mountManager: LocalLinuxMountManager
    private let migrationManager: LocalLinuxRootFSMigrationManager
    private let seedBundle: Bundle
    private let executorDeviceID: String

    private var snapshotValue: LocalLinuxRuntimeSnapshot
    private var preparationTask: Task<LocalLinuxRuntimeSnapshot, Error>?
    private var maintenanceTask: Task<LocalLinuxRuntimeSnapshot, Error>?
    private var updateContinuations: [UUID: AsyncStream<LocalLinuxRuntimeSnapshot>.Continuation] = [:]
    private var didRecoverPersistedJobs = false
    private var runtimeStarted = false
    private var cancelActiveWork: (@Sendable () async -> Void)?

    public init(
        bridge: iSHAppleBridgeAdapter = .shared,
        storage: LocalLinuxStorageManager = .shared,
        mountManager: LocalLinuxMountManager = .shared,
        migrationManager: LocalLinuxRootFSMigrationManager = .shared,
        seedBundle: Bundle = .main,
        executorDeviceID: String = UsageAnalyticsRuntimeContext.currentDeviceIdentifier()
    ) {
        self.bridge = bridge
        self.storage = storage
        self.mountManager = mountManager
        self.migrationManager = migrationManager
        self.seedBundle = seedBundle
        self.executorDeviceID = executorDeviceID
        snapshotValue = LocalLinuxRuntimeSnapshot(
            phase: AppConfigStore.boolValue(for: .localLinuxEnabled) ? .notInstalled : .disabled
        )
    }

    public func snapshot() -> LocalLinuxRuntimeSnapshot {
        snapshotValue
    }

    public func updates() -> AsyncStream<LocalLinuxRuntimeSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            updateContinuations[id] = continuation
            continuation.yield(snapshotValue)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUpdateContinuation(id: id) }
            }
        }
    }

    public func setActiveWorkCancellationHandler(
        _ handler: @escaping @Sendable () async -> Void
    ) {
        cancelActiveWork = handler
    }

    @discardableResult
    public func refreshInstalledState() async -> LocalLinuxRuntimeSnapshot {
        // 页面刷新不能把进行中的安装或维护覆盖成“已安装”，否则会放行新的操作。
        guard preparationTask == nil, maintenanceTask == nil else { return snapshotValue }
        await recoverPersistedJobsIfNeeded()
        guard preparationTask == nil, maintenanceTask == nil else { return snapshotValue }
        guard AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            updateSnapshot(phase: .disabled, progress: nil, error: nil)
            return snapshotValue
        }
        guard iSHAppleBridgeAdapter.isAvailable else {
            updateSnapshot(
                phase: .failed,
                progress: nil,
                error: LocalLinuxRuntimeError.unsupportedPlatform.localizedDescription
            )
            return snapshotValue
        }
        do {
            let resource = try LocalLinuxSeedResource.load(from: seedBundle)
            _ = try LocalLinuxRootFSMigrationResource.load(
                from: seedBundle,
                targetSeedSHA256: resource.metadata.installationReceiptSHA256
            )
            let integrity = await storage.systemIntegrity()
            guard preparationTask == nil, maintenanceTask == nil else { return snapshotValue }
            switch integrity {
            case .notInstalled:
                if runtimeStarted {
                    if let cancelActiveWork { await cancelActiveWork() }
                    updateSnapshot(
                        phase: .requiresRelaunch,
                        resource: resource,
                        progress: nil,
                        error: NSLocalizedString("运行中的 Linux 系统目录已被删除。重新启动本地 Linux 后会从内置系统恢复。", comment: "Running Linux RootFS deleted")
                    )
                } else {
                    updateSnapshot(phase: .notInstalled, resource: resource, progress: nil, error: nil)
                }
            case .installed(let installedSeedSHA256):
                updateSnapshot(
                    phase: runtimeStarted ? .ready : .installed,
                    resource: resource,
                    installedSeedSHA256: installedSeedSHA256,
                    progress: nil,
                    error: nil
                )
            case .damaged(let detail):
                if runtimeStarted, let cancelActiveWork { await cancelActiveWork() }
                updateSnapshot(
                    phase: runtimeStarted ? .requiresRelaunch : .degraded,
                    resource: resource,
                    progress: nil,
                    error: detail
                )
            }
        } catch {
            updateSnapshot(phase: .failed, progress: nil, error: error.localizedDescription)
        }
        return snapshotValue
    }

    public func ensureReady(trigger: LocalLinuxRuntimeTrigger) async throws -> LocalLinuxRuntimeSnapshot {
        while let maintenanceTask { _ = try await maintenanceTask.value }
        if let preparationTask { return try await preparationTask.value }

        // 在第一次挂起前登记任务；actor 在 await 期间仍允许其他启动请求进入。
        let task = Task {
            defer { preparationTask = nil }
            return try await prepareIfNeeded(trigger: trigger)
        }
        preparationTask = task
        return try await task.value
    }

    private func prepareIfNeeded(trigger: LocalLinuxRuntimeTrigger) async throws -> LocalLinuxRuntimeSnapshot {
        await recoverPersistedJobsIfNeeded()
        try Task.checkCancellation()
        guard AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            throw LocalLinuxRuntimeError.featureDisabled
        }
        guard snapshotValue.phase != .requiresRelaunch else {
            throw LocalLinuxRuntimeError.requiresRelaunch
        }
        if snapshotValue.phase == .ready, await bridge.runtimePhase() == 2 {
            switch await storage.systemIntegrity() {
            case .installed:
                try Task.checkCancellation()
                return snapshotValue
            case .notInstalled:
                await transitionToRequiresRelaunch(
                    reason: NSLocalizedString("运行中的 Linux 系统目录已被删除。重新启动本地 Linux 后会从内置系统恢复。", comment: "Running Linux RootFS deleted")
                )
                throw LocalLinuxRuntimeError.requiresRelaunch
            case .damaged(let detail):
                await transitionToRequiresRelaunch(reason: detail)
                throw LocalLinuxRuntimeError.requiresRelaunch
            }
        }
        do {
            return try await performPreparation(trigger: trigger)
        } catch {
            if error is CancellationError {
                let resource = try? LocalLinuxSeedResource.load(from: seedBundle)
                switch await storage.systemIntegrity() {
                case .notInstalled:
                    updateSnapshot(phase: .notInstalled, resource: resource, progress: nil, error: nil)
                case .installed(let installedSeedSHA256):
                    updateSnapshot(
                        phase: .installed,
                        resource: resource,
                        installedSeedSHA256: installedSeedSHA256,
                        progress: nil,
                        error: nil
                    )
                case .damaged(let detail):
                    updateSnapshot(phase: .degraded, resource: resource, progress: nil, error: detail)
                }
            } else {
                updateSnapshot(phase: .failed, progress: nil, error: error.localizedDescription)
            }
            throw error
        }
    }

    public func cancelPreparation() {
        preparationTask?.cancel()
    }

    public func updateActivityCounts(jobs: Int, terminals: Int, localMCP: Int) {
        snapshotValue.activeJobCount = max(0, jobs)
        snapshotValue.activeTerminalCount = max(0, terminals)
        snapshotValue.activeMCPProcessCount = max(0, localMCP)
        snapshotValue.updatedAt = Date()
        publishSnapshot()
    }

    public func updateLocalMCPActivityCount(_ count: Int) {
        snapshotValue.activeMCPProcessCount = max(0, count)
        snapshotValue.updatedAt = Date()
        publishSnapshot()
    }

    @discardableResult
    public func restartRuntime() async throws -> LocalLinuxRuntimeSnapshot {
        guard AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            throw LocalLinuxRuntimeError.featureDisabled
        }
        return try await performMaintenance(.restart)
    }

    @discardableResult
    public func deleteSystem(deleteUserData: Bool) async throws -> LocalLinuxRuntimeSnapshot {
        try await performMaintenance(.deleteSystem(deleteUserData: deleteUserData))
    }

    private enum MaintenanceOperation {
        case restart
        case deleteSystem(deleteUserData: Bool)
    }

    private func performMaintenance(_ operation: MaintenanceOperation) async throws -> LocalLinuxRuntimeSnapshot {
        while let maintenanceTask { _ = try? await maintenanceTask.value }
        let task = Task {
            defer { maintenanceTask = nil }
            do {
                try await stopRuntimeForMaintenance()
                switch operation {
                case .restart:
                    return try await performPreparation(trigger: .recipe)
                case .deleteSystem(let deleteUserData):
                    try await storage.deleteSystem(deleteUserData: deleteUserData)
                    snapshotValue.seedVersion = nil
                    snapshotValue.seedSHA256 = nil
                    // 重置的成功条件是清除系统，不依赖旧设置或下一次安装能否启动。
                    updateSnapshot(
                        phase: AppConfigStore.boolValue(for: .localLinuxEnabled) ? .notInstalled : .disabled,
                        progress: nil,
                        error: nil
                    )
                    return snapshotValue
                }
            } catch {
                updateSnapshot(phase: .failed, progress: nil, error: error.localizedDescription)
                throw error
            }
        }
        maintenanceTask = task
        return try await task.value
    }

    public func markRequiresRelaunch(reason: String) {
        updateSnapshot(phase: .requiresRelaunch, progress: nil, error: reason)
    }

    public func markSystemDamaged(reason: String) async throws {
        try await storage.markSystemDamaged(reason: reason)
        if runtimeStarted {
            await transitionToRequiresRelaunch(reason: reason)
        } else {
            updateSnapshot(phase: .degraded, progress: nil, error: reason)
        }
    }

    private func transitionToRequiresRelaunch(reason: String) async {
        if let cancelActiveWork { await cancelActiveWork() }
        updateSnapshot(phase: .requiresRelaunch, progress: nil, error: reason)
    }

    private func stopRuntimeForMaintenance() async throws {
        if let task = preparationTask {
            task.cancel()
            _ = try? await task.value
        }
        if let cancelActiveWork { await cancelActiveWork() }

        let bridgePhase = await bridge.runtimePhase()
        if runtimeStarted || bridgePhase != 0 {
            updateSnapshot(phase: .starting, progress: nil, error: nil)
            try await bridge.stopRuntime()
        }
        await mountManager.runtimeDidStop()
        runtimeStarted = false
        snapshotValue.capabilities = nil
        snapshotValue.activeJobCount = 0
        snapshotValue.activeTerminalCount = 0
        snapshotValue.activeMCPProcessCount = 0
    }

    private func performPreparation(trigger: LocalLinuxRuntimeTrigger) async throws -> LocalLinuxRuntimeSnapshot {
        _ = trigger
        guard AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            throw LocalLinuxRuntimeError.featureDisabled
        }
        guard iSHAppleBridgeAdapter.isAvailable else {
            throw LocalLinuxRuntimeError.unsupportedPlatform
        }
        try Task.checkCancellation()
        // native 启动失败仍可能留下 FAILED/STOPPED 内核；必须先卸载残留挂载再重试。
        let nativePhase = await bridge.runtimePhase()
        if nativePhase != 2 { runtimeStarted = false }
        if !runtimeStarted, nativePhase != 0 {
            try await bridge.stopRuntime()
            await mountManager.runtimeDidStop()
        }
        let layout = try await storage.prepareLayout()
        let resource = try LocalLinuxSeedResource.load(from: seedBundle)
        let migrationResource = try LocalLinuxRootFSMigrationResource.load(
            from: seedBundle,
            targetSeedSHA256: resource.metadata.installationReceiptSHA256
        )
        let integrity = await storage.systemIntegrity()
        var pendingMigrations: [LocalLinuxRootFSMigrationDefinition] = []
        switch integrity {
        case .notInstalled:
            break
        case .installed(let installedSeedSHA256):
            // 用户可通过 apk 等方式长期修改 RootFS。新 App 内置 seed 不会覆盖
            // 现有环境；只有清单明确声明的固定、可重复执行脚本可以推进基线版本。
            pendingMigrations = try migrationResource.migrationPath(from: installedSeedSHA256)
            updateSnapshot(
                phase: .installed,
                resource: resource,
                installedSeedSHA256: installedSeedSHA256,
                progress: nil,
                error: nil
            )
        case .damaged(let detail):
            _ = try await storage.preserveCurrentRootFS(reason: detail)
        }

        if case .installed = await storage.systemIntegrity() {
            // 已有有效系统直接启动。
        } else {
            updateSnapshot(
                phase: .installing,
                resource: resource,
                progress: LocalLinuxInstallProgress(phase: .checking),
                error: nil
            )
            let cancellationState = LocalLinuxInstallCancellationState()
            _ = try await withTaskCancellationHandler {
                try await bridge.installRootFSArchive(
                    archiveURL: resource.archiveURL,
                    metadata: resource.metadata,
                    persistentParent: layout.system,
                    rootName: "RootFS"
                ) { [weak self] progress in
                    Task { await self?.recordInstallProgress(progress, resource: resource) }
                    return cancellationState.shouldContinue
                }
            } onCancel: {
                cancellationState.cancel()
            }
            try Task.checkCancellation()
            updateSnapshot(phase: .installed, resource: resource, progress: nil, error: nil)
        }

        if !runtimeStarted {
            try Task.checkCancellation()
            updateSnapshot(phase: .starting, resource: resource, progress: nil, error: nil)
            let preparedMounts = try await mountManager.prepareStartupMounts()
            // mounts 只存 fd 数值，不能让其所有者在跨 actor 调用完成前析构。
            defer { withExtendedLifetime(preparedMounts) {} }
            try Task.checkCancellation()
            try await bridge.startRuntime(
                rootData: layout.rootFSData,
                sharedDirectory: layout.shared,
                socketPrefix: socketPrefix(),
                hostname: "ETOS",
                bootCommand: Self.bootCommand,
                startupMounts: preparedMounts.mounts
            )
            runtimeStarted = true
        }
        try Task.checkCancellation()
        try await migrationManager.apply(
            pendingMigrations,
            resource: migrationResource,
            storage: storage,
            bridge: bridge
        )
        let capabilities = try await bridge.runtimeCapabilities()
        snapshotValue.capabilities = capabilities
        updateSnapshot(phase: .ready, resource: resource, progress: nil, error: nil)
        return snapshotValue
    }

    private func recoverPersistedJobsIfNeeded() async {
        guard !didRecoverPersistedJobs else { return }
        didRecoverPersistedJobs = true
        _ = Persistence.markActiveLocalLinuxJobsInterrupted()
        _ = Persistence.markActiveLocalAgentRunsInterrupted()
        await mountManager.resetStaleLeaseCountsAfterLaunch()
    }

    private func recordInstallProgress(
        _ progress: LocalLinuxInstallProgress,
        resource: LocalLinuxSeedResource
    ) {
        guard snapshotValue.phase == .installing else { return }
        updateSnapshot(phase: .installing, resource: resource, progress: progress, error: nil)
    }

    private func updateSnapshot(
        phase: LocalLinuxRuntimePhase,
        resource: LocalLinuxSeedResource? = nil,
        installedSeedSHA256: String? = nil,
        progress: LocalLinuxInstallProgress?,
        error: String?
    ) {
        snapshotValue.phase = phase
        snapshotValue.installProgress = progress
        if let resource {
            snapshotValue.seedVersion = resource.metadata.alpineVersion
            snapshotValue.seedSHA256 = installedSeedSHA256 ?? resource.metadata.installationReceiptSHA256
        }
        snapshotValue.lastError = error
        snapshotValue.updatedAt = Date()
        _ = Persistence.saveLocalLinuxRuntimeSnapshot(snapshotValue, executorDeviceID: executorDeviceID)
        publishSnapshot()
    }

    private func publishSnapshot() {
        updateContinuations.values.forEach { $0.yield(snapshotValue) }
    }

    private func removeUpdateContinuation(id: UUID) {
        updateContinuations[id] = nil
    }

    private func socketPrefix() -> String {
        let preferred = NSTemporaryDirectory() + "e\(getpid())-"
        if preferred.utf8.count <= 82 { return preferred }
        return "/tmp/etos-\(getpid())-"
    }

    private static let bootCommand = "mkdir -p /home /mnt/home /mnt/workspaces /mnt/shared; "
        + "[ -e /home/etos ] || ln -s /mnt/home /home/etos; "
        + "[ -e /workspace ] || ln -s /mnt/workspaces /workspace; "
        + "exec /sbin/init"
}

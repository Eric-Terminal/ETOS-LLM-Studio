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
        await recoverPersistedJobsIfNeeded()
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
                targetSeedSHA256: resource.metadata.archiveSHA256
            )
            let integrity = await storage.systemIntegrity()
            switch integrity {
            case .notInstalled:
                if runtimeStarted {
                    if let cancelActiveWork { await cancelActiveWork() }
                    updateSnapshot(
                        phase: .requiresRelaunch,
                        resource: resource,
                        progress: nil,
                        error: NSLocalizedString("运行中的 Linux 系统目录已被删除。重新打开 App 后会从内置系统恢复。", comment: "Running Linux RootFS deleted")
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
        await recoverPersistedJobsIfNeeded()
        guard AppConfigStore.boolValue(for: .localLinuxEnabled) else {
            throw LocalLinuxRuntimeError.featureDisabled
        }
        guard snapshotValue.phase != .requiresRelaunch else {
            throw LocalLinuxRuntimeError.requiresRelaunch
        }
        if snapshotValue.phase == .ready {
            switch await storage.systemIntegrity() {
            case .installed:
                return snapshotValue
            case .notInstalled:
                await transitionToRequiresRelaunch(
                    reason: NSLocalizedString("运行中的 Linux 系统目录已被删除。重新打开 App 后会从内置系统恢复。", comment: "Running Linux RootFS deleted")
                )
                throw LocalLinuxRuntimeError.requiresRelaunch
            case .damaged(let detail):
                await transitionToRequiresRelaunch(reason: detail)
                throw LocalLinuxRuntimeError.requiresRelaunch
            }
        }
        if let preparationTask { return try await preparationTask.value }

        let task = Task { try await performPreparation(trigger: trigger) }
        preparationTask = task
        do {
            let result = try await task.value
            preparationTask = nil
            return result
        } catch {
            preparationTask = nil
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

    public func deleteSystem(deleteUserData: Bool) async throws {
        preparationTask?.cancel()
        if let cancelActiveWork { await cancelActiveWork() }
        try await storage.deleteSystem(deleteUserData: deleteUserData)
        if runtimeStarted {
            updateSnapshot(
                phase: .requiresRelaunch,
                progress: nil,
                error: LocalLinuxRuntimeError.requiresRelaunch.localizedDescription
            )
        } else {
            updateSnapshot(phase: .notInstalled, progress: nil, error: nil)
        }
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

    private func performPreparation(trigger: LocalLinuxRuntimeTrigger) async throws -> LocalLinuxRuntimeSnapshot {
        _ = trigger
        guard iSHAppleBridgeAdapter.isAvailable else {
            throw LocalLinuxRuntimeError.unsupportedPlatform
        }
        let layout = try await storage.prepareLayout()
        let resource = try LocalLinuxSeedResource.load(from: seedBundle)
        let migrationResource = try LocalLinuxRootFSMigrationResource.load(
            from: seedBundle,
            targetSeedSHA256: resource.metadata.archiveSHA256
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
            updateSnapshot(phase: .starting, resource: resource, progress: nil, error: nil)
            let preparedMounts = try await mountManager.prepareStartupMounts()
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
            snapshotValue.seedSHA256 = installedSeedSHA256 ?? resource.metadata.archiveSHA256
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

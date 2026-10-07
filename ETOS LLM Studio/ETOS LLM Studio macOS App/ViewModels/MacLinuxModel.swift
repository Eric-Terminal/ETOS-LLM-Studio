import Combine
import ETOSCore
import Foundation

/// 单例的构造也可能读取配置和磁盘，统一在后台取得，不从 SwiftUI 初始化链路访问。
struct MacLinuxServices: Sendable {
    let runtime: LocalLinuxRuntimeController
    let scheduler: LocalLinuxJobScheduler
    let storage: LocalLinuxStorageManager
    let contexts: LocalAgentRuntimeContextManager
    let fileTools: LocalAgentFileToolExecutor

    static let shared = Task.detached(priority: .utility) {
        MacLinuxServices(runtime: .shared, scheduler: .shared, storage: .shared, contexts: .shared, fileTools: .shared)
    }
}

@MainActor
final class MacLinuxModel: ObservableObject {
    @Published private(set) var snapshot = LocalLinuxRuntimeSnapshot(phase: .disabled)
    @Published private(set) var storageSize = ""
    @Published private(set) var shellPaths = [LocalLinuxTerminalShellConfiguration.defaultPath]
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published var error: String?

    private var observation: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var lifecycle: Task<Void, Error>?
    private var shouldObserve = false

    var canOperate: Bool { isLoaded && !isWorking && !isSuspended && AppLockManager.shared.state != .locked }

    func observe() {
        guard observation == nil, !isSuspended else { return }
        shouldObserve = true
        let epoch = epoch
        observation = Task { [weak self] in
            let services = await MacLinuxServices.shared.value
            for await snapshot in await services.runtime.updates() {
                guard !Task.isCancelled, let self, self.epoch == epoch, !isSuspended else { return }
                self.snapshot = snapshot
            }
        }
        refresh()
    }

    func stopObserving() { observation?.cancel(); observation = nil }

    func refresh() {
        perform { services in _ = await services.runtime.refreshInstalledState() }
    }

    func prepare() { perform { services in _ = try await services.runtime.ensureReady(trigger: .userTerminal) } }
    func restart() { perform { services in _ = try await services.runtime.restartRuntime() } }
    func reset(deleteUserData: Bool) {
        perform { services in
            _ = try await services.runtime.deleteSystem(deleteUserData: deleteUserData)
            _ = try await services.runtime.ensureReady(trigger: .userTerminal)
        }
    }

    func cancelPreparation() {
        operation?.cancel()
        Task { let services = await MacLinuxServices.shared.value; await services.runtime.cancelPreparation() }
    }

    private func perform(_ action: @escaping @Sendable (MacLinuxServices) async throws -> Void) {
        guard !isWorking, !isSuspended, AppLockManager.shared.state != .locked else { return }
        isWorking = true; error = nil
        let epoch = epoch, revision = LocalLinuxActivityBarrier.shared.revision
        operation = Task { [weak self] in
            let task = Task.detached(priority: .utility) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    let services = await MacLinuxServices.shared.value
                    try Task.checkCancellation()
                    try await action(services)
                    let usage = await services.storage.storageUsage()
                    let shells = await services.storage.availableTerminalShellPaths()
                    return (await services.runtime.snapshot(), ByteCountFormatter.string(fromByteCount: Int64(clamping: usage.totalBytes), countStyle: .file), shells)
                }
            }
            do {
                let (snapshot, size, shells) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let self, self.epoch == epoch, !isSuspended else { return }
                self.snapshot = snapshot; storageSize = size; shellPaths = shells; isLoaded = true
            } catch is CancellationError { }
            catch { if let self, self.epoch == epoch { self.error = error.localizedDescription } }
            if let self, self.epoch == epoch { isWorking = false }
        }
    }

    func suspend() {
        // 先同步关门；UI 尚未收到状态变化时，工具和其他窗口也不能再启动作业。
        LocalLinuxActivityBarrier.shared.suspend()
        isSuspended = true; epoch = UUID(); operation?.cancel(); stopObserving()
        let previous = lifecycle, pending = operation
        lifecycle = Task {
            _ = try? await previous?.value
            let services = await MacLinuxServices.shared.value
            await services.runtime.cancelPreparation()
            await services.scheduler.cancelAllLinuxRuntimeWork()
            await services.contexts.interruptActiveRunsForHostDataOperation()
            await services.fileTools.finishActiveRunsForHostDataOperation()
            await pending?.value
            await LocalLinuxActivityBarrier.shared.waitForIdle()
            await services.storage.waitForWorkspaceSizeRefreshes()
            try await services.runtime.stopForHostDataOperation()
        }
    }

    func resume() {
        guard isSuspended else { return }
        let previous = lifecycle, epoch = epoch
        lifecycle = Task { [weak self] in
            do { try await previous?.value }
            catch {
                if let self, self.epoch == epoch { self.error = error.localizedDescription }
                throw error
            }
            guard let self, self.epoch == epoch, isSuspended, AppLockManager.shared.state != .locked else { return }
            let services = await MacLinuxServices.shared.value
            await services.runtime.prepareForHostResume()
            guard self.epoch == epoch, AppLockManager.shared.state != .locked else { return }
            LocalLinuxActivityBarrier.shared.resume()
            guard !LocalLinuxActivityBarrier.shared.isSuspended else { return }
            isSuspended = false; isWorking = false; isLoaded = false; error = nil
            if shouldObserve { observe() }
        }
    }

    func retryResume() { guard isSuspended else { return }; suspend(); resume() }

    func waitForPendingOperations() async throws {
        // 停止失败必须阻止数据库替换；退出进程时由系统最终回收内核。
        try await lifecycle?.value
        await operation?.value
    }
}

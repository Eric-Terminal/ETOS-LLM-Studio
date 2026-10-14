import Combine
import ETOSCore
import Foundation

@MainActor
final class MacLinuxConfigurationModel: ObservableObject {
    @Published private(set) var catalog: MacLinuxConfigurationCatalog?
    @Published private(set) var lease = UUID()
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published var error: String?
    private var isOpen = false
    private var pendingReload = false
    private var loading: Task<Void, Never>?
    private var cancelOperation: (() -> Void)?
    private var subscription: AnyCancellable?

    func open() {
        guard !isOpen else { return }
        isOpen = true; lease = UUID()
        subscription = NotificationCenter.default.publisher(for: .localLinuxConfigurationDidChange)
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
        reload()
    }

    func close(clearContent: Bool = true) {
        isOpen = false; lease = UUID(); loading?.cancel(); cancelOperation?(); cancelOperation = nil; subscription = nil
        isLoading = false; isWorking = false; pendingReload = false; error = nil
        if clearContent { catalog = nil }
    }

    func reload() {
        guard isOpen, !LocalLinuxActivityBarrier.shared.isSuspended else { return }
        guard !isLoading, !isWorking else { pendingReload = true; return }
        isLoading = true
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        loading = Task { [weak self] in
            await AppConfigStore.shared.flushPendingWrites()
            let task = Task.detached(priority: .utility) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    MacLinuxConfigurationCatalog.prepare(try await LocalLinuxConfigurationLibrary.shared.snapshot())
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let self, self.lease == lease, !Task.isCancelled else { return }
                catalog = result
            } catch is CancellationError { }
            catch { if let self, self.lease == lease { self.error = error.localizedDescription } }
            guard let self, self.lease == lease else { return }
            isLoading = false
            if pendingReload { pendingReload = false; reload() }
        }
    }

    func perform(expectedLease: UUID, revision: UUID,
        _ operation: @escaping @Sendable (LocalLinuxConfigurationLibrary) async throws -> LocalLinuxConfigurationSnapshot
    ) async throws {
        guard isOpen, lease == expectedLease, !isWorking, !LocalLinuxActivityBarrier.shared.isSuspended,
              AppLockManager.shared.state != .locked else { throw CancellationError() }
        isWorking = true; error = nil
        defer { if lease == expectedLease { cancelOperation = nil; isWorking = false; pendingReload = false; reload() } }
        let task = Task.detached(priority: .utility) {
            try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                try Task.checkCancellation()
                return MacLinuxConfigurationCatalog.prepare(try await operation(.shared))
            }
        }
        cancelOperation = { task.cancel() }
        do {
            let result = try await task.value
            guard lease == expectedLease, isOpen else { throw CancellationError() }
            catalog = result
        } catch {
            if lease == expectedLease, !(error is CancellationError) { self.error = error.localizedDescription }
            throw error
        }
    }
}

/// 只将校验结果发回界面；输入变化后旧的正则编译或变量检查不能重新启用保存按钮。
@MainActor
final class MacLinuxDraftValidationModel: ObservableObject {
    @Published private(set) var canSave = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var version = UUID()

    func validate(_ value: LocalLinuxEnvironmentVariable) { validate { _ = try LocalLinuxConfigurationValidation.variable(value) } }
    func validate(_ value: LocalLinuxCommandRule) { validate { _ = try LocalLinuxConfigurationValidation.rule(value) } }

    private func validate(_ operation: @escaping @Sendable () throws -> Void) {
        invalidate()
        let version = version
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let work = Task.detached(priority: .utility) { () -> String? in
                do { try Task.checkCancellation(); try operation(); return nil } catch { return error.localizedDescription }
            }
            let error = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, self.version == version, !Task.isCancelled else { return }
            self.error = error; canSave = error == nil
        }
    }

    func invalidate() { task?.cancel(); version = UUID(); canSave = false; error = nil }
}

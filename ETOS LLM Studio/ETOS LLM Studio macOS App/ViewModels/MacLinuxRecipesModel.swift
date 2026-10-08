import AppKit
import Combine
import ETOSCore
import Foundation

@MainActor
final class MacLinuxRecipesModel: ObservableObject {
    @Published private(set) var catalog: MacLinuxRecipeCatalog?
    @Published private(set) var result: MacLinuxRecipeResult?
    @Published private(set) var job: LocalLinuxJob?
    @Published private(set) var isLoading = false
    @Published private(set) var isProbing = false
    @Published private(set) var isStarting = false
    @Published private(set) var lease = UUID()
    @Published var terminal: MacLinuxRecipeTerminalTarget?
    @Published var error: String?
    private var recommendation: LocalLinuxMirrorRecommendation?
    private var attemptID: String?
    private var isOpen = false
    private var pendingReload = false
    private var loading: Task<Void, Never>?
    private var probing: Task<Void, Never>?
    private var starting: Task<Void, Never>?
    private var subscription: AnyCancellable?
    var isInstalling: Bool { job.map { !$0.state.isTerminal } ?? false }
    var canStart: Bool { isOpen && catalog != nil && !isLoading && !isProbing && !isStarting && !isInstalling }

    func open() {
        guard !isOpen else { return }
        isOpen = true; lease = UUID()
        subscription = NotificationCenter.default.publisher(for: .localLinuxJobsDidChange)
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .receive(on: DispatchQueue.main).sink { [weak self] notification in
                guard let self, let job, notification.object == nil || (notification.object as? UUID) == job.id else { return }
                reload()
            }
        reload()
        if recommendation == nil { probe() }
    }

    func close(clearContent: Bool = true) {
        isOpen = false; lease = UUID(); loading?.cancel(); probing?.cancel(); starting?.cancel(); subscription = nil
        isLoading = false; isProbing = false; isStarting = false; pendingReload = false; terminal = nil; error = nil
        if clearContent { catalog = nil; result = nil; job = nil; attemptID = nil; recommendation = nil }
    }

    func probe() {
        guard isOpen, !isProbing, !isStarting, !isInstalling else { return }
        isProbing = true
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        probing = Task { [weak self] in
            let work = Task.detached(priority: .utility) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    let value = await LocalLinuxPackageMirrors.recommend()
                    try Task.checkCancellation()
                    return value
                }
            }
            do {
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, self.lease == lease, !Task.isCancelled else { return }
                recommendation = value
            } catch is CancellationError { }
            catch { if let self, self.lease == lease { self.error = error.localizedDescription } }
            guard let self, self.lease == lease else { return }
            isProbing = false; reload()
        }
    }

    func reload() {
        guard isOpen else { return }
        guard !isLoading, !isStarting else { pendingReload = true; return }
        isLoading = true
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision, recommendation = recommendation, attemptID = attemptID, jobID = job?.id
        loading = Task { [weak self] in
            let work = Task.detached(priority: .utility) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    let installed = await LocalLinuxEnvironmentInstaller.installedRecipeIDs()
                    let recommendation = recommendation ?? LocalLinuxMirrorRecommendation(selectedMirror: LocalLinuxPackageMirrors.regionalFallback(), probeResults: [])
                    let services = await MacLinuxServices.shared.value
                    var error: String?
                    let job: LocalLinuxJob?
                    if let jobID {
                        job = await services.scheduler.job(id: jobID)
                        if job == nil { error = LocalLinuxRuntimeError.jobNotFound(jobID).localizedDescription }
                    } else { job = nil }
                    let result: MacLinuxRecipeResult?
                    if let job, job.state.isTerminal {
                        let output: String
                        do { output = try await services.scheduler.userVisibleOutput(jobID: job.id) }
                        catch let failure { output = ""; error = failure.localizedDescription }
                        result = MacLinuxRecipeResult.prepare(job: job, output: output)
                    } else { result = nil }
                    return (MacLinuxRecipeCatalog.prepare(recommendation: recommendation, installed: installed, attemptID: attemptID, job: job), job, result, error)
                }
            }
            do {
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, self.lease == lease, !Task.isCancelled else { return }
                catalog = value.0; job = value.1; result = value.2; error = value.3
            } catch is CancellationError { }
            catch { if let self, self.lease == lease { self.error = error.localizedDescription } }
            guard let self, self.lease == lease else { return }
            isLoading = false
            if pendingReload { pendingReload = false; reload() }
        }
    }

    func start(_ target: MacLinuxRecipeConfirmation) {
        guard canStart, lease == target.lease, catalog?.id == target.catalogID,
              !LocalLinuxActivityBarrier.shared.isSuspended, AppLockManager.shared.state != .locked else { return }
        isStarting = true; error = nil; result = nil
        let lease = lease, recipe = target.row.recipe
        starting = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: target.revision) {
                    try Task.checkCancellation()
                    let terminal = try await LocalLinuxEnvironmentInstaller.startTerminal(columns: 80, rows: 24)
                    let services = await MacLinuxServices.shared.value
                    do {
                        try Task.checkCancellation()
                        // 发送发生在用户确认的创建流程中；终端页面只附着，不携带可重放的启动输入。
                        try await services.scheduler.sendTerminalInput(jobID: terminal.id, owner: .user, data: recipe.terminalInput)
                    } catch { await services.scheduler.cancel(jobID: terminal.id); throw error }
                    return terminal
                }
            }
            do {
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, self.lease == lease, !Task.isCancelled else { return }
                job = value; attemptID = recipe.id; terminal = MacLinuxRecipeTerminalTarget(id: value.id)
            } catch is CancellationError { }
            catch { if let self, self.lease == lease { self.error = error.localizedDescription } }
            guard let self, self.lease == lease else { return }
            isStarting = false; pendingReload = false; reload()
        }
    }

    func copyCommand(_ target: MacLinuxRecipeConfirmation) {
        guard canStart, lease == target.lease, catalog?.id == target.catalogID,
              LocalLinuxActivityBarrier.shared.revision == target.revision, !LocalLinuxActivityBarrier.shared.isSuspended,
              AppLockManager.shared.state != .locked else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(target.row.recipe.displayedCommand, forType: .string)
    }
}

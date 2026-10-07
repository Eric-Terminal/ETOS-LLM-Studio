import AppKit
import Combine
import ETOSCore
import Foundation

struct MacLinuxTerminalRow: Identifiable, Sendable {
    let job: LocalLinuxJob
    let title: String
    var id: UUID { job.id }

    init(_ job: LocalLinuxJob) {
        self.job = job
        title = String(format: NSLocalizedString("终端 %@", comment: ""), String(job.id.uuidString.prefix(8)))
    }
}

struct MacLinuxTerminalKeyRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let data: Data

    init(_ shortcut: LocalLinuxTerminalShortcut) {
        id = shortcut.id; title = shortcut.title; data = shortcut.inputData
    }
}

@MainActor
final class MacLinuxTerminalModel: ObservableObject {
    @Published private(set) var terminals: [MacLinuxTerminalRow] = []
    @Published private(set) var shortcuts: [MacLinuxTerminalKeyRow] = []
    @Published private(set) var job: LocalLinuxJob?
    @Published private(set) var inputOwner: LocalLinuxTerminalInputOwner?
    @Published private(set) var output: [LocalLinuxTerminalDisplayLine] = []
    @Published private(set) var isWorking = false
    @Published private(set) var isOpen = false
    @Published private(set) var lease = UUID()
    @Published var input = ""
    @Published var error: String?

    private var observation: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var initialJobID: UUID?
    private var selectionRevision = UUID()
    private var appearance = LocalLinuxTerminalAppearance.dark
    private var columns: UInt16 = 80
    private var rows: UInt16 = 24

    var canOperate: Bool { isOpen && !isWorking && !LocalLinuxActivityBarrier.shared.isSuspended && AppLockManager.shared.state != .locked }
    var isTerminalActive: Bool { job.map { !$0.state.isTerminal } ?? false }

    func open(initialJobID: UUID?, appearance: LocalLinuxTerminalAppearance) {
        guard !isOpen, !LocalLinuxActivityBarrier.shared.isSuspended else { return }
        isOpen = true; lease = UUID(); self.initialJobID = initialJobID; self.appearance = appearance
        let lease = lease
        observation = Task { [weak self] in
            let services = await MacLinuxServices.shared.value
            for await _ in await services.runtime.updates() {
                guard !Task.isCancelled, let self, self.lease == lease else { return }
                await refresh(services: services, lease: lease)
            }
        }
    }

    func leave() {
        isOpen = false; lease = UUID()
        observation?.cancel(); observation = nil
        outputTask?.cancel(); outputTask = nil; operation?.cancel(); resizeTask?.cancel()
        output = []; terminals = []; shortcuts = []; input = ""; job = nil; inputOwner = nil; isWorking = false
    }

    private func refresh(services: MacLinuxServices, lease: UUID) async {
        let selected = job?.id ?? initialJobID, initial = initialJobID, selectionRevision = selectionRevision
        do {
            let data = try await Task.detached(priority: .utility) {
                try await LocalLinuxActivityBarrier.shared.withActivity {
                    let jobs = await services.scheduler.activeJobs().filter {
                        $0.kind == .terminal && (($0.sessionID == nil && $0.runID == nil) || $0.id == initial)
                    }
                    let selectedJob: LocalLinuxJob?
                    if let selected { selectedJob = await services.scheduler.job(id: selected) }
                    else { selectedJob = jobs.first }
                    let owner: LocalLinuxTerminalInputOwner?
                    if let selectedJob { owner = try? await services.scheduler.terminalInputOwner(jobID: selectedJob.id) }
                    else { owner = nil }
                    let keys = LocalLinuxTerminalShortcutConfiguration.decode(AppConfigStore.textValue(for: .localLinuxTerminalShortcutIDs))
                    return (jobs.map(MacLinuxTerminalRow.init), selectedJob, owner, keys.map(MacLinuxTerminalKeyRow.init))
                }
            }.value
            guard !Task.isCancelled, self.lease == lease, isOpen else { return }
            terminals = data.0; shortcuts = data.3
            guard self.selectionRevision == selectionRevision else { return }
            inputOwner = data.2
            let changed = job?.id != data.1?.id
            job = data.1
            if changed, let job, !job.state.isTerminal { subscribe(job.id) }
        } catch is CancellationError { }
        catch { if self.lease == lease { self.error = error.localizedDescription } }
    }

    func select(_ row: MacLinuxTerminalRow) {
        guard canOperate else { return }
        selectionRevision = UUID(); job = row.job; inputOwner = nil; input = ""; subscribe(row.id)
    }

    func changeAppearance(_ value: LocalLinuxTerminalAppearance) {
        appearance = value
        if isOpen, let job, !job.state.isTerminal { subscribe(job.id) }
    }

    func reloadMetadata() {
        let lease = lease
        Task { [weak self] in
            let services = await MacLinuxServices.shared.value
            guard let self, isOpen, self.lease == lease else { return }
            await refresh(services: services, lease: lease)
        }
    }

    private func subscribe(_ id: UUID) {
        outputTask?.cancel(); output = []
        let lease = lease, appearance = appearance
        outputTask = Task { [weak self] in
            let services = await MacLinuxServices.shared.value
            do {
                let owner = try await services.scheduler.terminalInputOwner(jobID: id)
                guard self?.lease == lease, self?.job?.id == id, !Task.isCancelled else { return }
                self?.inputOwner = owner
                let stream = try await services.scheduler.terminalDisplayUpdates(jobID: id, appearance: appearance, minimumInterval: .milliseconds(100))
                for await lines in stream {
                    guard !Task.isCancelled, let self, self.lease == lease, job?.id == id else { return }
                    output = lines
                }
            } catch is CancellationError { }
            catch { if let self, self.lease == lease, job?.id == id, !Task.isCancelled { self.error = error.localizedDescription } }
        }
        resize(columns: columns, rows: rows)
    }

    func createTerminal() {
        let columns = columns, rows = rows
        perform { services in
            let workspace = try await services.storage.interactiveUserWorkspace()
            let terminal = try await services.scheduler.startTerminal(context: nil, workspace: workspace, inputOwner: .user, columns: columns, rows: rows)
            if Task.isCancelled { await services.scheduler.cancel(jobID: terminal.id); throw CancellationError() }
            return terminal
        } completed: { model, terminal in
            guard let terminal else { return }
            model.selectionRevision = UUID(); model.job = terminal; model.inputOwner = .user; model.input = ""; model.subscribe(terminal.id)
        }
    }

    func sendInput() {
        guard !input.isEmpty, canOperate, isTerminalActive else { return }
        let text = input
        send { Data((text + "\n").utf8) } completed: { model in if model.input == text { model.input = "" } }
    }

    func send(_ data: Data) { send { data } completed: { _ in } }

    private func send(_ data: @escaping @Sendable () -> Data, completed: @escaping (MacLinuxTerminalModel) -> Void) {
        guard let job, !job.state.isTerminal else { return }
        perform { services in
            try await services.scheduler.claimTerminalInput(jobID: job.id, owner: .user)
            try await services.scheduler.sendTerminalInput(jobID: job.id, owner: .user, data: data())
            return nil
        } completed: { model, _ in model.inputOwner = .user; completed(model) }
    }

    func returnToAgent() {
        guard let job, let runID = job.runID else { return }
        perform { services in
            try await services.scheduler.claimTerminalInput(jobID: job.id, owner: .agent(runID: runID))
            return nil
        } completed: { model, _ in model.inputOwner = .agent(runID: runID) }
    }

    func interrupt() {
        guard let job else { return }
        perform { services in try await services.scheduler.interrupt(jobID: job.id); return nil }
    }

    func endTerminal() {
        guard let job else { return }
        perform { services in await services.scheduler.cancel(jobID: job.id); return nil }
    }

    func resize(columns: UInt16, rows: UInt16) {
        self.columns = columns; self.rows = rows
        resizeTask?.cancel()
        guard isOpen, let job, !job.state.isTerminal else { return }
        resizeTask = Task {
            let services = await MacLinuxServices.shared.value
            guard !Task.isCancelled else { return }
            try? await services.scheduler.resizeTerminal(jobID: job.id, columns: columns, rows: rows)
        }
    }

    func copyOutput() {
        let lines = output, lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task { [weak self] in
            let text = await Task.detached(priority: .utility) { lines.map(\.plainText).joined(separator: "\n") }.value
            guard let self, self.lease == lease, canOperate, LocalLinuxActivityBarrier.shared.revision == revision else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func perform(
        _ action: @escaping @Sendable (MacLinuxServices) async throws -> LocalLinuxJob?,
        completed: @escaping (MacLinuxTerminalModel, LocalLinuxJob?) -> Void = { _, _ in }
    ) {
        guard canOperate else { return }
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision
        isWorking = true; error = nil
        operation = Task { [weak self] in
            let task = Task.detached(priority: .userInitiated) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    let services = await MacLinuxServices.shared.value
                    try Task.checkCancellation()
                    return try await action(services)
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let self, self.lease == lease, isOpen else { return }
                completed(self, result)
            } catch is CancellationError { }
            catch { if let self, self.lease == lease { self.error = error.localizedDescription } }
            if let self, self.lease == lease { isWorking = false }
        }
    }
}

import AppKit
import Combine
import ETOSCore
import Foundation

@MainActor
final class MacLinuxJobDetailModel: ObservableObject {
    @Published private(set) var details: MacLinuxJobDetails?
    @Published private(set) var diagnostic: MacLinuxDiagnosticDetails?
    @Published private(set) var output = LocalLinuxRawOutputPage(cursor: .init(), text: "", nextCursor: nil, isComplete: true)
    @Published private(set) var pageNumber = 1
    @Published private(set) var isLoading = false
    @Published private(set) var lease = UUID()
    @Published var error: String?
    @Published var outputError: String?
    private var jobID: UUID?
    private var cursorHistory: [LocalLinuxRawOutputCursor] = []
    private var loading: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingRefresh = false
    private var includesOutput = true

    var canGoBack: Bool { !cursorHistory.isEmpty && !isLoading }
    var canGoForward: Bool { output.nextCursor != nil && !isLoading }

    func open(jobID: UUID, includesOutput: Bool = true) {
        guard self.jobID == nil else { return }
        self.jobID = jobID; self.includesOutput = includesOutput; lease = UUID()
        NotificationCenter.default.publisher(for: .localLinuxJobsDidChange)
            .filter { $0.object == nil || ($0.object as? UUID) == jobID }
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }.store(in: &subscriptions)
        if includesOutput { NotificationCenter.default.publisher(for: .localLinuxJobOutputDidChange)
            .filter { ($0.object as? UUID) == jobID }
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.global(qos: .utility), latest: true)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, output.nextCursor == nil else { return }
                reload()
            }.store(in: &subscriptions)
        }
        reload()
    }

    func leave(clearContent: Bool = true) {
        jobID = nil; lease = UUID(); loading?.cancel(); subscriptions.removeAll()
        // 普通进入子页保留导航源和阅读位置；宿主数据操作才丢弃旧数据库快照。
        if clearContent {
            details = nil; diagnostic = nil; cursorHistory = []; pageNumber = 1
            output = LocalLinuxRawOutputPage(cursor: .init(), text: "", nextCursor: nil, isComplete: true)
        }
        pendingRefresh = false; isLoading = false; error = nil; outputError = nil
    }

    func reload() {
        guard !isLoading else { pendingRefresh = true; return }
        load(cursor: output.cursor, history: cursorHistory)
    }

    func previousPage() {
        guard canGoBack, let cursor = cursorHistory.last else { return }
        var history = cursorHistory; history.removeLast()
        load(cursor: cursor, history: history)
    }

    func nextPage() {
        guard canGoForward, let cursor = output.nextCursor else { return }
        var history = cursorHistory; history.append(output.cursor)
        load(cursor: cursor, history: history)
    }

    private func load(cursor: LocalLinuxRawOutputCursor, history: [LocalLinuxRawOutputCursor]) {
        guard let jobID, !LocalLinuxActivityBarrier.shared.isSuspended else { return }
        isLoading = true; error = nil
        let lease = lease, revision = LocalLinuxActivityBarrier.shared.revision, includesOutput = includesOutput
        loading = Task { [weak self] in
            let task = Task.detached(priority: .utility) {
                try await LocalLinuxActivityBarrier.shared.withActivity(expectedRevision: revision) {
                    let services = await MacLinuxServices.shared.value
                    guard let job = await services.scheduler.job(id: jobID) else { throw LocalLinuxRuntimeError.jobNotFound(jobID) }
                    let stored = job.diagnosticID.flatMap { Persistence.loadLocalLinuxDiagnostic(id: $0) }
                    let details = try MacLinuxJobDetails.prepare(job)
                    let diagnostic = try stored.map(MacLinuxDiagnosticDetails.prepare)
                    var page: LocalLinuxRawOutputPage?
                    var outputError: String?
                    if includesOutput {
                        do { page = try await services.scheduler.userVisibleOutputPage(jobID: jobID, cursor: cursor, maximumBytes: 65_536) }
                        catch { outputError = error.localizedDescription }
                    }
                    return (details, diagnostic, page, outputError)
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let self, self.lease == lease, !Task.isCancelled else { return }
                details = result.0; diagnostic = result.1; outputError = result.3
                // 文件读取失败保留原页与导航栈，避免一次失败导致上一页也丢失。
                if let page = result.2 { output = page; cursorHistory = history; pageNumber = history.count + 1 }
            } catch is CancellationError { }
            catch { if let self, self.lease == lease { self.error = error.localizedDescription } }
            guard let self, self.lease == lease else { return }
            isLoading = false
            if pendingRefresh { pendingRefresh = false; reload() }
        }
    }

    func copyOutput() { copy(output.text) }
    func copyDiagnostic() { if let diagnostic { copy(diagnostic.json) } }

    private func copy(_ value: String) {
        guard jobID != nil, !LocalLinuxActivityBarrier.shared.isSuspended, AppLockManager.shared.state != .locked else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
}

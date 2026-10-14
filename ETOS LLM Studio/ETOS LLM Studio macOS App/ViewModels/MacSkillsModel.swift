import Combine
import ETOSCore
import Foundation

@MainActor
final class MacSkillsModel: ObservableObject {
    @Published private(set) var rows: [MacSkillRow] = []
    @Published private(set) var guideRows: JSONValue = .array([])
    @Published private(set) var chatToolsEnabled = false
    @Published private(set) var enabledNames: Set<String> = []
    @Published private(set) var detail: MacSkillDetailPresentation?
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var isPreparingImport = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published var query = "" { didSet { refresh() } }
    @Published var enabledOnly = false { didSet { refresh() } }
    @Published var error: String?
    private var manager: SkillManager?
    private var subscription: AnyCancellable?
    private var presentationTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var writeTask: Task<String?, Error>?
    private var importTask: Task<MacSkillImportPreview, Error>?
    private var presentationID = UUID()
    private var detailID = UUID()
    private var openDetailName: String?
    private var sessionIsolated = false
    var canWrite: Bool { isLoaded && !isWorking && !isPreparingImport && !isSuspended && AppLockManager.shared.state != .locked }

    func start() async {
        guard manager == nil else { return }
        let manager = await SkillManager.prepareSharedInBackground()
        guard self.manager == nil else { return }
        self.manager = manager; isLoaded = true
        subscription = manager.objectWillChange.debounce(for: .milliseconds(50), scheduler: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            refresh()
            // 同步或沙盒工具也能修改资源；打开的详情必须随目录通知重新准备快照。
            if let openDetailName { openDetail(openDetailName) }
        }
        refresh()
    }

    func setSessionIsolation(_ isolated: Bool) { sessionIsolated = isolated; refresh() }

    func refreshLanguage() {
        refresh()
        if let detail { openDetail(detail.source.metadata.name) }
    }

    func refresh() {
        guard let manager, !isSuspended else { return }
        chatToolsEnabled = manager.chatToolsEnabled; enabledNames = manager.enabledSkillNames
        let skills = manager.skills, enabled = manager.enabledSkillNames, group = manager.chatToolsEnabled
        let isolated = sessionIsolated, query = query, enabledOnly = enabledOnly
        presentationTask?.cancel(); presentationID = UUID()
        let id = presentationID
        presentationTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                MacSkillPresentation.prepare(skills: skills, enabled: enabled, group: group,
                                             isolated: isolated, query: query, enabledOnly: enabledOnly)
            }.value
            guard let self, !Task.isCancelled, id == presentationID, !isSuspended else { return }
            rows = result.0; guideRows = result.1
        }
    }

    func openDetail(_ name: String) {
        guard let manager, !isSuspended else { return }
        openDetailName = name
        detailTask?.cancel(); detailID = UUID(); detail = nil; isLoadingDetail = true; error = nil
        let id = detailID
        detailTask = Task { [weak self] in
            do {
                let source = try await manager.loadLibraryDetailInBackground(name: name)
                let prepared = await Task.detached(priority: .utility) { MacSkillDetailPresentation(source) }.value
                guard let self, !Task.isCancelled, id == detailID, !isSuspended else { return }
                detail = prepared; isLoadingDetail = false
            } catch {
                guard let self, !Task.isCancelled, id == detailID, !isSuspended else { return }
                self.error = error.localizedDescription; isLoadingDetail = false
            }
        }
    }

    func closeDetail() { detailTask?.cancel(); detailID = UUID(); openDetailName = nil; detail = nil; isLoadingDetail = false }

    @discardableResult
    func mutate(_ mutation: SkillLibraryMutation, expectedEpoch: UUID) async throws -> String? {
        guard canWrite, epoch == expectedEpoch, let manager else { throw MacMemoryWriteError.busy }
        isWorking = true
        let task = Task { try await manager.mutateLibraryInBackground(mutation) }
        writeTask = task
        defer { isWorking = false; writeTask = nil; refresh() }
        return try await task.value
    }

    func reload() {
        guard let manager, !isSuspended else { return }
        reloadTask?.cancel()
        let token = epoch
        reloadTask = Task { [weak self] in
            do {
                try await manager.reloadLibraryInBackground()
                guard let self, !Task.isCancelled, token == epoch, !isSuspended else { return }
                isLoaded = true; refresh()
            } catch {
                guard let self, !Task.isCancelled, token == epoch, !isSuspended else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func prepareImport(_ source: MacSkillImportSource, expectedEpoch: UUID) async throws -> MacSkillImportPreview {
        guard canWrite, epoch == expectedEpoch else { throw MacMemoryWriteError.busy }
        isPreparingImport = true
        let task = Task.detached(priority: .utility) { try await MacSkillImportPreview.prepare(source) }
        importTask = task
        defer { isPreparingImport = false; importTask = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !task.isCancelled, !isSuspended, epoch == expectedEpoch,
              AppLockManager.shared.state != .locked else { throw CancellationError() }
        return result
    }

    func cancelImport() { importTask?.cancel() }

    func suspend() {
        isSuspended = true; epoch = UUID(); presentationID = UUID()
        presentationTask?.cancel(); reloadTask?.cancel(); importTask?.cancel(); closeDetail()
    }

    func resume() { isSuspended = false; isLoaded = false; reload() }

    func waitForPendingWrites() async {
        _ = try? await writeTask?.value
        _ = try? await importTask?.value
        await reloadTask?.value; await detailTask?.value; await presentationTask?.value
    }
}

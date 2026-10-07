import Combine
import ETOSCore
import Foundation

@MainActor
final class MacBuiltInToolsModel: ObservableObject {
    @Published private(set) var rows: [MacBuiltInToolPresentation] = []
    @Published private(set) var allRows: [ToolCatalogBuiltInToolKind: MacBuiltInToolPresentation] = [:]
    @Published private(set) var guideRows: JSONValue = .array([])
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published var query = "" { didSet { refresh() } }
    @Published var enabledOnly = false { didSet { refresh() } }
    @Published var error: String?
    private var manager: AppToolManager?
    private var subscriptions: Set<AnyCancellable> = []
    private var presentationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Error>?
    private var presentationID = UUID()
    private var memoryIsolated = false
    private var toolsIsolated = false

    var canWrite: Bool { isLoaded && !isWorking && !isSuspended && AppLockManager.shared.state != .locked }

    func start() async {
        guard manager == nil else { refresh(); return }
        let manager = await AppToolManager.prepareSharedInBackground()
        guard self.manager == nil else { return }
        self.manager = manager; isLoaded = true
        manager.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        let config = AppConfigStore.shared
        Publishers.CombineLatest4(config.$enableMemory, config.$enableMemoryWrite, config.$enableMemoryActiveRetrieval, config.$memoryTopK)
            .dropFirst().removeDuplicates { $0 == $1 }.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        config.$appLanguage.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    func setIsolation(memory: Bool, tools: Bool) { memoryIsolated = memory; toolsIsolated = tools; refresh() }

    func refresh() {
        guard let manager, !isSuspended else { return }
        let config = AppConfigStore.shared
        let memory = config.enableMemory, write = config.enableMemoryWrite, retrieve = config.enableMemoryActiveRetrieval, topK = config.memoryTopK
        let widget = manager.isToolEnabled(.showWidget), ask = manager.isToolEnabled(.askUserInput), time = manager.isToolEnabled(.getSystemTime)
        let memoryIsolated = memoryIsolated, toolsIsolated = toolsIsolated, query = query, enabledOnly = enabledOnly
        presentationTask?.cancel(); presentationID = UUID()
        let token = presentationID
        presentationTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                let states = ToolCatalogSupport.builtInToolStates(
                    enableMemory: memory, enableMemoryWrite: write, enableMemoryActiveRetrieval: retrieve, memoryTopK: topK,
                    enableWidgetTool: widget, enableAskUserInputTool: ask, enableGetSystemTimeTool: time,
                    isMemoryIsolated: memoryIsolated, isToolIsolated: toolsIsolated)
                return MacBuiltInToolPresentation.prepare(states: states, query: query, enabledOnly: enabledOnly)
            }.value
            guard let self, !Task.isCancelled, token == presentationID, !isSuspended else { return }
            rows = prepared.rows; allRows = prepared.all; guideRows = prepared.guide
        }
    }

    func isEnabled(_ kind: AppToolKind) -> Bool { manager?.isToolEnabled(kind) ?? false }

    func setEnabled(_ value: Bool, kind: AppToolKind, expectedEpoch: UUID) async throws {
        guard canWrite, epoch == expectedEpoch, let manager else { throw MacMemoryWriteError.busy }
        isWorking = true
        let task = Task { try await manager.setBuiltInToolEnabledInBackground(kind: kind, isEnabled: value) }
        writeTask = task
        defer { writeTask = nil; isWorking = false; refresh() }
        try await task.value
    }

    func suspend() {
        isSuspended = true; epoch = UUID(); presentationID = UUID(); presentationTask?.cancel()
    }

    func resume() { isSuspended = false; refresh() }

    func waitForPendingWrites() async {
        _ = try? await writeTask?.value
        await presentationTask?.value
    }
}

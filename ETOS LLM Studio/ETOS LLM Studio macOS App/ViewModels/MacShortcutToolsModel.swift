import Combine
import ETOSCore
import Foundation

struct MacShortcutToolRow: Identifiable, Sendable {
    let tool: ShortcutToolDefinition
    let title: String
    let description: String
    let status: String
    let schema: String?
    var id: UUID { tool.id }
}

@MainActor
final class MacShortcutToolsModel: ObservableObject {
    @Published private(set) var rows: [MacShortcutToolRow] = []
    @Published private(set) var guideRows: JSONValue = .array([])
    @Published private(set) var chatToolsEnabled = false
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published var query = "" { didSet { refresh() } }
    @Published var enabledOnly = false { didSet { refresh() } }
    @Published var error: String?
    private var manager: ShortcutToolManager?
    private var subscription: AnyCancellable?
    private var presentationTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var writeTask: Task<Void, Error>?
    private var presentationID = UUID()
    private var sessionIsolated = false

    var canWrite: Bool { isLoaded && !isWorking && !isSuspended && AppLockManager.shared.state != .locked }

    func start() async {
        guard manager == nil else { refresh(); return }
        let manager = await ShortcutToolManager.prepareSharedInBackground()
        guard self.manager == nil else { return }
        self.manager = manager; isLoaded = true
        subscription = manager.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func setSessionIsolation(_ value: Bool) { sessionIsolated = value; refresh() }

    func refresh() {
        guard let manager, !isSuspended else { return }
        chatToolsEnabled = manager.chatToolsEnabled
        let tools = manager.tools, enabled = manager.chatToolsEnabled, isolated = sessionIsolated
        let query = query, enabledOnly = enabledOnly
        presentationTask?.cancel(); presentationID = UUID()
        let token = presentationID
        presentationTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                Self.prepare(tools: tools, enabled: enabled, isolated: isolated, query: query, enabledOnly: enabledOnly)
            }.value
            guard let self, !Task.isCancelled, token == presentationID, !isSuspended else { return }
            rows = prepared.0; guideRows = prepared.1
        }
    }

    nonisolated static func prepare(
        tools: [ShortcutToolDefinition], enabled: Bool, isolated: Bool, query: String, enabledOnly: Bool
    ) -> ([MacShortcutToolRow], JSONValue) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = tools.filter { tool in
            (!enabledOnly || tool.isEnabled) && (query.isEmpty || [tool.name, tool.displayName, tool.effectiveDescription]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }.map { tool in
            let status: String
            if isolated { status = NSLocalizedString("当前会话已屏蔽相关上下文，因此不会实际启用该工具。", comment: "") }
            else if !enabled { status = NSLocalizedString("快捷指令工具总开关已关闭。", comment: "") }
            else { status = tool.isEnabled ? NSLocalizedString("已启用", comment: "") : NSLocalizedString("未启用", comment: "") }
            return MacShortcutToolRow(tool: tool, title: tool.displayName, description: tool.effectiveDescription,
                                      status: status, schema: tool.metadata["inputSchema"]?.prettyPrintedCompact())
        }
        let guide: JSONValue = .array(rows.map { row in .dictionary([
            "id": .string(row.id.uuidString), "name": .string(row.tool.name), "display_name": .string(row.title),
            "enabled": .bool(row.tool.isEnabled), "run_mode": .string(row.tool.runModeHint.rawValue),
            "available_to_model": .bool(enabled && row.tool.isEnabled && !isolated)
        ]) })
        return (rows, guide)
    }

    func setEnabled(_ value: Bool, expectedEpoch: UUID) async throws {
        try await perform(expectedEpoch: expectedEpoch) { try await $0.setChatToolsEnabledInBackground(value) }
    }

    func save(_ original: ShortcutToolDefinition, enabled: Bool, runMode: ShortcutRunModeHint,
              description: String, expectedEpoch: UUID) async throws {
        try await perform(expectedEpoch: expectedEpoch) {
            try await $0.saveSettingsInBackground(original: original, isEnabled: enabled, runMode: runMode, userDescription: description)
        }
    }

    private func perform(expectedEpoch: UUID, action: @escaping @MainActor (ShortcutToolManager) async throws -> Void) async throws {
        guard canWrite, epoch == expectedEpoch, let manager else { throw MacMemoryWriteError.busy }
        isWorking = true
        let task = Task { try await action(manager) }
        writeTask = task
        defer { isWorking = false; writeTask = nil; refresh() }
        try await task.value
    }

    func suspend() {
        isSuspended = true; epoch = UUID()
        presentationTask?.cancel(); reloadTask?.cancel(); presentationID = UUID()
    }

    func resume() {
        guard isSuspended else { refresh(); return }
        isSuspended = false
        guard let manager else { return }
        isLoaded = false
        reloadTask = Task { [weak self] in
            await manager.reloadToolsInBackground()
            guard !Task.isCancelled else { return }
            self?.isLoaded = true
            self?.refresh()
        }
    }

    func waitForPendingWrites() async {
        _ = try? await writeTask?.value
        await reloadTask?.value
        await presentationTask?.value
    }
}

import Combine
import ETOSCore
import Foundation

struct MacAgentPromptRow: Identifiable, Sendable {
    let profile: LocalAgentPromptProfile
    let title: String
    let preview: String
    let isSelected: Bool
    var id: UUID { profile.id }
}

struct MacAgentPromptPresentation: Sendable {
    let rows: [MacAgentPromptRow]
    let guideRows: JSONValue
    let selection: String
    let effectiveSelection: String

    static func prepare(_ snapshot: LocalAgentPromptLibrarySnapshot) -> Self {
        let effective = snapshot.effectiveProfileID
        let rows = snapshot.profiles.map { profile in
            let title = profile.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return MacAgentPromptRow(profile: profile,
                title: title.isEmpty ? NSLocalizedString("未命名提示词", comment: "") : title,
                preview: profile.content.isEmpty ? NSLocalizedString("空提示词（不发送）", comment: "") : String(profile.content.prefix(120)),
                isSelected: profile.isEnabled && profile.id == effective)
        }
        return Self(rows: rows, guideRows: .array(rows.map { row in .dictionary([
            "id": .string(row.id.uuidString), "title": .string(row.title), "enabled": .bool(row.profile.isEnabled),
            "built_in": .bool(row.profile.isBuiltIn), "selected": .bool(row.isSelected)
        ]) }), selection: snapshot.selectedProfileID, effectiveSelection: effective.uuidString)
    }
}

@MainActor
final class MacAgentPromptModel: ObservableObject {
    @Published private(set) var rows: [MacAgentPromptRow] = []
    @Published private(set) var guideRows: JSONValue = .array([])
    @Published private(set) var selection = ""
    @Published private(set) var effectiveSelection = ""
    @Published private(set) var isLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published private(set) var revision = UUID()
    @Published var error: String?
    private var loading: Task<Void, Never>?
    private var writing: Task<Void, Error>?
    private var loadID = UUID()

    var canWrite: Bool { isLoaded && !isLoading && !isWorking && !isSuspended && AppLockManager.shared.state != .locked }

    func reload() {
        guard !isSuspended, !isWorking else { return }
        let previous = loading
        previous?.cancel(); loadID = UUID()
        let loadID = loadID, epoch = epoch
        isLoading = true
        loading = Task { [weak self] in
            // 取消不代表已经退出数据库；保留前一读取的收尾链，供恢复/退出等待。
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await LocalAgentPromptLibrary.shared.snapshot()
                let prepared = await Task.detached(priority: .utility) { MacAgentPromptPresentation.prepare(snapshot) }.value
                guard let self, !Task.isCancelled, self.loadID == loadID, self.epoch == epoch, !isSuspended else { return }
                apply(prepared); isLoading = false; error = nil
            } catch {
                guard let self, !Task.isCancelled, self.loadID == loadID, self.epoch == epoch else { return }
                isLoading = false; self.error = error.localizedDescription
            }
        }
    }

    func save(_ draft: LocalAgentPromptProfile, original: LocalAgentPromptProfile?, expectedEpoch: UUID) async throws {
        try await mutate(expectedEpoch: expectedEpoch) { try await LocalAgentPromptLibrary.shared.save(draft, original: original) }
    }

    func delete(_ profile: LocalAgentPromptProfile, expectedEpoch: UUID) async throws {
        try await mutate(expectedEpoch: expectedEpoch) { try await LocalAgentPromptLibrary.shared.delete(profile) }
    }

    func select(_ profile: LocalAgentPromptProfile, expectedSelection: String, expectedEpoch: UUID) async throws {
        try await mutate(expectedEpoch: expectedEpoch) {
            try await LocalAgentPromptLibrary.shared.select(profile, expectedSelection: expectedSelection)
        }
    }

    private func mutate(expectedEpoch: UUID, operation: @escaping @Sendable () async throws -> LocalAgentPromptLibrarySnapshot) async throws {
        guard canWrite, epoch == expectedEpoch else { throw MacMemoryWriteError.busy }
        isWorking = true; error = nil
        let task = Task { [weak self] in
            await AppConfigStore.shared.flushPendingWrites()
            let snapshot = try await operation()
            let prepared = await Task.detached(priority: .utility) { MacAgentPromptPresentation.prepare(snapshot) }.value
            guard let self, epoch == expectedEpoch, !isSuspended else { return }
            apply(prepared)
        }
        writing = task
        defer {
            writing = nil; isWorking = false
            if epoch != expectedEpoch && !isSuspended { reload() }
        }
        try await task.value
    }

    private func apply(_ prepared: MacAgentPromptPresentation) {
        revision = UUID()
        rows = prepared.rows; guideRows = prepared.guideRows
        selection = prepared.selection; effectiveSelection = prepared.effectiveSelection; isLoaded = true
    }

    func suspend() {
        isSuspended = true; epoch = UUID(); loadID = UUID(); loading?.cancel()
        isLoaded = false; isLoading = false
    }

    func resume() { isSuspended = false; if !rows.isEmpty { reload() } }

    func waitForPendingWrites() async {
        _ = try? await writing?.value
        await loading?.value
    }
}

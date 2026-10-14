import Combine
import ETOSCore
import Foundation

struct MacConversationSummaryRow: Identifiable, Sendable {
    let source: ConversationSessionSummary
    let date: String
    var id: UUID { source.id }
}

struct MacProfileFactRow: Identifiable, Sendable {
    let id: UUID
    let statement: String
    let evidence: String
}

struct MacProfileFactGroup: Identifiable, Sendable {
    let id: ConversationProfileFactCategory
    let title: String
    let rows: [MacProfileFactRow]
}

struct MacConversationMemoryPresentation: Sendable {
    let summaries: [MacConversationSummaryRow]
    let summariesByID: [UUID: MacConversationSummaryRow]
    let profile: ConversationUserProfile?
    let profileDate: String
    let factGroups: [MacProfileFactGroup]
    let guideFacts: JSONValue

    init(_ snapshot: ConversationMemoryStateSnapshot = .init(sessionSummaries: [], userProfile: nil)) {
        summaries = snapshot.sessionSummaries.map {
            MacConversationSummaryRow(source: $0, date: $0.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        summariesByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        profile = snapshot.userProfile
        profileDate = snapshot.userProfile?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? ""
        let facts = snapshot.userProfile?.facts ?? []
        let grouped = Dictionary(grouping: facts, by: \.category)
        factGroups = ConversationProfileFactCategory.allCases.compactMap { category in
            guard let values = grouped[category], !values.isEmpty else { return nil }
            return MacProfileFactGroup(id: category, title: category.localizedTitle, rows: values.map {
                MacProfileFactRow(id: $0.id, statement: $0.statement, evidence: String(
                    format: NSLocalizedString("置信度 %.0f%% · %d 条证据", comment: ""), $0.confidence * 100, $0.evidenceCount
                ))
            })
        }
        guideFacts = .array(facts.map { .dictionary([
            "category": .string($0.category.rawValue), "statement": .string($0.statement),
            "confidence": .double($0.confidence), "evidence_count": .int($0.evidenceCount)
        ]) })
    }
}

@MainActor
final class MacConversationMemoryModel: ObservableObject {
    @Published private(set) var presentation = MacConversationMemoryPresentation()
    @Published private(set) var models: [RunnableModel] = []
    @Published private(set) var modelIDs: [String] = [""]
    @Published private(set) var modelIDSet: Set<String> = [""]
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published var error: String?
    private var subscriptions = Set<AnyCancellable>()
    private var refreshTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var started = false

    func start(service: ChatService?) {
        guard !started, let service else { return }
        started = true
        NotificationCenter.default.publisher(for: .conversationMemoryDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .snapshotRestoreDidFinish))
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
            .store(in: &subscriptions)
        AppConfigStore.shared.$appLanguage.dropFirst().sink { [weak self] _ in self?.reload() }
            .store(in: &subscriptions)
        service.providersSubject.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.reloadModels(service)
        }.store(in: &subscriptions)
        reload()
    }

    func reload() {
        guard started else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let snapshot = await ConversationMemoryManager.loadStateSnapshotAsync()
            let presentation = await Task.detached(priority: .utility) {
                MacConversationMemoryPresentation(snapshot)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.presentation = presentation
            isLoaded = true
        }
    }

    private func reloadModels(_ service: ChatService) {
        modelTask?.cancel()
        modelTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let models = service.activatedChatModels
                let ids = [""] + models.map(\.id)
                return (models, ids, Set(ids))
            }.value
            guard let self, !Task.isCancelled else { return }
            models = result.0
            modelIDs = result.1
            modelIDSet = result.2
        }
    }

    func saveProfile(content: String, original: ConversationUserProfile?) async throws {
        guard !isWorking else { throw MacMemoryWriteError.busy }
        isWorking = true
        defer { isWorking = false; reload() }
        try await Task.detached(priority: .userInitiated) {
            try ConversationMemoryManager.saveUserProfileDraft(content: content, expectedProfile: original)
        }.value
    }

    func deleteSummary(id: UUID) async {
        await performDeletion { ConversationMemoryManager.removeSessionSummary(sessionID: id) }
    }

    func clearSummaries() async {
        await performDeletion { _ = ConversationMemoryManager.clearAllSessionSummaries() }
    }

    func clearProfile() async {
        await performDeletion { try ConversationMemoryManager.clearUserProfile() }
    }

    private func performDeletion(_ operation: @escaping @Sendable () throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false; reload() }
        do { try await Task.detached(priority: .userInitiated, operation: operation).value }
        catch { self.error = error.localizedDescription }
    }
}

import Combine
import ETOSCore
import Foundation

struct MacMemoryRow: Identifiable {
    let item: MemoryItem
    let preview: String
    let date: String
    let entitiesText: String
    var id: UUID { item.id }
}

@MainActor
final class MacMemoryModel: ObservableObject {
    @Published private(set) var rows: [MacMemoryRow] = []
    @Published private(set) var embeddingModels: [RunnableModel] = []
    @Published private(set) var embeddingModelIDs: [String] = [""]
    @Published private(set) var embeddingModelIDSet: Set<String> = [""]
    @Published private(set) var memoryTitles: [UUID: String] = [:]
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var progress: MemoryEmbeddingProgress?
    @Published private(set) var reembeddingResults: [MemoryReembeddingItemResult] = []
    @Published var error: String?
    @Published var query = "" { didSet { refreshRows() } }
    @Published var showsArchived = false { didSet { refreshRows() } }
    private var manager: MemoryManager?
    private var memories: [MemoryItem] = []
    private var subscriptions = Set<AnyCancellable>()
    private var preparationTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var isStarting = false

    func start(service: ChatService?) async {
        guard let service, !isLoaded, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let manager = await Task.detached { MemoryManager.shared }.value
        self.manager = manager
        manager.memoriesPublisher.receive(on: DispatchQueue.main).sink { [weak self] memories in
            self?.memories = memories
            self?.refreshRows()
        }.store(in: &subscriptions)
        manager.embeddingErrorPublisher.receive(on: DispatchQueue.main).sink { [weak self] error in
            self?.error = error.localizedDescription
        }.store(in: &subscriptions)
        manager.embeddingProgressPublisher.receive(on: DispatchQueue.main).sink { [weak self] progress in
            self?.progress = progress
        }.store(in: &subscriptions)
        service.providersSubject.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshEmbeddingModels(service)
        }.store(in: &subscriptions)
        _ = await manager.getAllMemories()
        isLoaded = true
    }

    private func refreshEmbeddingModels(_ service: ChatService) {
        modelTask?.cancel()
        modelTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let models = service.configuredRunnableModels.filter { $0.model.supportsEmbedding }
                let ids = [""] + models.map(\.id)
                return (models, ids, Set(ids))
            }.value
            guard let self, !Task.isCancelled else { return }
            embeddingModels = result.0
            embeddingModelIDs = result.1
            embeddingModelIDSet = result.2
        }
    }

    private func refreshRows() {
        preparationTask?.cancel()
        let memories = memories
        let query = query
        let archived = showsArchived
        preparationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let rows = memories.filter {
                    $0.isArchived == archived && (query.isEmpty || $0.content.localizedStandardContains(query))
                }.sorted { $0.displayDate > $1.displayDate }.map { memory in
                    MacMemoryRow(
                        item: memory, preview: String(memory.content.prefix(180)),
                        date: memory.displayDate.formatted(date: .abbreviated, time: .shortened),
                        entitiesText: memory.entities.joined(separator: ", ")
                    )
                }
                let titles = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, String($0.content.prefix(120))) })
                return (rows, titles)
            }.value
            guard let self, !Task.isCancelled else { return }
            rows = result.0
            memoryTitles = result.1
        }
    }

    func save(_ draft: MemoryItem, entitiesText: String, replacing original: MemoryItem?) async throws {
        guard let manager, !isWorking else { throw MacMemoryWriteError.busy }
        isWorking = true
        defer { isWorking = false }
        await AppConfigStore.shared.flushPendingWrites()
        try await Task.detached(priority: .userInitiated) {
            var draft = draft
            draft.content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !draft.content.isEmpty else { throw MemoryEmbeddingError.emptyInput }
            draft.entities = entitiesText.components(separatedBy: CharacterSet(charactersIn: ",，"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if let original {
                let existing = await manager.getAllMemories().first { $0.id == original.id }
                guard let existing, MemoryVersionSnapshot(memory: existing) == MemoryVersionSnapshot(memory: original) else {
                    throw MacMemoryWriteError.changedExternally
                }
                // 向量与检索统计由核心维护，编辑器只更新用户可写字段。
                draft.embedding = existing.embedding
                draft.accessCount = existing.accessCount
                draft.lastAccessedAt = existing.lastAccessedAt
                guard await manager.updateMemory(item: draft, expectedSnapshot: MemoryVersionSnapshot(memory: original)) else {
                    throw MacMemoryWriteError.writeFailed
                }
            } else {
                let created = await manager.addMemory(MemoryWriteRequest(
                    content: draft.content, kind: draft.kind, source: .manual,
                    importance: draft.importance, confidence: draft.confidence, entities: draft.entities,
                    validFrom: draft.validFrom, validUntil: draft.validUntil
                ))
                guard created != nil else { throw MacMemoryWriteError.writeFailed }
            }
        }.value
    }

    func delete(_ item: MemoryItem) async {
        guard let manager, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await Task.detached(priority: .userInitiated) { await manager.deleteMemories([item]) }.value
    }

    func reembed(_ item: MemoryItem? = nil) async {
        guard let manager, !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        let limit = max(1, AppConfigStore.shared.memoryReembeddingConcurrencyLimit)
        let previousResults = reembeddingResults
        await AppConfigStore.shared.flushPendingWrites()
        do {
            reembeddingResults = try await Task.detached(priority: .userInitiated) {
                if let item {
                    let results = try await manager.reembedMemories(withIDs: [item.id], concurrencyLimit: limit)
                    guard let result = results.first else { return previousResults }
                    if previousResults.contains(where: { $0.memoryID == item.id }) {
                        return previousResults.map { $0.memoryID == item.id ? result : $0 }
                    }
                    return previousResults + results
                }
                return try await manager.reembedAllMemoriesDetailed(concurrencyLimit: limit)
            }.value
        } catch { self.error = error.localizedDescription }
    }

    func retryEmbedding(id: UUID) async {
        guard let item = memories.first(where: { $0.id == id }) else { return }
        await reembed(item)
    }
}

enum MacMemoryWriteError: LocalizedError {
    case writeFailed
    case changedExternally
    case busy
    var errorDescription: String? {
        switch self {
        case .writeFailed: NSLocalizedString("无法保存记忆，请刷新列表后重试。", comment: "")
        case .changedExternally: NSLocalizedString("记忆已在其他位置修改，请重新打开后再编辑。", comment: "")
        case .busy: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
        }
    }
}

import Combine
import ETOSCore
import Foundation

/// 文件任务由工作区持有，关闭设置窗口不会让备份或退出遗漏仍在写入的任务。
@MainActor
final class MacLocalModelLibraryModel: ObservableObject {
    @Published private(set) var rows: [MacLocalModelRow] = []
    @Published private(set) var guideRows: JSONValue = .array([])
    @Published private(set) var isLoaded = false
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = false
    @Published private(set) var epoch = UUID()
    @Published var error: String?
    let download: MacLocalModelDownload
    private var store: LocalModelStore?
    private var subscription: AnyCancellable?
    private var presentationTask: Task<Void, Never>?
    private var writeTask: Task<Bool, Never>?
    private var presentationID = UUID()
    private var writeID = UUID()

    var canWrite: Bool { isLoaded && !isWorking && !isSuspended }

    init(store: LocalModelStore? = nil, downloadTransport: @escaping MacLocalModelDownload.Transport = { request, progress in
        try await SyncPackageUploadService.downloadTemporaryFile(request: request, progress: progress)
    }) {
        download = MacLocalModelDownload(transport: downloadTransport)
        if let store { attach(store) }
    }

    func start() async {
        guard store == nil else { refresh(); return }
        let store = await Task.detached { LocalModelStore.shared }.value
        guard self.store == nil else { return }
        attach(store)
    }

    private func attach(_ store: LocalModelStore) {
        self.store = store
        subscription = store.objectWillChange.sink { [weak self] in self?.refresh() }
        isLoaded = true
        refresh()
    }

    func refresh() {
        guard let store, !isSuspended else { return }
        presentationTask?.cancel(); presentationID = UUID()
        let token = presentationID
        presentationTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                let rows = store.models.map { MacLocalModelRow(record: $0, store: store) }
                let guide: JSONValue = .array(rows.map { .dictionary([
                    "id": .string($0.id.uuidString), "name": .string($0.title),
                    "activated": .bool($0.record.isActivated), "file_available": .bool($0.fileExists),
                    "architecture": .string($0.record.ggufArchitecture ?? "")
                ]) })
                return (rows, guide)
            }.value
            guard let self, !Task.isCancelled, token == presentationID, !isSuspended else { return }
            rows = prepared.0; guideRows = prepared.1
        }
    }

    func editorSource(for row: MacLocalModelRow) async -> MacLocalModelEditorSource? {
        guard canWrite, let store else { return nil }
        let token = epoch
        let source = await Task.detached { () -> MacLocalModelEditorSource? in
            let rows = store.models.map { MacLocalModelRow(record: $0, store: store) }
            guard let current = rows.first(where: { $0.id == row.id }) else { return nil }
            return MacLocalModelEditorSource(row: current, rows: rows)
        }.value
        guard canWrite, token == epoch, !Task.isCancelled else { return nil }
        if case .none = source { error = LocalModelDraftWriteError.changedExternally.localizedDescription }
        return source
    }

    func importFiles(_ urls: [URL], expectedEpoch: UUID) async -> Bool {
        guard canWrite, expectedEpoch == epoch else { return false }
        return await perform { store in
            let selection = try Self.importSelection(urls)
            for (index, url) in selection.weights.enumerated() {
                _ = try store.importModel(from: url, mmprojURL: index == 0 ? selection.projector : nil)
            }
        }
    }

    func startDownload(urlText: String, displayName: String, expectedEpoch: UUID) -> UUID? {
        guard canWrite, expectedEpoch == epoch, let store else { return nil }
        isWorking = true; writeID = UUID()
        let token = writeID
        let task = download.start(urlText: urlText, displayName: displayName, store: store) { [weak self] in
            guard let self else { return false }
            return !isSuspended && epoch == expectedEpoch
        }
        writeTask = Task { [weak self] in
            let succeeded = await task.value
            self?.finishWrite(token)
            return succeeded
        }
        return download.id
    }

    nonisolated static func importSelection(_ urls: [URL]) throws -> (weights: [URL], projector: URL?) {
        let weights = urls.filter { !$0.lastPathComponent.lowercased().contains("mmproj") }
        guard !weights.isEmpty else { throw MacLocalModelInputError.noWeights }
        return (weights, urls.first { $0.lastPathComponent.lowercased().contains("mmproj") })
    }

    func save(_ draft: MacLocalModelDraft, original: LocalModelRecord, expectedEpoch: UUID) async -> Bool {
        guard canWrite, expectedEpoch == epoch else { return false }
        return await perform { store in try draft.save(in: store, replacing: original) }
    }

    func delete(_ original: LocalModelRecord, expectedEpoch: UUID) async -> Bool {
        guard canWrite, expectedEpoch == epoch else { return false }
        return await perform { store in try store.deleteDraft(original) }
    }

    /// 同一向导提案可同时改多个开关，不能因第一个开关开始落盘而丢弃后续字段。
    func updateSetting(_ key: AppConfigKey, enabled: Bool, service: ChatService?) {
        guard isLoaded, !isSuspended else { return }
        let configuration = AppConfigStore.shared
        switch key {
        case .localModelsEnabled: configuration.localModelsEnabled = enabled
        case .localModelPerformanceMonitorEnabled: configuration.localModelPerformanceMonitorEnabled = enabled
        case .localModelCacheEnabled: configuration.localModelCacheEnabled = enabled
        case .localModelKVCacheEnabled: configuration.localModelKVCacheEnabled = enabled
        default: return
        }
        let previous = writeTask
        isWorking = true; writeID = UUID()
        let token = writeID
        writeTask = Task { [weak self] in
            _ = await previous?.value
            await configuration.flushPendingWrites()
            await Task.detached(priority: .utility) {
                if key == .localModelsEnabled { service?.reloadProviders() }
                if !enabled && key == .localModelCacheEnabled { LocalLLMEngine.shared.clearModelCache() }
                if !enabled && key == .localModelKVCacheEnabled { LocalLLMEngine.shared.clearKVCache() }
            }.value
            self?.finishWrite(token)
            return true
        }
    }

    private func perform(_ action: @escaping @Sendable (LocalModelStore) throws -> Void) async -> Bool {
        guard let store else { return false }
        isWorking = true; writeID = UUID()
        let token = writeID
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try action(store) } }.value
            await store.waitForPendingUIUpdates()
            await AppConfigStore.shared.flushPendingWrites()
            if case .failure(let error) = result { self?.error = error.localizedDescription }
            self?.finishWrite(token)
            if case .success = result { return true }
            return false
        }
        writeTask = task
        return await task.value
    }

    private func finishWrite(_ token: UUID) {
        guard token == writeID else { return }
        isWorking = false; writeTask = nil
        refresh()
    }

    func suspend() {
        isSuspended = true; epoch = UUID()
        download.cancel(download.id)
        presentationTask?.cancel(); presentationID = UUID()
    }

    func resume() { isSuspended = false; refresh() }

    func waitForPendingWrites() async {
        _ = await writeTask?.value
        await presentationTask?.value
    }
}

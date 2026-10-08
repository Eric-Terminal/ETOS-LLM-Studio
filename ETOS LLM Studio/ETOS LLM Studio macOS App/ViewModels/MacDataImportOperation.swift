import ETOSCore
import Foundation

enum MacDataImportOperation {
    case snapshot(URL, password: String?)
    case package(SyncPackage)

    func apply(using service: ChatService) async throws -> SyncMergeSummary? {
        // 数据包与快照共用工作区屏障；磁盘、解码和合并始终离开主执行器。
        try await Task.detached(priority: .userInitiated) { () async throws -> SyncMergeSummary? in
            switch self {
            case .snapshot(let url, let password):
                try SnapshotRestoreService.restoreSnapshot(from: url, password: password)
                return nil
            case .package(let package):
                return await SyncEngine.apply(package: package, chatService: service)
            }
        }.value
    }
}

@MainActor
final class MacDataImportOperations {
    private var pending: Task<SyncMergeSummary?, Error>?
    private var previews: [UUID: (cancel: () -> Void, completion: Task<Void, Never>)] = [:]

    func trackPreview<Value>(_ worker: Task<Value, Error>) -> UUID {
        let id = UUID()
        previews[id] = ({ worker.cancel() }, Task { _ = await worker.result })
        return id
    }

    func finishPreview(_ id: UUID) { previews.removeValue(forKey: id) }

    func cancelPreviews() { for item in previews.values { item.cancel() } }

    func cancelAndWaitForPreviews() async {
        let pending = previews
        for item in pending.values { item.cancel() }
        for item in pending.values { await item.completion.value }
        for id in pending.keys { previews.removeValue(forKey: id) }
    }

    func perform(_ operation: @escaping @MainActor () async throws -> SyncMergeSummary?) async throws -> SyncMergeSummary? {
        guard pending == nil else { throw MacMemoryWriteError.busy }
        // 原生确认后的写入由工作区持有，关页或退出不得取消一半的合并。
        let task = Task { @MainActor in try await operation() }
        pending = task
        defer { pending = nil }
        return try await task.value
    }

    func waitForCompletion() async { _ = try? await pending?.value }
}

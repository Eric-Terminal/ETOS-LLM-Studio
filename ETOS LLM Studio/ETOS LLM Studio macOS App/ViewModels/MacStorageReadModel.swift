import Combine
import ETOSCore
import Foundation

/// 所有存储预览都登记到工作区；取消页面后，数据库替换仍会等待实际读取结束。
@MainActor
final class MacStorageReadModel<Value: Sendable>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var revision = UUID()
    private var worker: Task<Value, Error>?

    func load(workspace: MacWorkspaceModel, operation: @escaping @Sendable () throws -> Value) {
        let previous = worker
        close()
        guard workspace.canManageLocalModels else { return }
        isLoading = true
        let expected = revision
        let worker = Task.detached(priority: .utility) {
            _ = await previous?.result
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        self.worker = worker
        let tracked = workspace.dataImportOperations.trackPreview(worker)
        Task { [weak self, weak workspace] in
            let result = await worker.result
            workspace?.dataImportOperations.finishPreview(tracked)
            guard let self, revision == expected else { return }
            isLoading = false; self.worker = nil
            guard workspace?.canManageLocalModels == true, !worker.isCancelled else { value = nil; return }
            switch result {
            case .success(let value): self.value = value
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func close(clearContent: Bool = true) {
        worker?.cancel(); worker = nil; revision = UUID(); error = nil; isLoading = false
        if clearContent { value = nil }
    }
}

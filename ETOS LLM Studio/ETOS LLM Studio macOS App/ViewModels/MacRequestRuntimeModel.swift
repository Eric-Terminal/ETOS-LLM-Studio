import Combine
import ETOSCore
import Foundation

struct MacRequestRuntimeStore: Sendable {
    var read: @Sendable (MacRequestRuntimeSource) async -> ModelRequestBodyControlState
    var write: @Sendable (ModelRequestBodyControlState, MacRequestRuntimeSource) async -> Void

    static let database = MacRequestRuntimeStore(read: { source in
        await Task.detached { ModelRequestBodyControlRuntimeStore.state(forModelKey: source.modelKey, controls: source.controls) }.value
    }, write: { state, source in
        await Task.detached { ModelRequestBodyControlRuntimeStore.save(state, forModelKey: source.modelKey, controls: source.controls) }.value
    })
}

@MainActor
final class MacRequestRuntimeModel: ObservableObject {
    @Published private(set) var presentation: MacRequestRuntimePresentation?
    @Published private(set) var isWorking = false
    @Published private(set) var isSuspended = false
    @Published private(set) var error: String?
    private(set) var source: MacRequestRuntimeSource?
    private(set) var revision = UUID()
    private var operation: Task<Void, Error>?
    private let store: MacRequestRuntimeStore

    init(store: MacRequestRuntimeStore = .database) { self.store = store }

    func select(_ model: RunnableModel?, sessionID: UUID?, force: Bool = false) {
        guard force || source?.modelKey != model?.id || source?.sessionID != sessionID else { return }
        source = model.map { MacRequestRuntimeSource(model: $0, sessionID: sessionID) }
        reload()
    }

    func reload() {
        revision = UUID()
        presentation = nil
        error = nil
        guard !isSuspended else { return }
        isWorking = true
        let token = revision, source = source, previous = operation, store = store
        operation = Task { [weak self] in
            _ = try? await previous?.value
            let prepared: MacRequestRuntimePresentation?
            if let source {
                let state = await store.read(source)
                prepared = await Task.detached { MacRequestRuntimePresentation(source: source, state: state) }.value
            } else { prepared = nil }
            guard let self, revision == token, !isSuspended else { return }
            presentation = prepared; isWorking = false
        }
    }

    func apply(_ change: MacRequestRuntimeChange, expectedRevision: UUID) async throws {
        guard !isWorking, !isSuspended, revision == expectedRevision, let source, presentation != nil else { throw GuideError.pageChanged }
        let token = UUID(), previous = operation, store = store
        revision = token; isWorking = true; error = nil
        // 已接受的写入不因切换模型而丢失；后续读取及备份/恢复屏障等待同一任务链。
        let task = Task { [weak self] in
            _ = try? await previous?.value
            do {
                let current = await store.read(source)
                let updated = try await Task.detached { try change.applying(to: current, controls: source.controls) }.value
                await store.write(updated, source)
                let prepared = await Task.detached { MacRequestRuntimePresentation(source: source, state: updated) }.value
                if let self, revision == token, !isSuspended { presentation = prepared; isWorking = false }
            } catch {
                if let self, revision == token, !isSuspended { self.error = error.localizedDescription; isWorking = false }
                throw error
            }
        }
        operation = task
        try await task.value
    }

    func suspend() { isSuspended = true; revision = UUID(); presentation = nil }
    func resume() { isSuspended = false; reload() }
    func waitForPendingWrites() async { _ = try? await operation?.value }
}

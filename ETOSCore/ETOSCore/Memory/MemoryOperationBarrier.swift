import Foundation

/// 恢复数据库前关闭入口、取消可取消任务并等待已进入的操作退出；只在后台恢复线程等待。
final class MemoryOperationBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var operations: [UUID: (() -> Void)?] = [:]
    private var isRestoring = false

    var acceptsOperations: Bool {
        condition.lock()
        defer { condition.unlock() }
        return !isRestoring
    }

    func begin(allowDuringRestore: Bool = false) -> UUID? {
        condition.lock()
        defer { condition.unlock() }
        guard !isRestoring || allowDuringRestore else { return nil }
        let id = UUID()
        // 字典值本身可选；使用 updateValue 保留尚未绑定取消句柄的操作。
        operations.updateValue(nil, forKey: id)
        return id
    }

    func finish(_ id: UUID) {
        condition.lock()
        operations.removeValue(forKey: id)
        condition.broadcast()
        condition.unlock()
    }

    func start<T: Sendable>(
        allowDuringRestore: Bool = false,
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () async -> T
    ) -> Task<T, Never>? {
        guard let id = begin(allowDuringRestore: allowDuringRestore) else { return nil }
        let task = Task.detached(priority: priority) { [self] in
            defer { finish(id) }
            return await operation()
        }
        condition.lock()
        let shouldCancel = isRestoring && !allowDuringRestore
        if operations.keys.contains(id) { operations.updateValue({ task.cancel() }, forKey: id) }
        condition.unlock()
        // 关闭入口可能发生在登记和创建 Task 之间，后绑定的句柄也必须收到取消。
        if shouldCancel { task.cancel() }
        return task
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let task = start(operation: {
            do {
                try Task.checkCancellation()
                let value = try await operation()
                try Task.checkCancellation()
                return Result<T, Error>.success(value)
            } catch {
                return .failure(Task.isCancelled ? CancellationError() : error)
            }
        }) else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            let result = await task.value
            return try result.get()
        } onCancel: { task.cancel() }
    }

    /// 返回 false 表示已有恢复持有入口；调用方不能嵌套替换同一份数据库。
    func pauseForRestore() -> Bool {
        condition.lock()
        guard !isRestoring else { condition.unlock(); return false }
        isRestoring = true
        let cancellations = operations.values.compactMap { $0 }
        condition.unlock()
        cancellations.forEach { $0() }
        condition.lock()
        while !operations.isEmpty { condition.wait() }
        condition.unlock()
        return true
    }

    func resumeAfterRestore() {
        condition.lock()
        isRestoring = false
        condition.unlock()
    }
}

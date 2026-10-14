import Foundation

/// WebKit 给出 JSON 值树，提交后只读。转换为 JSONValue 的遍历留在后台任务中完成。
struct RoleplayBridgeSubmittedPayload: @unchecked Sendable {
    let values: [String: Any]
}

/// 提交顺序由短锁固定；磁盘读写和等待前序任务均不占用调用方的线程。
final class RoleplayBridgeOperationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        let task = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            // 取消的任务仍等待前序完成，保证等待队尾时不会漏掉尚未结束的写入。
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        return task
    }
}

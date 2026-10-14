import Foundation

/// 主执行器只登记不可变快照；数据库和 JSON 写入在后台按登记顺序完成。
@MainActor
final class DailyPulsePersistenceQueue {
    static let shared = DailyPulsePersistenceQueue()
    private(set) var revision = UUID()
    private var operationRevision = UUID()
    private(set) var pending: Task<Void, Never>?

    @discardableResult
    func enqueue<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) -> Task<Value, Never> {
        let previous = pending
        let task = Task.detached(priority: .utility) {
            await previous?.value
            // 已接受的写入不随页面或生成任务取消，否则内存状态会与数据库分离。
            return operation()
        }
        revision = UUID()
        operationRevision = UUID()
        pending = Task.detached(priority: .utility) { _ = await task.value }
        return task
    }

    func read<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) -> Task<Value, Never> {
        let previous = pending
        let task = Task.detached(priority: .utility) {
            await previous?.value
            return operation()
        }
        operationRevision = UUID()
        // 加载过程会清理过期记录，也必须排在写入之间；纯加载不使另一加载的结果失效。
        pending = Task.detached(priority: .utility) { _ = await task.value }
        return task
    }

    func flush() async {
        while let pending {
            let expected = operationRevision
            await pending.value
            if operationRevision == expected {
                self.pending = nil
                return
            }
        }
    }
}

public extension DailyPulseManager {
    /// 备份、恢复与桌面退出前等待已经登记的持久化；不主动创建管理器或触发生成。
    static func flushPendingPersistence() async {
        await DailyPulsePersistenceQueue.shared.flush()
    }
}

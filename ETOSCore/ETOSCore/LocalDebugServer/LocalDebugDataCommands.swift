import Foundation

extension LocalDebugServer {
    /// 跨执行器只传递不可变 JSON；已进入的数据库事务由外层命令队列等到实际结束。
    func runDebugDataOperation(_ operation: @escaping @Sendable () async -> [String: Any]) async -> [String: Any] {
        let worker = Task.detached(priority: .userInitiated) { LocalDebugJSONObject(value: await operation()) }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        return result.value
    }
}

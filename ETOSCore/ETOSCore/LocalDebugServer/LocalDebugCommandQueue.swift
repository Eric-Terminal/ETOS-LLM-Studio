import Foundation

/// 同一调试客户端的命令按接收顺序执行；取消只丢弃未开始的命令，已进入的操作仍须等到实际返回。
@MainActor
final class LocalDebugCommandQueue {
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    var isEmpty: Bool { operations.isEmpty }

    func enqueue(discardOnCancellation: Bool = true, _ operation: @escaping @MainActor () async -> Void) {
        let previous = tail, id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            if !discardOnCancellation || !Task.isCancelled { await operation() }
            self?.operations.removeValue(forKey: id)
        }
        operations[id] = task
        tail = task
    }

    func cancel() { for task in operations.values { task.cancel() } }

    func waitForCompletion() async {
        while !operations.isEmpty {
            let pending = Array(operations.values)
            for task in pending { await task.value }
        }
    }
}

enum LocalDebugCommandContext {
    @TaskLocal static var connectionToken: UUID?
}

/// 仅封装 JSONSerialization 的不可变 JSON 值；命令处理器使用值拷贝，不跨执行器共享可变容器。
struct LocalDebugJSONObject: @unchecked Sendable {
    let value: [String: Any]

    static func decode(_ data: Data) throws -> LocalDebugJSONObject? {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return LocalDebugJSONObject(value: value)
    }

    func encoded() throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}

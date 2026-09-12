import Foundation

/// 仅保留一次待处理变化；慢速页面不会积压输出分片，隐藏页面无需订阅。
final class LocalLinuxTerminalChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var isFinished = false

    func stream() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        lock.lock()
        let finished = isFinished
        if !finished { observers[id] = continuation }
        // 在注册的同一把锁内发布初始变化，避免遗漏订阅前的输出。
        continuation.yield(())
        lock.unlock()
        if finished { continuation.finish() }
        return stream
    }

    func send() {
        lock.lock()
        let pending = Array(observers.values)
        lock.unlock()
        for observer in pending { observer.yield(()) }
    }

    func finish() {
        lock.lock()
        isFinished = true
        let pending = Array(observers.values)
        observers.removeAll()
        lock.unlock()
        // finish 会同步触发移除回调，必须在锁外完成。
        for observer in pending {
            observer.yield(())
            observer.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }
}

import Foundation

/// 宿主先同步封闭入口，再取消进程并等待所有收尾；恢复数据库时不能遗留旧作业写入。
public final class LocalLinuxActivityBarrier: @unchecked Sendable {
    public static let shared = LocalLinuxActivityBarrier()
    private let lock = NSLock()
    private var paused = false
    private var generation = UUID()
    private var activities: Set<UUID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public var isSuspended: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    public var revision: UUID {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    public func suspend() {
        lock.lock(); defer { lock.unlock() }
        paused = true; generation = UUID()
    }

    public func resume() {
        lock.lock(); defer { lock.unlock() }
        // 等待者恢复前，不允许另一个窗口提前放行新任务。
        guard activities.isEmpty else { return }
        paused = false
    }

    public func waitForIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if activities.isEmpty {
                lock.unlock(); continuation.resume()
            } else {
                waiters.append(continuation); lock.unlock()
            }
        }
    }

    /// 宿主的工作区准备和文件操作也计入收尾，避免仅等待进程却漏掉启动前的数据库写入。
    public func withActivity<Result: Sendable>(
        expectedRevision: UUID? = nil,
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let activity = try begin(expectedRevision: expectedRevision)
        defer { activity.finish() }
        try activity.checkCancellation()
        let result = try await operation()
        try activity.checkCancellation()
        return result
    }

    func begin(expectedRevision: UUID? = nil) throws -> LocalLinuxActivityLease {
        lock.lock(); defer { lock.unlock() }
        guard !paused, expectedRevision == nil || expectedRevision == generation else { throw CancellationError() }
        let id = UUID()
        activities.insert(id)
        return LocalLinuxActivityLease(owner: self, id: id, generation: generation)
    }

    fileprivate func check(id: UUID, generation: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !paused, self.generation == generation, activities.contains(id) else { throw CancellationError() }
    }

    fileprivate func finish(id: UUID) {
        lock.lock()
        activities.remove(id)
        let ready = activities.isEmpty ? waiters : []
        if activities.isEmpty { waiters.removeAll() }
        lock.unlock()
        ready.forEach { $0.resume() }
    }
}

final class LocalLinuxActivityLease: @unchecked Sendable {
    private let owner: LocalLinuxActivityBarrier
    private let id: UUID
    private let generation: UUID
    private let lock = NSLock()
    private var finished = false

    fileprivate init(owner: LocalLinuxActivityBarrier, id: UUID, generation: UUID) {
        self.owner = owner; self.id = id; self.generation = generation
    }

    func checkCancellation() throws {
        try Task.checkCancellation()
        try owner.check(id: id, generation: generation)
    }

    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; lock.unlock()
        owner.finish(id: id)
    }

    deinit { finish() }
}

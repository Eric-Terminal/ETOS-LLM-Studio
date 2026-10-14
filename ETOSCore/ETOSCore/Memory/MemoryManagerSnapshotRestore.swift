import Foundation

extension MemoryManager {
    /// 已登记的操作可能等待到一轮被恢复取消的初始化，不能直接使用未加载完的索引。
    func waitForOperationInitialization() async -> Bool {
        while let task = initializationTask {
            await task.value
            guard operationBarrier.acceptsOperations, !Task.isCancelled else { return false }
            if task == initializationTask { return similarityIndex != nil }
        }
        return false
    }

    /// 此入口包住实际换库和文件还原；解压校验不需要占住记忆系统。
    static func withCurrentInstancePausedForSnapshotRestore<T>(_ operation: () throws -> T) throws -> T {
        try currentInstanceForSnapshotRestore().withPausedForSnapshotRestore(operation)
    }

    func withPausedForSnapshotRestore<T>(_ operation: () throws -> T) throws -> T {
        let manager = self
        guard manager.operationBarrier.pauseForRestore() else {
            throw NSError(domain: "ETOSMemoryRestore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("当前有数据或工具任务正在运行，请稍后重试。", comment: "")
            ])
        }
        // 所有可能继续排队写盘的操作均已退出，现在才能排空队列并关闭底层库。
        manager.flushPendingPersistenceWritesForSnapshot()
        var didRestore = false
        defer {
            manager.resetAllAutoRetryState()
            // 先发布新的初始化任务，再开放操作入口，防止请求继续读旧缓存。
            let (startSignal, signal) = AsyncStream<Void>.makeStream()
            let allowLegacyVectorMigration = !didRestore
            manager.initializationTask = manager.operationBarrier.start(allowDuringRestore: true) { [weak manager] in
                var events = startSignal.makeAsyncIterator()
                _ = await events.next()
                guard let manager, !Task.isCancelled else { return }
                await manager.setup(allowLegacyVectorMigration: allowLegacyVectorMigration)
            }
            manager.operationBarrier.resumeAfterRestore()
            signal.yield(())
            signal.finish()
        }
        let result = try operation()
        didRestore = true
        return result
    }
}

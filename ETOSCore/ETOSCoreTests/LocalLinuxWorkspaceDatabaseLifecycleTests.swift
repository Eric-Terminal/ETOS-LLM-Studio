import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("工作区统计与数据库替换", .serialized)
struct LocalLinuxWorkspaceDatabaseLifecycleTests {
    @Test("旧统计不能重开已关闭的连接或写入替换后的数据库", .timeLimit(.minutes(1)), arguments: [false, true])
    func delayedSizeWriteDoesNotCrossDatabaseReplacement(replaceDatabase: Bool) async throws {
        // 真实持久化门面固定读取 StorageUtility 路径；先核对现有 XCTest 隔离机制，
        // 避免脱离测试宿主运行时触及长期保存的 Documents。
        try #require(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        let expectedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ETOSCoreTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try #require(
            StorageUtility.documentsDirectory.standardizedFileURL
                == expectedDirectory.standardizedFileURL
        )

        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        let workspace = LocalAgentWorkspace(
            sessionID: nil,
            guestPath: "/mnt/workspaces/lifecycle-test",
            hostRelativePath: "Workspaces/\(UUID().uuidString)"
        )
        defer {
            // 只处理本测试插入的行；关闭的是上面已确认处于隔离目录的测试连接。
            // 行为断言完成后才重开测试库清理，关闭状态下也不能残留测试行。
            try? Persistence.activeGRDBStore()?.deleteLocalAgentWorkspace(id: workspace.id)
            try? Persistence.closeActiveStoresForSnapshotRestore()
            Persistence.grdbEnabledOverrideForTests = previousOverride
        }
        let originalStore = try #require(Persistence.activeGRDBStore())
        try #require(originalStore.databaseURL.deletingLastPathComponent() == Persistence.getChatsDirectory())
        try #require(Persistence.saveLocalAgentWorkspace(workspace))
        let persistSize = try #require(Persistence.makeLocalAgentWorkspaceSizeWriter())

        let replacementDirectory = expectedDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        if replaceDatabase {
            try FileManager.default.createDirectory(at: replacementDirectory, withIntermediateDirectories: true)
            let replacement = try PersistenceGRDBStore(chatsDirectory: replacementDirectory)
            var restoredWorkspace = workspace
            restoredWorkspace.sizeBytes = 987
            try replacement.saveLocalAgentWorkspace(restoredWorkspace)
            try replacement.dbPool.close()
        }

        let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let persisted = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            started.continuation.finish()
            release.continuation.finish()
            persisted.continuation.finish()
        }
        let refresher = LocalLinuxWorkspaceSizeRefresher(
            coalescingDelay: .zero,
            measure: { _ in
                started.continuation.yield(())
                var released = release.stream.makeAsyncIterator()
                guard await released.next() != nil else { throw CancellationError() }
                return 123
            }
        )
        var starts = started.stream.makeAsyncIterator()
        var completions = persisted.stream.makeAsyncIterator()
        await refresher.schedule(workspace, directory: expectedDirectory) { workspace, size in
            do {
                try persistSize(workspace, size)
                persisted.continuation.yield(true)
            } catch {
                persisted.continuation.yield(false)
                throw error
            }
        }
        try #require(await starts.next() != nil)

        // 真实关闭流程执行完，扫描才得到继续机会；没有墙钟竞态。
        let replacementResult = Result {
            try Persistence.closeActiveStoresForSnapshotRestore()
            #expect(Persistence.grdbStoreLock.withLock { Persistence.cachedGRDBStore == nil })
            #expect(Persistence.makeLocalAgentWorkspaceSizeWriter() == nil)
            if replaceDatabase {
                try Persistence.replaceDatabaseFile(.init(
                    sourceURL: replacementDirectory.appendingPathComponent("chat-store.sqlite"),
                    targetURL: originalStore.databaseURL
                ))
                _ = try #require(Persistence.activeGRDBStore())
            }
        }
        let cacheWasCleared = Persistence.grdbStoreLock.withLock { Persistence.cachedGRDBStore == nil }
        release.continuation.yield(())
        let completion: Bool? = await completions.next()
        let didSave = try #require(completion as Bool?)
        try replacementResult.get()
        #expect(!didSave)
        if replaceDatabase {
            let restored = try #require(Persistence.activeGRDBStore())
            #expect(restored !== originalStore)
            #expect(try restored.loadLocalAgentWorkspaces().first { $0.id == workspace.id }?.sizeBytes == 987)
        } else {
            #expect(cacheWasCleared)
            #expect(Persistence.grdbStoreLock.withLock { Persistence.cachedGRDBStore == nil })
        }
    }
}

import Foundation
import Testing
@testable import ETOSCore

@Suite("本地 Linux 后台工作区统计")
struct LocalLinuxWorkspaceSizeTests {
    @Test("短时间内的完成请求合并扫描，排队不等待目录遍历", .timeLimit(.minutes(1)))
    func completionBurstIsCoalesced() async throws {
        let probe = MeasurementProbe()
        let refresher = makeRefresher(probe)
        let workspace = makeWorkspace()
        var starts = probe.starts.makeAsyncIterator()
        var saved = probe.saved.makeAsyncIterator()

        await scheduleBurst(on: refresher, workspace: workspace)
        #expect(await starts.next() == 1)
        // 扫描仍被测试门闩挂起；排队已经返回，也尚未写入统计。
        #expect(await probe.savedCount == 0)
        await probe.complete(1, size: 42)
        #expect(await saved.next() == 42)
        #expect(await probe.count == 1)
    }

    @Test("扫描期间的新完成请求会合并成下一次统计", .timeLimit(.minutes(1)))
    func changesDuringScanTriggerAnotherPass() async throws {
        let probe = MeasurementProbe()
        let refresher = makeRefresher(probe)
        let workspace = makeWorkspace()
        var starts = probe.starts.makeAsyncIterator()
        var saved = probe.saved.makeAsyncIterator()

        await scheduleBurst(on: refresher, workspace: workspace)
        #expect(await starts.next() == 1)
        await scheduleBurst(on: refresher, workspace: workspace)
        await probe.complete(1, size: 10)
        #expect(await saved.next() == 10)
        #expect(await starts.next() == 2)
        await probe.complete(2, size: 20)
        #expect(await saved.next() == 20)
        #expect(await probe.count == 2)
    }

    @Test("主动刷新返回已保存的测量值，失败后允许重新刷新")
    func explicitRefreshRetriesAfterFailure() async throws {
        let attempts = AttemptCounter()
        let refresher = LocalLinuxWorkspaceSizeRefresher(
            measure: { _ in
                if await attempts.next() == 1 { throw CocoaError(.fileReadUnknown) }
                return 123
            },
            persist: { _, size in #expect(size == 123) }
        )
        let workspace = makeWorkspace()
        do {
            _ = try await refresher.refresh(workspace, directory: URL(fileURLWithPath: "/unused"))
            Issue.record("首次扫描应传递测量错误")
        } catch {
            #expect((error as? CocoaError)?.code == .fileReadUnknown)
        }
        let size = try await refresher.refresh(workspace, directory: URL(fileURLWithPath: "/unused"))
        #expect(size == 123)
        #expect(await attempts.count == 2)
    }

    @Test("统计写回保留较新的元数据，且不会恢复已删除或重建的工作区")
    func sizeUpdateDoesNotOverwriteWorkspaceLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceGRDBStore(chatsDirectory: directory)
        let original = makeWorkspace()
        try store.saveLocalAgentWorkspace(original)
        var newer = try #require(store.loadLocalAgentWorkspaces().first)
        newer.lastUsedAt = original.lastUsedAt.addingTimeInterval(60)
        newer.guestPath = "/mnt/workspaces/renamed"
        try store.saveLocalAgentWorkspace(newer)
        try store.updateLocalAgentWorkspaceSize(original, sizeBytes: 456)
        newer.sizeBytes = 456
        #expect(try store.loadLocalAgentWorkspaces().first == newer)

        try store.deleteLocalAgentWorkspace(id: original.id)
        try store.updateLocalAgentWorkspaceSize(original, sizeBytes: 999)
        #expect(try store.loadLocalAgentWorkspaces().isEmpty)

        let recreated = LocalAgentWorkspace(
            id: original.id, sessionID: nil, guestPath: original.guestPath,
            hostRelativePath: original.hostRelativePath,
            createdAt: original.createdAt.addingTimeInterval(60)
        )
        try store.saveLocalAgentWorkspace(recreated)
        try store.updateLocalAgentWorkspaceSize(original, sizeBytes: 999)
        #expect(try store.loadLocalAgentWorkspaces().first?.sizeBytes == 0)
        let reloaded = try #require(store.loadLocalAgentWorkspaces().first)
        try store.updateLocalAgentWorkspaceSize(reloaded, sizeBytes: 789)
        #expect(try store.loadLocalAgentWorkspaces().first?.sizeBytes == 789)
    }

    private func makeWorkspace() -> LocalAgentWorkspace {
        LocalAgentWorkspace(sessionID: nil, guestPath: "/mnt/workspaces/test", hostRelativePath: "Workspaces/test")
    }

    private func makeRefresher(_ probe: MeasurementProbe) -> LocalLinuxWorkspaceSizeRefresher {
        LocalLinuxWorkspaceSizeRefresher(
            coalescingDelay: .zero,
            measure: { _ in try await probe.measure() },
            persist: { _, size in await probe.persist(size) }
        )
    }

    // 同一 actor 内一次性提交请求，避免用墙钟延时猜测合并窗口是否已经结束。
    private func scheduleBurst(on refresher: isolated LocalLinuxWorkspaceSizeRefresher, workspace: LocalAgentWorkspace) {
        for _ in 0..<50 {
            refresher.schedule(workspace, directory: URL(fileURLWithPath: "/unused"))
        }
    }

    private actor AttemptCounter {
        private(set) var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    private actor MeasurementProbe {
        nonisolated let starts: AsyncStream<Int>
        nonisolated let saved: AsyncStream<UInt64>
        private let started: AsyncStream<Int>.Continuation
        private let persisted: AsyncStream<UInt64>.Continuation
        private var gates: [Int: CheckedContinuation<UInt64, Error>] = [:]
        private(set) var count = 0
        private(set) var savedCount = 0

        init() {
            let startEvents = AsyncStream<Int>.makeStream()
            starts = startEvents.stream
            started = startEvents.continuation
            let savedEvents = AsyncStream<UInt64>.makeStream()
            saved = savedEvents.stream
            persisted = savedEvents.continuation
        }

        func measure() async throws -> UInt64 {
            count += 1
            let index = count
            return try await withCheckedThrowingContinuation { continuation in
                gates[index] = continuation
                started.yield(index)
            }
        }

        func complete(_ index: Int, size: UInt64) { gates.removeValue(forKey: index)?.resume(returning: size) }

        func persist(_ size: UInt64) {
            savedCount += 1
            persisted.yield(size)
        }
    }
}

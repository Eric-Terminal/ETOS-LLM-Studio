// ============================================================================
// LocalLinuxJobPaginationTests.swift
// ============================================================================
// 活跃任务与终态历史的查询边界回归测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Linux 任务分页测试")
struct LocalLinuxJobPaginationTests {
    @Test("较早活跃任务不被超过一百条终态历史隐藏")
    func activeJobRemainsOutsideHistoryCursor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-linux-job-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceGRDBStore(chatsDirectory: directory)
        let sessionID = UUID()
        store.saveChatSessions([
            ChatSession(id: sessionID, name: "分页测试", isTemporary: false)
        ])
        var active = makeJob(
            sessionID: sessionID,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        active.state = .running
        try store.saveLocalLinuxJob(active)

        for index in 0 ..< 105 {
            var job = makeJob(
                sessionID: sessionID,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 2))
            )
            job.state = .completed
            job.finishedAt = job.createdAt
            try store.saveLocalLinuxJob(job)
        }

        let activeJobs = try store.loadLocalLinuxJobs(activeOnly: true, sessionID: sessionID)
        var cursor: LocalLinuxJobCursor?
        var history: [LocalLinuxJob] = []
        repeat {
            let page = try store.loadLocalLinuxJobHistoryPage(
                sessionID: sessionID,
                cursor: cursor,
                limit: 30
            )
            history.append(contentsOf: page.jobs)
            cursor = page.nextCursor
        } while cursor != nil

        #expect(activeJobs.map(\.id) == [active.id])
        #expect(history.count == 105)
        #expect(!history.contains(where: { $0.id == active.id }))
        #expect(Set(history.map(\.id)).count == 105)
    }

    @Test("相同创建时间的活跃任务按 ID 稳定翻页")
    func activeJobsWithSameTimestampUseStableIDOrder() {
        let sessionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 42)
        let smallerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let largerID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let ordered = LocalLinuxJobScheduler.orderedJobs([
            makeJob(id: smallerID, sessionID: sessionID, createdAt: createdAt),
            makeJob(id: largerID, sessionID: sessionID, createdAt: createdAt)
        ])

        #expect(ordered.map(\.id) == [largerID, smallerID])
        let cursor = LocalLinuxJobCursor(createdAt: ordered[0].createdAt, id: ordered[0].id)
        let nextPage = ordered.filter { job in
            if job.createdAt != cursor.createdAt {
                return job.createdAt < cursor.createdAt
            }
            return job.id.uuidString < cursor.id.uuidString
        }
        #expect(nextPage.map(\.id) == [smallerID])
    }

    @Test("任务分组后仍保留相同时间的稳定 ID 次序")
    func groupedJobsReuseStableOrdering() {
        let sessionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 42)
        let runA = UUID()
        let runB = UUID()
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        ]
        let groups = LocalLinuxJobScheduler.orderedJobGroups([
            makeJob(id: ids[0], sessionID: sessionID, runID: runA, createdAt: createdAt),
            makeJob(id: ids[2], sessionID: sessionID, runID: runA, createdAt: createdAt),
            makeJob(id: ids[1], sessionID: sessionID, runID: runB, createdAt: createdAt)
        ])

        #expect(groups.map { $0.map(\.id) } == [[ids[2], ids[0]], [ids[1]]])
    }

    private func makeJob(
        id: UUID = UUID(),
        sessionID: UUID,
        runID: UUID = UUID(),
        createdAt: Date
    ) -> LocalLinuxJob {
        LocalLinuxJob(
            id: id,
            requestID: UInt64(createdAt.timeIntervalSince1970),
            kind: .run,
            sessionID: sessionID,
            runID: runID,
            rootRunID: nil,
            parentRunID: nil,
            toolCallID: nil,
            workspaceID: nil,
            executorDeviceID: "test-device",
            request: LocalLinuxJobRequest(
                executable: "/bin/true",
                arguments: ["/bin/true"]
            ),
            createdAt: createdAt
        )
    }
}

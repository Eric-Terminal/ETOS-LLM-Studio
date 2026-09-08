import Foundation
import GRDB
import Testing
@testable import ETOSCore

@Suite("反馈关联提交通知")
struct FeedbackCommitNotificationTests {
    private let baseline = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("没有评论或状态变化时，引用提交仍触发提醒且刷新后不重复")
    func commitOnlyUpdateIsNotifiedOnce() throws {
        let ticket = makeTicket(knownIDs: [])
        let snapshot = makeSnapshot(events: [reference(id: "1", offset: 60)])
        let event = FeedbackService.makeTicketUpdateEventIfNeeded(previousTicket: ticket, snapshot: snapshot)
        #expect(event?.latestReferencedCommit?.displayHeadline == "fix(工具): 修复参数 #133")
        #expect(event?.hasStatusChange == false)
        #expect(event?.latestDeveloperComment == nil)

        let merged = ticket.merged(with: snapshot)
        let encoded = try JSONEncoder().encode(merged)
        let restored = try JSONDecoder().decode(FeedbackTicket.self, from: encoded)
        #expect(restored.lastKnownReferencedCommitIDs == ["referenced-1"])
        #expect(FeedbackService.makeTicketUpdateEventIfNeeded(previousTicket: restored, snapshot: snapshot) == nil)
    }

    @Test("升级建立基线时只提醒上次检查后新增的引用，不依赖工单更新时间")
    func legacyTicketUsesLastCheckForBaseline() {
        let ticket = makeTicket(knownIDs: nil)
        let oldSnapshot = makeSnapshot(events: [reference(id: "old", offset: -60)])
        #expect(FeedbackService.makeTicketUpdateEventIfNeeded(previousTicket: ticket, snapshot: oldSnapshot) == nil)
        let newSnapshot = makeSnapshot(events: [reference(id: "new", offset: 60)])
        #expect(FeedbackService.makeTicketUpdateEventIfNeeded(previousTicket: ticket, snapshot: newSnapshot)?.latestReferencedCommit != nil)
    }

    @Test("事件重排、暂时缺失及同一时间新增引用不会造成漏报或重复提醒")
    func referencesAreComparedByIdentity() {
        let first = reference(id: "1", offset: 60)
        let second = reference(id: "2", offset: 60)
        let ticket = makeTicket(knownIDs: []).merged(with: makeSnapshot(events: [first]))
        let missing = ticket.merged(with: makeSnapshot(events: []))
        #expect(FeedbackService.makeTicketUpdateEventIfNeeded(previousTicket: missing, snapshot: makeSnapshot(events: [first])) == nil)
        #expect(FeedbackService.makeTicketUpdateEventIfNeeded(previousTicket: missing, snapshot: makeSnapshot(events: [second, first]))?.latestReferencedCommit?.sha == "sha-2")
        let merged = missing.merged(with: makeSnapshot(events: [second, first]))
        #expect(FeedbackService.makeTicketUpdateEventIfNeeded(previousTicket: merged, snapshot: makeSnapshot(events: [first, second])) == nil)
    }

    @Test("回复、状态及引用同时到达时均保留在同一更新事件中")
    func combinedUpdateKeepsAllReasons() {
        let comment = FeedbackComment(id: "reply", author: "Eric-Terminal", body: "**请更新**", createdAt: baseline.addingTimeInterval(90), isDeveloper: true)
        let snapshot = makeSnapshot(events: [reference(id: "1", offset: 60)], status: .resolved, comments: [comment])
        let event = FeedbackService.makeTicketUpdateEventIfNeeded(previousTicket: makeTicket(knownIDs: []), snapshot: snapshot)
        #expect(event?.hasStatusChange == true)
        #expect(event?.latestDeveloperComment?.id == "reply")
        #expect(event?.latestReferencedCommit != nil)
    }

    @Test("配置数据库迁移增加引用基线并完整读取长 Markdown 正文")
    func relationalTrackingAndLongTextArePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PersistenceAuxiliaryGRDBStore(
            databaseURL: directory.appendingPathComponent("config-store.sqlite"),
            loggerCategory: "FeedbackCommitNotificationTests"
        )
        let body = "# 反馈\n\n" + String(repeating: "**完整内容**\n", count: 2_000) + "正文结束"
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO feedback_tickets
                (issue_number, ticket_token, category, title, created_at, last_known_status,
                 submitted_detail, last_known_referenced_commit_ids)
                VALUES (133, 'test-token', 'bug', '测试反馈', 1700000000, 'triage', ?, ?)
                """, arguments: [body, "[\"commit-1\",\"commit-2\"]"])
        }
        let tickets = try store.read { db in try FeedbackStore.loadTickets(from: db) }
        #expect(tickets.first?.submittedDetail == body)
        #expect(tickets.first?.lastKnownReferencedCommitIDs == ["commit-1", "commit-2"])
    }

    @Test("向导可检索反馈渲染、关联提交与通知时机说明")
    func guideExplainsFeedbackBehavior() async {
        let knowledge = GuideKnowledgeService()
        let result = await knowledge.search("关联提交", limit: 1)
        #expect(result.first?.id == "feedback-assistant")
    }

    private func makeTicket(knownIDs: [String]?) -> FeedbackTicket {
        FeedbackTicket(
            issueNumber: 133, ticketToken: "test-token", category: .bug, title: "测试反馈",
            createdAt: baseline.addingTimeInterval(-120), lastKnownStatus: .triage,
            lastCheckedAt: baseline, lastKnownUpdatedAt: baseline, lastKnownCommentCount: 0,
            lastKnownReferencedCommitIDs: knownIDs
        )
    }

    private func reference(id: String, offset: TimeInterval) -> FeedbackTimelineEvent {
        .referencedCommit(
            id: id, actor: "Eric-Terminal", createdAt: baseline.addingTimeInterval(offset),
            commit: FeedbackReferencedCommit(
                sha: "sha-\(id)", shortSHA: "sha-\(id)",
                messageHeadline: "fix(工具): 修复参数 #133", message: "fix(工具): 修复参数 #133\n\n详细说明",
                htmlURL: URL(string: "https://github.com/example/repo/commit/sha-\(id)")!,
                committedAt: baseline, verified: true
            )
        )
    }

    private func makeSnapshot(
        events: [FeedbackTimelineEvent], status: FeedbackTicketStatus = .triage, comments: [FeedbackComment] = []
    ) -> FeedbackStatusSnapshot {
        FeedbackStatusSnapshot(
            issueNumber: 133, title: "测试反馈", status: status, labels: [], updatedAt: baseline,
            publicURL: nil, isClosed: false, comments: comments, timelineEvents: events
        )
    }
}

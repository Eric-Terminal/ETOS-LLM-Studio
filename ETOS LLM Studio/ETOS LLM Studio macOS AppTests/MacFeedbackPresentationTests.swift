import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacFeedbackPresentationTests {
    @Test("旧工单仍展示标题，凭据与空白字段不进入正文")
    func legacyTicketFields() {
        let ticket = FeedbackTicket(issueNumber: 12, ticketToken: "secret-token", category: .bug,
            title: "旧标题", createdAt: .distantPast, lastKnownStatus: .triage,
            submittedDetail: "完整正文\n\n第二段", submittedReproductionSteps: "  ")
        let result = MacFeedbackPresentation(ticket: ticket, snapshot: nil)
        #expect(result.fields.map(\.id) == ["标题", "详细描述"])
        #expect(result.fields.map(\.text.source) == ["旧标题", "完整正文\n\n第二段"])
        #expect(result.events.isEmpty)
    }

    @Test("旧接口评论按时间展示，完整正文不会被卡片摘要截断")
    func legacyComments() {
        let ticket = FeedbackTicket(issueNumber: 12, ticketToken: "token", category: .bug,
            title: "标题", createdAt: .distantPast, lastKnownStatus: .triage)
        let body = String(repeating: "完整评论\n", count: 100)
        let snapshot = FeedbackStatusSnapshot(issueNumber: 12, title: "标题", status: .triage,
            labels: [], updatedAt: .now, publicURL: nil, isClosed: false,
            comments: [FeedbackComment(id: "later", author: "开发者", body: body, createdAt: .now),
                FeedbackComment(id: "first", author: "用户", body: "首条", createdAt: .distantPast)])
        let result = MacFeedbackPresentation(ticket: ticket, snapshot: snapshot)
        #expect(result.events.map(\.text.source) == ["首条", body])
    }

    @Test("关联提交保留完整说明和来源链接，不把评论再追加一次")
    func referencedCommit() {
        let ticket = FeedbackTicket(issueNumber: 12, ticketToken: "token", category: .bug,
            title: "标题", createdAt: .distantPast, lastKnownStatus: .triage)
        let commit = FeedbackReferencedCommit(sha: "abcdef1234", shortSHA: "abcdef1", messageHeadline: "修复 #12",
            message: "修复 #12\n\n完整提交说明", htmlURL: URL(string: "https://github.com/example/repo/commit/abcdef1234"),
            committedAt: .distantPast, verified: true)
        let snapshot = FeedbackStatusSnapshot(issueNumber: 12, title: "标题", status: .triage,
            labels: [], updatedAt: .now, publicURL: nil, isClosed: false,
            comments: [FeedbackComment(id: "unused", author: "用户", body: "旧接口镜像", createdAt: .now)],
            timelineEvents: [.referencedCommit(id: "commit-event", actor: "开发者", createdAt: .now, commit: commit)])
        let result = MacFeedbackPresentation(ticket: ticket, snapshot: snapshot)
        #expect(result.events.count == 1)
        #expect(result.events.first?.commit == commit)
        #expect(result.events.first?.text.source == commit.message)
    }
}

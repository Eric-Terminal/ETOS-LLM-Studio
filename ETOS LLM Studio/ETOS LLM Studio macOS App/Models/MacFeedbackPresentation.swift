import ETOSCore
import Foundation

/// 工单正文只进入本机展示数据，不进入页面向导快照。
struct MacFeedbackPresentation: Sendable {
    struct Field: Identifiable, Sendable {
        let id: String
        let text: MacPreparedMessageText
    }
    struct Event: Identifiable, Sendable {
        let id: String
        let author: String
        let date: Date
        let text: MacPreparedMessageText
        let commit: FeedbackReferencedCommit?
    }
    let fields: [Field]
    let events: [Event]

    init(ticket: FeedbackTicket, snapshot: FeedbackStatusSnapshot?) {
        let values: [(String, String?)] = [
            ("标题", ticket.submittedTitle ?? ticket.title),
            ("详细描述", ticket.submittedDetail),
            ("可复现步骤（可选）", ticket.submittedReproductionSteps),
            ("预期行为（可选）", ticket.submittedExpectedBehavior),
            ("实际行为（可选）", ticket.submittedActualBehavior),
            ("补充信息（可选）", ticket.submittedExtraContext)
        ]
        fields = values.compactMap { key, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Field(id: key, text: MacPreparedMessageText(value, markdown: true))
        }
        let timeline = snapshot.map { $0.timelineEvents.isEmpty ? $0.comments.map(FeedbackTimelineEvent.comment) : $0.timelineEvents } ?? []
        events = timeline.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }.map { event in
            switch event {
            case .comment(let comment):
                return Event(id: event.id, author: comment.author, date: comment.createdAt,
                    text: MacPreparedMessageText(comment.body, markdown: true), commit: nil)
            case .referencedCommit(_, let actor, let date, let commit):
                return Event(id: event.id, author: actor, date: date,
                    text: MacPreparedMessageText(commit.message, markdown: true), commit: commit)
            }
        }
    }
}

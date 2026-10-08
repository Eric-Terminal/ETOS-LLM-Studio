import ETOSCore
import Foundation

struct MacDailyPulsePresentation: Sendable {
    struct Card: Identifiable, Sendable {
        let id: UUID
        let runID: UUID
        let source: DailyPulseCard
        let detail: MacPreparedMessageText
        let continuation: String
        let taskID: UUID?
        let feedbackTitle: String
    }
    struct Run: Identifiable, Sendable {
        let id: UUID
        let day: String
        let headline: String
        let date: String
        let cards: [Card]
        let visibleCards: [Card]
        let hiddenCards: [Card]

        init(id: UUID, day: String, headline: String, date: String, cards: [Card]) {
            self.id = id; self.day = day; self.headline = headline; self.date = date; self.cards = cards
            visibleCards = cards.filter { $0.source.isVisible }
            hiddenCards = cards.filter { !$0.source.isVisible }
        }
    }
    struct TaskRow: Identifiable, Sendable {
        let source: DailyPulseTask
        let date: String
        var id: UUID { source.id }
    }
    struct HistoryRow: Identifiable, Sendable {
        let source: DailyPulseFeedbackEvent
        let title: String
        let date: String
        var id: UUID { source.id }
    }
    struct SignalRow: Identifiable, Sendable {
        let source: DailyPulseExternalSignal
        let date: String
        var id: UUID { source.id }
    }
    struct TimeRow: Identifiable, Sendable {
        let id: UUID
        let title: String
        let time: String
    }

    let today: Run?
    let cards: [UUID: Card]
    let tasks: [TaskRow]
    let feedback: [HistoryRow]
    let signals: [SignalRow]
    let times: [TimeRow]
    let hasCompletedTasks: Bool
    let guideSummary: JSONValue
    let guideTimes: JSONValue

    init(runs: [DailyPulseRun], tasks: [DailyPulseTask], feedback: [DailyPulseFeedbackEvent],
         signals: [DailyPulseExternalSignal], times: [DailyPulseDeliveryTime],
         referenceDate: Date, markdown: Bool, advanced: Bool) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        let todayKey = DailyPulseManager.dayKey(for: referenceDate)
        // 未到日期的预准备内容不提前展示，通知点击也不能绕过日期边界。
        let visibleRuns = runs.filter { $0.dayKey == todayKey }.sorted { $0.generatedAt > $1.generatedAt }.prefix(1)
        let prepared = visibleRuns.map { run in
            Run(id: run.id, day: run.dayKey, headline: run.headline, date: formatter.string(from: run.generatedAt),
                cards: run.cards.map { card in
                    Card(id: card.id, runID: run.id, source: card,
                         detail: MacPreparedMessageText(card.detailsMarkdown, markdown: markdown, advanced: advanced),
                         continuation: DailyPulseManager.defaultContinuationPrompt(for: card),
                         taskID: tasks.first { $0.sourceDayKey == run.dayKey && $0.sourceCardID == card.id }?.id,
                         feedbackTitle: Self.feedbackTitle(card.feedback))
                })
        }
        today = prepared.first { $0.day == todayKey }
        cards = prepared.reduce(into: [:]) { result, run in
            for card in run.cards { result[card.id] = card }
        }
        self.tasks = tasks.map { TaskRow(source: $0, date: formatter.string(from: $0.updatedAt)) }
        self.feedback = feedback.map {
            let key: String
            switch $0.action {
            case .liked: key = "已喜欢 · %@"
            case .disliked: key = "已降权 · %@"
            case .hidden: key = "已隐藏 · %@"
            case .saved: key = "已保存为会话 · %@"
            }
            return HistoryRow(source: $0, title: String(format: NSLocalizedString(key, comment: ""), $0.dayKey),
                              date: formatter.string(from: $0.createdAt))
        }
        self.signals = signals.map { SignalRow(source: $0, date: formatter.string(from: $0.capturedAt)) }
        self.times = times.enumerated().map {
            TimeRow(id: $0.element.id, title: String(format: NSLocalizedString("卡片 %d", comment: ""), $0.offset + 1),
                    time: $0.element.timeText)
        }
        hasCompletedTasks = tasks.contains { $0.isCompleted }
        guideTimes = .array(self.times.map { .dictionary(["id": .string($0.id.uuidString), "time": .string($0.time)]) })
        guideSummary = .dictionary([
            "today": .string(todayKey), "card_count": .int(today?.cards.count ?? 0),
            "task_count": .int(tasks.count), "feedback_count": .int(feedback.count), "signal_count": .int(signals.count)
        ])
    }

    static func feedbackTitle(_ feedback: DailyPulseCardFeedback) -> String {
        switch feedback {
        case .none: return NSLocalizedString("未反馈", comment: "")
        case .liked: return NSLocalizedString("已喜欢", comment: "")
        case .disliked: return NSLocalizedString("已降权", comment: "")
        case .hidden: return NSLocalizedString("已隐藏", comment: "")
        }
    }
}

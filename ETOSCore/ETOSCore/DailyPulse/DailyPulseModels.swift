// ============================================================================
// DailyPulseModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责每日脉冲的公开模型、内部生成输入与外部上下文结构定义。
// ============================================================================

import Foundation

public enum DailyPulseCardFeedback: String, Codable, Hashable, Sendable {
    case none
    case liked
    case disliked
    case hidden
}

public enum DailyPulseTrigger: String, Codable, Hashable, Sendable {
    case automatic
    case manual
    case delivery
}

public enum DailyPulseHistoryAction: String, Codable, Hashable, Sendable {
    case liked
    case disliked
    case hidden
    case saved
}

public struct DailyPulseFeedbackEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var dayKey: String
    public var topicHint: String
    public var cardTitle: String
    public var action: DailyPulseHistoryAction

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        dayKey: String,
        topicHint: String,
        cardTitle: String,
        action: DailyPulseHistoryAction
    ) {
        self.id = id
        self.createdAt = createdAt
        self.dayKey = dayKey
        self.topicHint = topicHint
        self.cardTitle = cardTitle
        self.action = action
    }
}

public struct DailyPulseCurationNote: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var targetDayKey: String
    public var text: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        targetDayKey: String,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.targetDayKey = targetDayKey
        self.text = text
        self.createdAt = createdAt
    }
}

public enum DailyPulseExternalSignalSource: String, Codable, Hashable, Sendable {
    case shortcutResult
    case mcpOutput
    case mcpError
    case announcement
}

public struct DailyPulseExternalSignal: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: DailyPulseExternalSignalSource
    public var title: String
    public var preview: String
    public var capturedAt: Date
    public var isFailure: Bool

    public init(
        id: UUID = UUID(),
        source: DailyPulseExternalSignalSource,
        title: String,
        preview: String,
        capturedAt: Date = Date(),
        isFailure: Bool = false
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.preview = preview
        self.capturedAt = capturedAt
        self.isFailure = isFailure
    }
}

public struct DailyPulseTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceDayKey: String
    public var sourceCardID: UUID?
    public var title: String
    public var details: String
    public var suggestedPrompt: String
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        sourceDayKey: String,
        sourceCardID: UUID?,
        title: String,
        details: String,
        suggestedPrompt: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceDayKey = sourceDayKey
        self.sourceCardID = sourceCardID
        self.title = title
        self.details = details
        self.suggestedPrompt = suggestedPrompt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    public var isCompleted: Bool {
        completedAt != nil
    }
}

public struct DailyPulseCard: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var whyRecommended: String
    public var summary: String
    public var detailsMarkdown: String
    public var suggestedPrompt: String
    public var feedback: DailyPulseCardFeedback
    public var savedSessionID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        whyRecommended: String,
        summary: String,
        detailsMarkdown: String,
        suggestedPrompt: String,
        feedback: DailyPulseCardFeedback = .none,
        savedSessionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.whyRecommended = whyRecommended
        self.summary = summary
        self.detailsMarkdown = detailsMarkdown
        self.suggestedPrompt = suggestedPrompt
        self.feedback = feedback
        self.savedSessionID = savedSessionID
    }

    public var isVisible: Bool {
        feedback != .hidden
    }
}

public struct DailyPulseRun: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var dayKey: String
    public var generatedAt: Date
    public var headline: String
    public var cards: [DailyPulseCard]
    public var sourceDigest: String

    public init(
        id: UUID = UUID(),
        dayKey: String,
        generatedAt: Date,
        headline: String,
        cards: [DailyPulseCard],
        sourceDigest: String
    ) {
        self.id = id
        self.dayKey = dayKey
        self.generatedAt = generatedAt
        self.headline = headline
        self.cards = cards
        self.sourceDigest = sourceDigest
    }

    public var visibleCards: [DailyPulseCard] {
        cards.filter(\.isVisible)
    }
}

public enum DailyPulseGenerationError: LocalizedError {
    case noModelSelected
    case insufficientContext
    case invalidModelOutput

    public var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return NSLocalizedString("每日脉冲生成失败：当前没有可用的聊天模型。", comment: "Daily pulse error when no model is available")
        case .insufficientContext:
            return NSLocalizedString("每日脉冲暂时无法生成：当前可用的聊天、记忆、明日策展或外部上下文还不够。", comment: "Daily pulse error when not enough context is available")
        case .invalidModelOutput:
            return NSLocalizedString("每日脉冲生成失败：模型返回内容无法解析。", comment: "Daily pulse error when model output is invalid")
        }
    }
}

internal struct DailyPulseGenerationInput: Sendable {
    let focusText: String
    let curationText: String
    let globalSystemPrompt: String
    let sessionExcerpts: [DailyPulseSessionExcerpt]
    let memories: [String]
    let requestLogSummary: String
    let activeTasks: [DailyPulseTask]
    let preferenceProfile: DailyPulsePreferenceProfile
    let externalContext: DailyPulseExternalContext

    init(
        focusText: String,
        curationText: String,
        globalSystemPrompt: String = "",
        sessionExcerpts: [DailyPulseSessionExcerpt],
        memories: [String],
        requestLogSummary: String,
        activeTasks: [DailyPulseTask],
        preferenceProfile: DailyPulsePreferenceProfile,
        externalContext: DailyPulseExternalContext
    ) {
        self.focusText = focusText
        self.curationText = curationText
        self.globalSystemPrompt = globalSystemPrompt
        self.sessionExcerpts = sessionExcerpts
        self.memories = memories
        self.requestLogSummary = requestLogSummary
        self.activeTasks = activeTasks
        self.preferenceProfile = preferenceProfile
        self.externalContext = externalContext
    }

    var hasUsableContext: Bool {
        !focusText.isEmpty
            || !curationText.isEmpty
            || !globalSystemPrompt.isEmpty
            || !sessionExcerpts.isEmpty
            || !memories.isEmpty
            || !requestLogSummary.isEmpty
            || !activeTasks.isEmpty
            || preferenceProfile.hasSignals
            || externalContext.hasSignals
    }

    var sourceDigest: String {
        let sessionDigest = sessionExcerpts
            .flatMap { [[$0.name], $0.lines].flatMap { $0 } }
            .joined(separator: "|")
        let memoryDigest = memories.joined(separator: "|")
        return [
            focusText,
            curationText,
            globalSystemPrompt,
            sessionDigest,
            memoryDigest,
            requestLogSummary,
            activeTasks
                .map { "\($0.title)|\($0.details)|\($0.isCompleted ? "done" : "pending")" }
                .joined(separator: "|"),
            preferenceProfile.summaryText,
            externalContext.summaryText
        ]
        .joined(separator: "\n---\n")
    }
}

internal struct DailyPulsePreferenceProfile: Hashable, Sendable {
    let positiveHints: [String]
    let negativeHints: [String]
    let recentVisibleHints: [String]

    static let empty = DailyPulsePreferenceProfile(
        positiveHints: [],
        negativeHints: [],
        recentVisibleHints: []
    )

    var hasSignals: Bool {
        !positiveHints.isEmpty || !negativeHints.isEmpty || !recentVisibleHints.isEmpty
    }

    var summaryText: String {
        let empty = NSLocalizedString("（无）", comment: "Daily Pulse prompt empty placeholder")
        let positiveTitle = NSLocalizedString("更可能喜欢的话题：", comment: "Daily Pulse preference profile positive title")
        let negativeTitle = NSLocalizedString("应尽量避开的主题：", comment: "Daily Pulse preference profile negative title")
        let recentTitle = NSLocalizedString("最近几天已经出现过的卡片主题：", comment: "Daily Pulse preference profile recent title")
        let positive = positiveHints.isEmpty ? empty : positiveHints.map { "- \($0)" }.joined(separator: "\n")
        let negative = negativeHints.isEmpty ? empty : negativeHints.map { "- \($0)" }.joined(separator: "\n")
        let recent = recentVisibleHints.isEmpty ? empty : recentVisibleHints.map { "- \($0)" }.joined(separator: "\n")
        return """
        \(positiveTitle)
        \(positive)

        \(negativeTitle)
        \(negative)

        \(recentTitle)
        \(recent)
        """
    }
}

internal struct DailyPulseExternalContext: Hashable, Sendable {
    let mcpSourceLines: [String]
    let shortcutSourceLines: [String]
    let recentSnapshotLines: [String]
    let trendSourceLines: [String]
    let signalHistoryLines: [String]

    static let empty = DailyPulseExternalContext(
        mcpSourceLines: [],
        shortcutSourceLines: [],
        recentSnapshotLines: [],
        trendSourceLines: [],
        signalHistoryLines: []
    )

    var hasSignals: Bool {
        !mcpSourceLines.isEmpty
            || !shortcutSourceLines.isEmpty
            || !recentSnapshotLines.isEmpty
            || !trendSourceLines.isEmpty
            || !signalHistoryLines.isEmpty
    }

    var summaryText: String {
        let empty = NSLocalizedString("（无）", comment: "Daily Pulse prompt empty placeholder")
        let mcpTitle = NSLocalizedString("可用 MCP 外部能力：", comment: "Daily Pulse external context MCP title")
        let shortcutTitle = NSLocalizedString("可用快捷指令能力：", comment: "Daily Pulse external context shortcuts title")
        let snapshotTitle = NSLocalizedString("最近已获取到的外部结果快照：", comment: "Daily Pulse external context snapshots title")
        let trendTitle = NSLocalizedString("公告与趋势信号：", comment: "Daily Pulse external context trends title")
        let signalHistoryTitle = NSLocalizedString("最近积累的外部信号历史：", comment: "Daily Pulse external context signal history title")
        let mcpSummary = mcpSourceLines.isEmpty ? empty : mcpSourceLines.joined(separator: "\n")
        let shortcutSummary = shortcutSourceLines.isEmpty ? empty : shortcutSourceLines.joined(separator: "\n")
        let snapshotSummary = recentSnapshotLines.isEmpty ? empty : recentSnapshotLines.joined(separator: "\n")
        let trendSummary = trendSourceLines.isEmpty ? empty : trendSourceLines.joined(separator: "\n")
        let signalHistorySummary = signalHistoryLines.isEmpty ? empty : signalHistoryLines.joined(separator: "\n")
        return """
        \(mcpTitle)
        \(mcpSummary)

        \(shortcutTitle)
        \(shortcutSummary)

        \(snapshotTitle)
        \(snapshotSummary)

        \(trendTitle)
        \(trendSummary)

        \(signalHistoryTitle)
        \(signalHistorySummary)
        """
    }
}

internal struct DailyPulseSessionExcerpt: Codable, Hashable, Sendable {
    let name: String
    let lines: [String]
}

internal struct DailyPulseModelResponse: Codable, Sendable {
    let headline: String?
    let cards: [DailyPulseModelCard]
}

internal struct DailyPulseModelCard: Codable, Sendable {
    let title: String
    let why: String?
    let summary: String
    let detailsMarkdown: String?
    let suggestedPrompt: String?

    enum CodingKeys: String, CodingKey {
        case title
        case why
        case summary
        case detailsMarkdown = "details_markdown"
        case suggestedPrompt = "suggested_prompt"
    }
}

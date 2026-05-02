// ============================================================================
// DailyPulse.swift
// ============================================================================
// ETOS LLM Studio 每日脉冲核心能力
//
// 功能特性:
// - 定义每日脉冲运行记录、卡片与反馈模型
// - 提供最近聊天 / 记忆 / 请求日志的上下文拼装
// - 通过 Detached Completion 生成不污染聊天历史的每日卡片
// - 管理持久化、反馈写回、保存为会话等行为
// ============================================================================

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#endif

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
    let sessionExcerpts: [DailyPulseSessionExcerpt]
    let memories: [String]
    let requestLogSummary: String
    let activeTasks: [DailyPulseTask]
    let preferenceProfile: DailyPulsePreferenceProfile
    let externalContext: DailyPulseExternalContext

    var hasUsableContext: Bool {
        !focusText.isEmpty
            || !curationText.isEmpty
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
        let positive = positiveHints.isEmpty ? "（无）" : positiveHints.map { "- \($0)" }.joined(separator: "\n")
        let negative = negativeHints.isEmpty ? "（无）" : negativeHints.map { "- \($0)" }.joined(separator: "\n")
        let recent = recentVisibleHints.isEmpty ? "（无）" : recentVisibleHints.map { "- \($0)" }.joined(separator: "\n")
        return """
        更可能喜欢的话题：
        \(positive)

        应尽量避开的主题：
        \(negative)

        最近几天已经出现过的卡片主题：
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
        let mcpSummary = mcpSourceLines.isEmpty ? "（无）" : mcpSourceLines.joined(separator: "\n")
        let shortcutSummary = shortcutSourceLines.isEmpty ? "（无）" : shortcutSourceLines.joined(separator: "\n")
        let snapshotSummary = recentSnapshotLines.isEmpty ? "（无）" : recentSnapshotLines.joined(separator: "\n")
        let trendSummary = trendSourceLines.isEmpty ? "（无）" : trendSourceLines.joined(separator: "\n")
        let signalHistorySummary = signalHistoryLines.isEmpty ? "（无）" : signalHistoryLines.joined(separator: "\n")
        return """
        可用 MCP 外部能力：
        \(mcpSummary)

        可用快捷指令能力：
        \(shortcutSummary)

        最近已获取到的外部结果快照：
        \(snapshotSummary)

        公告与趋势信号：
        \(trendSummary)

        最近积累的外部信号历史：
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

@MainActor
public final class DailyPulseManager: ObservableObject {
    public static let shared = DailyPulseManager(chatService: .shared, memoryManager: .shared)
    internal nonisolated static let persistedRetentionLimit = 14
    internal nonisolated static let feedbackHistoryRetentionLimit = 120
    internal nonisolated static let externalSignalRetentionLimit = 40
    internal nonisolated static let taskRetentionLimit = 80

    @Published public var runs: [DailyPulseRun]
    @Published public var feedbackHistory: [DailyPulseFeedbackEvent]
    @Published public var pendingCuration: DailyPulseCurationNote?
    @Published public var externalSignals: [DailyPulseExternalSignal]
    @Published public var tasks: [DailyPulseTask]
    @Published public var isGenerating: Bool = false
    @Published public var lastErrorMessage: String?
    @Published public var lastViewedDayKey: String?
    @Published public var lastDeliveryAttemptDayKey: String?
    @Published public var preparingDayKey: String?
    @Published public var lastPreparationStartedAt: Date?
    @Published public var focusText: String {
        didSet {
            defaults.set(focusText, forKey: Self.focusDefaultsKey)
        }
    }
    @Published public var tomorrowCurationText: String {
        didSet {
            persistPendingCurationFromDraft()
        }
    }
    @Published public var autoGenerateEnabled: Bool {
        didSet {
            defaults.set(autoGenerateEnabled, forKey: Self.autoGenerateDefaultsKey)
        }
    }
    @Published public var includeMCPContext: Bool {
        didSet {
            defaults.set(includeMCPContext, forKey: Self.includeMCPContextDefaultsKey)
        }
    }
    @Published public var includeShortcutContext: Bool {
        didSet {
            defaults.set(includeShortcutContext, forKey: Self.includeShortcutContextDefaultsKey)
        }
    }
    @Published public var includeRecentExternalResults: Bool {
        didSet {
            defaults.set(includeRecentExternalResults, forKey: Self.includeRecentExternalResultsDefaultsKey)
        }
    }
    @Published public var includeTrendContext: Bool {
        didSet {
            defaults.set(includeTrendContext, forKey: Self.includeTrendContextDefaultsKey)
        }
    }

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "DailyPulse")
    let chatService: ChatService
    let memoryManager: MemoryManager
    let defaults: UserDefaults
    let retentionLimit: Int
    let cardsPerRun = 3
    let candidateCardsPerRun = 6
    let maxSessionsInPrompt = 4
    let maxMessagesPerSession = 6
    let maxMemoriesInPrompt = 8
    var syncNotificationObserver: NSObjectProtocol?

    internal nonisolated static let autoGenerateDefaultsKey = "dailyPulse.autoGenerate"
    internal nonisolated static let focusDefaultsKey = "dailyPulse.focusText"
    internal nonisolated static let includeMCPContextDefaultsKey = "dailyPulse.includeMCPContext"
    internal nonisolated static let includeShortcutContextDefaultsKey = "dailyPulse.includeShortcutContext"
    internal nonisolated static let includeRecentExternalResultsDefaultsKey = "dailyPulse.includeRecentExternalResults"
    internal nonisolated static let includeTrendContextDefaultsKey = "dailyPulse.includeTrendContext"
    internal nonisolated static let dedicatedModelDefaultsKey = "dailyPulseModelIdentifier"
    internal nonisolated static let lastViewedDayKeyDefaultsKey = "dailyPulse.lastViewedDayKey"
    internal nonisolated static let lastDeliveryAttemptDayKeyDefaultsKey = "dailyPulse.lastDeliveryAttemptDayKey"
#if os(iOS)
    var activeBackgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
#endif

    public init(
        chatService: ChatService,
        memoryManager: MemoryManager,
        defaults: UserDefaults = .standard
    ) {
        self.chatService = chatService
        self.memoryManager = memoryManager
        self.defaults = defaults
        self.retentionLimit = Self.persistedRetentionLimit
        let persistedRuns = Persistence.loadDailyPulseRuns().sorted(by: { $0.generatedAt > $1.generatedAt })
        let pendingCuration = Persistence.loadDailyPulsePendingCuration()
        self.runs = Self.visibleRuns(from: persistedRuns, referenceDate: Date())
        self.feedbackHistory = Persistence.loadDailyPulseFeedbackHistory().sorted(by: { $0.createdAt > $1.createdAt })
        self.pendingCuration = pendingCuration
        self.externalSignals = Self.trimmedExternalSignals(Persistence.loadDailyPulseExternalSignals(), limit: Self.externalSignalRetentionLimit)
        self.tasks = Self.sortedTasks(Persistence.loadDailyPulseTasks())
        self.focusText = defaults.string(forKey: Self.focusDefaultsKey) ?? ""
        self.tomorrowCurationText = pendingCuration?.text ?? ""
        self.lastViewedDayKey = defaults.string(forKey: Self.lastViewedDayKeyDefaultsKey)
        self.lastDeliveryAttemptDayKey = defaults.string(forKey: Self.lastDeliveryAttemptDayKeyDefaultsKey)
        if defaults.object(forKey: Self.autoGenerateDefaultsKey) == nil {
            defaults.set(true, forKey: Self.autoGenerateDefaultsKey)
        }
        if defaults.object(forKey: Self.includeMCPContextDefaultsKey) == nil {
            defaults.set(true, forKey: Self.includeMCPContextDefaultsKey)
        }
        if defaults.object(forKey: Self.includeShortcutContextDefaultsKey) == nil {
            defaults.set(true, forKey: Self.includeShortcutContextDefaultsKey)
        }
        if defaults.object(forKey: Self.includeRecentExternalResultsDefaultsKey) == nil {
            defaults.set(false, forKey: Self.includeRecentExternalResultsDefaultsKey)
        }
        if defaults.object(forKey: Self.includeTrendContextDefaultsKey) == nil {
            defaults.set(true, forKey: Self.includeTrendContextDefaultsKey)
        }
        self.autoGenerateEnabled = defaults.object(forKey: Self.autoGenerateDefaultsKey) as? Bool ?? true
        self.includeMCPContext = defaults.object(forKey: Self.includeMCPContextDefaultsKey) as? Bool ?? true
        self.includeShortcutContext = defaults.object(forKey: Self.includeShortcutContextDefaultsKey) as? Bool ?? true
        self.includeRecentExternalResults = defaults.object(forKey: Self.includeRecentExternalResultsDefaultsKey) as? Bool ?? false
        self.includeTrendContext = defaults.object(forKey: Self.includeTrendContextDefaultsKey) as? Bool ?? true
        prunePendingCurationIfNeeded(referenceDate: Date())
        if runs.count != persistedRuns.count {
            Persistence.saveDailyPulseRuns(runs)
        }
        if externalSignals.count != Persistence.loadDailyPulseExternalSignals().count {
            Persistence.saveDailyPulseExternalSignals(externalSignals)
        }
        if tasks != Self.sortedTasks(Persistence.loadDailyPulseTasks()) {
            Persistence.saveDailyPulseTasks(tasks)
        }

        syncNotificationObserver = NotificationCenter.default.addObserver(
            forName: .syncDailyPulseUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadPersistedRuns()
            }
        }
    }

    deinit {
        if let syncNotificationObserver {
            NotificationCenter.default.removeObserver(syncNotificationObserver)
        }
    }
}

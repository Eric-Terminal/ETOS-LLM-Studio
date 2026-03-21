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

public enum DailyPulseCardFeedback: String, Codable, Hashable, Sendable {
    case none
    case liked
    case disliked
    case hidden
}

public enum DailyPulseTrigger: String, Codable, Hashable, Sendable {
    case automatic
    case manual
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
            return NSLocalizedString("每日脉冲暂时无法生成：当前可用的聊天、记忆与关注焦点还不够。", comment: "Daily pulse error when not enough context is available")
        case .invalidModelOutput:
            return NSLocalizedString("每日脉冲生成失败：模型返回内容无法解析。", comment: "Daily pulse error when model output is invalid")
        }
    }
}

internal struct DailyPulseGenerationInput: Sendable {
    let focusText: String
    let sessionExcerpts: [DailyPulseSessionExcerpt]
    let memories: [String]
    let requestLogSummary: String
    let preferenceProfile: DailyPulsePreferenceProfile

    var hasUsableContext: Bool {
        !focusText.isEmpty
            || !sessionExcerpts.isEmpty
            || !memories.isEmpty
            || !requestLogSummary.isEmpty
            || preferenceProfile.hasSignals
    }

    var sourceDigest: String {
        let sessionDigest = sessionExcerpts
            .flatMap { [[$0.name], $0.lines].flatMap { $0 } }
            .joined(separator: "|")
        let memoryDigest = memories.joined(separator: "|")
        return [
            focusText,
            sessionDigest,
            memoryDigest,
            requestLogSummary,
            preferenceProfile.summaryText
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
    internal static let persistedRetentionLimit = 14

    @Published public private(set) var runs: [DailyPulseRun]
    @Published public private(set) var isGenerating: Bool = false
    @Published public private(set) var lastErrorMessage: String?
    @Published public var focusText: String {
        didSet {
            defaults.set(focusText, forKey: Self.focusDefaultsKey)
        }
    }
    @Published public var autoGenerateEnabled: Bool {
        didSet {
            defaults.set(autoGenerateEnabled, forKey: Self.autoGenerateDefaultsKey)
        }
    }

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "DailyPulse")
    private let chatService: ChatService
    private let memoryManager: MemoryManager
    private let defaults: UserDefaults
    private let retentionLimit = Self.persistedRetentionLimit
    private let cardsPerRun = 3
    private let candidateCardsPerRun = 6
    private let maxSessionsInPrompt = 4
    private let maxMessagesPerSession = 6
    private let maxMemoriesInPrompt = 8
    private var syncNotificationObserver: NSObjectProtocol?

    private static let autoGenerateDefaultsKey = "dailyPulse.autoGenerate"
    private static let focusDefaultsKey = "dailyPulse.focusText"

    public init(
        chatService: ChatService,
        memoryManager: MemoryManager,
        defaults: UserDefaults = .standard
    ) {
        self.chatService = chatService
        self.memoryManager = memoryManager
        self.defaults = defaults
        self.runs = Persistence.loadDailyPulseRuns().sorted(by: { $0.generatedAt > $1.generatedAt })
        self.focusText = defaults.string(forKey: Self.focusDefaultsKey) ?? ""
        if defaults.object(forKey: Self.autoGenerateDefaultsKey) == nil {
            defaults.set(true, forKey: Self.autoGenerateDefaultsKey)
        }
        self.autoGenerateEnabled = defaults.object(forKey: Self.autoGenerateDefaultsKey) as? Bool ?? true

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

    public var latestRun: DailyPulseRun? {
        runs.sorted(by: { $0.generatedAt > $1.generatedAt }).first
    }

    public var todayRun: DailyPulseRun? {
        runs.first(where: { $0.dayKey == Self.dayKey(for: Date()) })
    }

    public func reloadPersistedRuns() {
        runs = Persistence.loadDailyPulseRuns().sorted(by: { $0.generatedAt > $1.generatedAt })
    }

    public func clearError() {
        lastErrorMessage = nil
    }

    public func generateIfNeeded(trigger: DailyPulseTrigger = .automatic) async {
        if trigger == .automatic, !autoGenerateEnabled {
            return
        }
        let todayKey = Self.dayKey(for: Date())
        if trigger == .automatic, runs.contains(where: { $0.dayKey == todayKey }) {
            return
        }
        await generate(force: trigger == .manual, trigger: trigger)
    }

    public func generateNow() async {
        await generate(force: true, trigger: .manual)
    }

    public func applyFeedback(_ feedback: DailyPulseCardFeedback, cardID: UUID, runID: UUID) {
        runs = Self.applyingFeedback(feedback, to: cardID, runID: runID, in: runs)
        persistRuns()
    }

    @discardableResult
    public func saveCardAsSession(cardID: UUID, runID: UUID) -> ChatSession? {
        guard let card = card(cardID: cardID, runID: runID) else { return nil }
        let content = Self.archivedChatContent(for: card)
        let session = chatService.createSavedSession(
            name: card.title,
            initialMessages: [ChatMessage(role: .assistant, content: content)]
        )
        runs = Self.markingCardSaved(sessionID: session.id, cardID: cardID, runID: runID, in: runs)
        persistRuns()
        return session
    }

    internal static func applyingFeedback(
        _ feedback: DailyPulseCardFeedback,
        to cardID: UUID,
        runID: UUID,
        in runs: [DailyPulseRun]
    ) -> [DailyPulseRun] {
        runs.map { run in
            guard run.id == runID else { return run }
            var updatedRun = run
            updatedRun.cards = run.cards.map { card in
                guard card.id == cardID else { return card }
                var updatedCard = card
                updatedCard.feedback = feedback
                return updatedCard
            }
            return updatedRun
        }
    }

    internal static func markingCardSaved(
        sessionID: UUID,
        cardID: UUID,
        runID: UUID,
        in runs: [DailyPulseRun]
    ) -> [DailyPulseRun] {
        runs.map { run in
            guard run.id == runID else { return run }
            var updatedRun = run
            updatedRun.cards = run.cards.map { card in
                guard card.id == cardID else { return card }
                var updatedCard = card
                updatedCard.savedSessionID = sessionID
                return updatedCard
            }
            return updatedRun
        }
    }

    internal static func trimmedRuns(_ runs: [DailyPulseRun], limit: Int) -> [DailyPulseRun] {
        runs.sorted(by: { $0.generatedAt > $1.generatedAt }).prefix(max(1, limit)).map { $0 }
    }

    internal static func mergeRun(local: DailyPulseRun, incoming: DailyPulseRun) -> DailyPulseRun {
        let base = incoming.generatedAt >= local.generatedAt ? incoming : local
        let secondary = incoming.generatedAt >= local.generatedAt ? local : incoming

        let mergedCards = base.cards.map { baseCard in
            guard let matchingSecondary = secondary.cards.first(where: {
                areTopicsSimilar(topicText(for: $0), topicText(for: baseCard))
            }) else {
                return baseCard
            }

            var merged = baseCard
            merged.feedback = mergedFeedback(base: baseCard.feedback, incoming: matchingSecondary.feedback)
            if merged.savedSessionID == nil {
                merged.savedSessionID = matchingSecondary.savedSessionID
            }
            return merged
        }

        return DailyPulseRun(
            id: base.id,
            dayKey: base.dayKey,
            generatedAt: max(base.generatedAt, secondary.generatedAt),
            headline: base.headline,
            cards: mergedCards,
            sourceDigest: base.sourceDigest
        )
    }

    internal static func cleanedJSONObjectString(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            let cleaned = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    internal static func parseModelResponse(from raw: String) throws -> DailyPulseModelResponse {
        let cleaned = cleanedJSONObjectString(from: raw)
        let data = Data(cleaned.utf8)
        let decoder = JSONDecoder()
        return try decoder.decode(DailyPulseModelResponse.self, from: data)
    }

    internal static func archivedChatContent(for card: DailyPulseCard) -> String {
        let prompt = card.suggestedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "# \(card.title)",
            "",
            "> \(card.summary)",
            "",
            "## 为什么推荐给你",
            card.whyRecommended,
            "",
            "## 详情",
            card.detailsMarkdown,
            prompt.isEmpty ? "" : "\n## 建议追问\n\(prompt)"
        ]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func defaultContinuationPrompt(for card: DailyPulseCard) -> String {
        let suggested = card.suggestedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !suggested.isEmpty {
            return suggested
        }
        return "请继续展开这条每日脉冲，并结合我的现状给出更具体建议。"
    }

    private func generate(force: Bool, trigger: DailyPulseTrigger) async {
        if isGenerating { return }
        guard force || autoGenerateEnabled || trigger == .manual else { return }

        isGenerating = true
        lastErrorMessage = nil
        defer { isGenerating = false }

        do {
            let input = await buildGenerationInput()
            guard input.hasUsableContext else {
                throw DailyPulseGenerationError.insufficientContext
            }
            guard chatService.selectedModelSubject.value != nil || !chatService.activatedRunnableModels.isEmpty else {
                throw DailyPulseGenerationError.noModelSelected
            }

            let userPrompt = Self.makeUserPrompt(
                from: input,
                cardsPerRun: cardsPerRun,
                candidateCardsPerRun: candidateCardsPerRun
            )
            let raw = try await chatService.generateDetachedChatCompletion(
                systemPrompt: Self.systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.45
            )
            let parsed = try Self.parseModelResponse(from: raw)
            let cards = Self.makeCards(
                from: parsed.cards,
                fallbackFocus: input.focusText,
                profile: input.preferenceProfile,
                limit: cardsPerRun
            )
            guard !cards.isEmpty else {
                throw DailyPulseGenerationError.invalidModelOutput
            }

            let now = Date()
            let newRun = DailyPulseRun(
                dayKey: Self.dayKey(for: now),
                generatedAt: now,
                headline: Self.normalizedText(parsed.headline, fallback: "今天这几条值得你看"),
                cards: cards,
                sourceDigest: input.sourceDigest
            )
            upsertRun(newRun)
            logger.info("每日脉冲已生成，触发方式: \(trigger.rawValue, privacy: .public)，卡片数: \(cards.count)")
        } catch {
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if trigger == .manual || !runs.contains(where: { $0.dayKey == Self.dayKey(for: Date()) }) {
                lastErrorMessage = description
            }
            logger.error("每日脉冲生成失败: \(description, privacy: .public)")
        }
    }

    private func upsertRun(_ run: DailyPulseRun) {
        var updatedRuns = runs.filter { $0.dayKey != run.dayKey }
        updatedRuns.insert(run, at: 0)
        runs = Self.trimmedRuns(updatedRuns, limit: retentionLimit)
        persistRuns()
    }

    private func persistRuns() {
        Persistence.saveDailyPulseRuns(runs)
    }

    private func card(cardID: UUID, runID: UUID) -> DailyPulseCard? {
        runs.first(where: { $0.id == runID })?.cards.first(where: { $0.id == cardID })
    }

    private func buildGenerationInput() async -> DailyPulseGenerationInput {
        await memoryManager.waitForInitialization()
        let sessionExcerpts = buildSessionExcerpts()
        let memories = buildMemoryExcerpts()
        let requestLogSummary = buildRequestLogSummary()
        let preferenceProfile = buildPreferenceProfile(from: runs)
        return DailyPulseGenerationInput(
            focusText: focusText.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionExcerpts: sessionExcerpts,
            memories: memories,
            requestLogSummary: requestLogSummary,
            preferenceProfile: preferenceProfile
        )
    }

    private func buildPreferenceProfile(from runs: [DailyPulseRun]) -> DailyPulsePreferenceProfile {
        let recentRuns = runs
            .sorted(by: { $0.generatedAt > $1.generatedAt })
            .prefix(10)

        var positive: [String] = []
        var negative: [String] = []
        var recentVisible: [String] = []

        for run in recentRuns {
            for card in run.cards {
                let topic = Self.topicText(for: card)
                if card.savedSessionID != nil || card.feedback == .liked {
                    positive.append(topic)
                }
                if card.feedback == .disliked || card.feedback == .hidden {
                    negative.append(topic)
                }
                if card.isVisible {
                    recentVisible.append(topic)
                }
            }
        }

        return DailyPulsePreferenceProfile(
            positiveHints: Self.deduplicatedTopicHints(positive, limit: 8),
            negativeHints: Self.deduplicatedTopicHints(negative, limit: 8),
            recentVisibleHints: Self.deduplicatedTopicHints(recentVisible, limit: 10)
        )
    }

    private func buildSessionExcerpts() -> [DailyPulseSessionExcerpt] {
        var orderedSessions = chatService.chatSessionsSubject.value
        if let current = chatService.currentSessionSubject.value,
           !orderedSessions.contains(where: { $0.id == current.id }) {
            orderedSessions.insert(current, at: 0)
        }

        var results: [DailyPulseSessionExcerpt] = []
        results.reserveCapacity(maxSessionsInPrompt)

        for session in orderedSessions {
            let messages = Persistence.loadMessages(for: session.id)
                .filter { $0.role == .user || $0.role == .assistant }
            guard !messages.isEmpty else { continue }

            let lines = messages.suffix(maxMessagesPerSession).compactMap { message -> String? in
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let prefix = message.role == .user ? "用户" : "助手"
                return "\(prefix)：\(Self.truncated(trimmed, limit: 180))"
            }
            guard !lines.isEmpty else { continue }

            let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(
                DailyPulseSessionExcerpt(
                    name: name.isEmpty ? "未命名会话" : name,
                    lines: Array(lines)
                )
            )
            if results.count >= maxSessionsInPrompt {
                break
            }
        }
        return results
    }

    private func buildMemoryExcerpts() -> [String] {
        memoryManager.currentMemoriesSnapshot()
            .filter { !$0.isArchived }
            .prefix(maxMemoriesInPrompt)
            .map { Self.truncated($0.content.trimmingCharacters(in: .whitespacesAndNewlines), limit: 120) }
            .filter { !$0.isEmpty }
    }

    private func buildRequestLogSummary() -> String {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let from = calendar.date(byAdding: .day, value: -7, to: now)
        let summary = Persistence.summarizeRequestLogs(query: RequestLogQuery(from: from, to: now, limit: 50))
        guard summary.totalRequests > 0 else { return "" }

        let providerSummary = summary.byProvider
            .sorted { $0.requestCount > $1.requestCount }
            .prefix(3)
            .map { "\($0.key)×\($0.requestCount)" }
            .joined(separator: "，")
        let modelSummary = summary.byModel
            .sorted { $0.requestCount > $1.requestCount }
            .prefix(3)
            .map { "\($0.key)×\($0.requestCount)" }
            .joined(separator: "，")

        return [
            "最近 7 天请求数：\(summary.totalRequests)",
            providerSummary.isEmpty ? "" : "常用提供商：\(providerSummary)",
            modelSummary.isEmpty ? "" : "常用模型：\(modelSummary)"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func makeCards(
        from cards: [DailyPulseModelCard],
        fallbackFocus: String,
        profile: DailyPulsePreferenceProfile,
        limit: Int
    ) -> [DailyPulseCard] {
        let normalizedCandidates = cards.prefix(max(1, limit * 3)).compactMap { card in
            let title = normalizedText(card.title, fallback: "今日提醒")
            let summary = normalizedText(card.summary, fallback: "暂无摘要")
            let why = normalizedText(card.why, fallback: fallbackFocus.isEmpty ? "这条内容与你最近的聊天和使用轨迹相关。" : "这条内容与你当前关注的“\(fallbackFocus)”有关。")
            let details = normalizedMultilineText(card.detailsMarkdown, fallback: summary)
            let suggestedPrompt = normalizedText(card.suggestedPrompt, fallback: "请结合这条每日脉冲继续展开，并给我更具体的下一步建议。")
            guard !title.isEmpty, !summary.isEmpty else { return nil }
            return DailyPulseCard(
                title: truncated(title, limit: 40),
                whyRecommended: truncated(why, limit: 120),
                summary: truncated(summary, limit: 180),
                detailsMarkdown: truncated(details, limit: 2_000),
                suggestedPrompt: truncated(suggestedPrompt, limit: 160)
            )
        }

        return selectCards(
            from: normalizedCandidates,
            profile: profile,
            focusText: fallbackFocus,
            limit: limit
        )
    }

    internal static func selectCards(
        from candidates: [DailyPulseCard],
        profile: DailyPulsePreferenceProfile,
        focusText: String,
        limit: Int
    ) -> [DailyPulseCard] {
        let scored = candidates.enumerated().map { index, card in
            (
                index: index,
                card: card,
                score: score(card: card, profile: profile, focusText: focusText)
            )
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.index < rhs.index
            }
            return lhs.score > rhs.score
        }

        var selected: [DailyPulseCard] = []
        var usedCategories = Set<String>()

        for item in scored {
            guard selected.count < limit else { break }
            guard !matchesAnyHint(item.card, hints: profile.negativeHints) else { continue }
            guard !containsSimilarCard(item.card, in: selected) else { continue }

            let category = categoryHint(for: item.card)
            if category != "general", usedCategories.contains(category), scored.count > limit {
                continue
            }

            selected.append(item.card)
            usedCategories.insert(category)
        }

        if selected.count < limit {
            for item in scored {
                guard selected.count < limit else { break }
                guard !containsSimilarCard(item.card, in: selected) else { continue }
                selected.append(item.card)
            }
        }

        return Array(selected.prefix(max(1, limit)))
    }

    private static let systemPrompt = """
    你是 ETOS LLM Studio 的“每日脉冲”策展助手。

    任务：
    - 依据用户最近聊天、长期记忆、近期使用轨迹、最近卡片反馈与用户主动填写的关注焦点，输出一组候选卡片。
    - 卡片要尽量具体、可继续对话、可直接转成一个新会话。
    - 优先推荐近期可行动、可延续、和用户真实上下文强相关的话题。
    - 不要捏造用户经历，不要凭空加入外部事实；如果上下文不足，就保守一点。
    - 输出要有明显多样性，避免所有卡片都围绕同一件事。
    - 如果用户已经明确 dislike / hidden 某类主题，就尽量别再推同类主题。
    - 如果用户过去喜欢或保存过某类主题，可以适度延续，但不要机械重复昨天的标题。

    输出要求：
    - 只返回 JSON，不要使用 Markdown 代码块。
    - JSON 结构必须严格符合：
      {
        "headline": "一句话总标题",
        "cards": [
          {
            "title": "卡片标题",
            "why": "为什么推荐给用户",
            "summary": "一句或两句摘要",
            "details_markdown": "可保存为聊天的详细 Markdown 内容",
            "suggested_prompt": "用户点继续聊时可直接发送的追问"
          }
        ]
      }
    """

    private static func makeUserPrompt(
        from input: DailyPulseGenerationInput,
        cardsPerRun: Int,
        candidateCardsPerRun: Int
    ) -> String {
        let sessionBlock: String = {
            guard !input.sessionExcerpts.isEmpty else { return "（无）" }
            return input.sessionExcerpts.enumerated().map { index, excerpt in
                let lines = excerpt.lines.joined(separator: "\n")
                return "### 会话 \(index + 1)：\(excerpt.name)\n\(lines)"
            }.joined(separator: "\n\n")
        }()

        let memoryBlock: String = {
            guard !input.memories.isEmpty else { return "（无）" }
            return input.memories.map { "- \($0)" }.joined(separator: "\n")
        }()

        let focus = input.focusText.isEmpty ? "（未填写）" : input.focusText
        let logSummary = input.requestLogSummary.isEmpty ? "（无）" : input.requestLogSummary

        return """
        当前时间：\(Self.userFacingDateString(from: Date()))
        最终展示目标卡片数：\(cardsPerRun)
        候选卡片建议输出数：\(candidateCardsPerRun)

        用户关注焦点：
        \(focus)

        最近聊天摘要：
        \(sessionBlock)

        长期记忆：
        \(memoryBlock)

        最近请求日志摘要：
        \(logSummary)

        最近卡片偏好与历史：
        \(input.preferenceProfile.summaryText)

        请基于这些信息，为用户生成今日的每日脉冲候选卡片。
        """
    }

    internal static func score(card: DailyPulseCard, profile: DailyPulsePreferenceProfile, focusText: String) -> Int {
        var score = 0
        let topic = topicText(for: card)

        if !focusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           areTopicsSimilar(topic, focusText) || normalizedContains(topic, focusText) {
            score += 4
        }
        if matchesAnyHint(card, hints: profile.positiveHints) {
            score += 3
        }
        if matchesAnyHint(card, hints: profile.recentVisibleHints) {
            score -= 2
        }
        if matchesAnyHint(card, hints: profile.negativeHints) {
            score -= 6
        }
        if card.detailsMarkdown.count > 80 {
            score += 1
        }
        return score
    }

    internal static func deduplicatedTopicHints(_ topics: [String], limit: Int) -> [String] {
        var result: [String] = []
        for topic in topics {
            let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !result.contains(where: { areTopicsSimilar($0, trimmed) }) else { continue }
            result.append(trimmed)
            if result.count >= max(1, limit) {
                break
            }
        }
        return result
    }

    internal static func containsSimilarCard(_ candidate: DailyPulseCard, in cards: [DailyPulseCard]) -> Bool {
        cards.contains { existing in
            areTopicsSimilar(topicText(for: existing), topicText(for: candidate))
        }
    }

    internal static func matchesAnyHint(_ card: DailyPulseCard, hints: [String]) -> Bool {
        let topic = topicText(for: card)
        return hints.contains(where: { hint in
            areTopicsSimilar(topic, hint) || normalizedContains(topic, hint) || normalizedContains(hint, topic)
        })
    }

    internal static func topicText(for card: DailyPulseCard) -> String {
        "\(card.title) \(card.summary)"
    }

    internal static func normalizedContains(_ lhs: String, _ rhs: String) -> Bool {
        let left = topicFingerprint(lhs)
        let right = topicFingerprint(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.contains(right) || right.contains(left)
    }

    internal static func areTopicsSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let left = topicFingerprint(lhs)
        let right = topicFingerprint(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right || left.contains(right) || right.contains(left) {
            return true
        }

        let leftSet = Set(left)
        let rightSet = Set(right)
        guard !leftSet.isEmpty, !rightSet.isEmpty else { return false }
        let overlap = leftSet.intersection(rightSet).count
        let union = leftSet.union(rightSet).count
        guard union > 0 else { return false }
        return Double(overlap) / Double(union) >= 0.72
    }

    internal static func topicFingerprint(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
        let filteredScalars = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || isCJK(scalar)
        }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        return String(filtered.prefix(48))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static func categoryHint(for card: DailyPulseCard) -> String {
        let text = "\(card.title) \(card.summary) \(card.whyRecommended)"
        let normalized = topicFingerprint(text)
        if normalized.contains("项目") || normalized.contains("开发") || normalized.contains("代码") || normalized.contains("实现") {
            return "project"
        }
        if normalized.contains("计划") || normalized.contains("下一步") || normalized.contains("待办") || normalized.contains("行动") {
            return "action"
        }
        if normalized.contains("学习") || normalized.contains("理解") || normalized.contains("原理") || normalized.contains("知识") {
            return "learning"
        }
        if normalized.contains("总结") || normalized.contains("复盘") || normalized.contains("整理") || normalized.contains("回顾") {
            return "reflection"
        }
        return "general"
    }

    private static func mergedFeedback(base: DailyPulseCardFeedback, incoming: DailyPulseCardFeedback) -> DailyPulseCardFeedback {
        let priority: [DailyPulseCardFeedback: Int] = [
            .none: 0,
            .liked: 1,
            .disliked: 2,
            .hidden: 3
        ]
        return (priority[incoming] ?? 0) > (priority[base] ?? 0) ? incoming : base
    }

    internal static func normalizedText(_ text: String?, fallback: String) -> String {
        let trimmed = text?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    internal static func normalizedMultilineText(_ text: String?, fallback: String) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    internal static func truncated(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    public static func dayKey(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func userFacingDateString(from date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

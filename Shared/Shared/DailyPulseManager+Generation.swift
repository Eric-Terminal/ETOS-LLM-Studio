import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#endif

extension DailyPulseManager {
    func generate(
        force: Bool,
        trigger: DailyPulseTrigger,
        notifyReadyWhenFinished: Bool = false
    ) async {
        if isGenerating { return }
        guard force || autoGenerateEnabled || trigger == .manual || trigger == .delivery else { return }
        prunePendingCurationIfNeeded(referenceDate: Date())

        beginGenerationBackgroundTaskIfNeeded()
        beginPreparation(referenceDate: Date())
        isGenerating = true
        lastErrorMessage = nil
        defer {
            isGenerating = false
            finishPreparation()
            endGenerationBackgroundTaskIfNeeded()
        }

        do {
            let input = await buildGenerationInput()
            guard input.hasUsableContext else {
                throw DailyPulseGenerationError.insufficientContext
            }
            guard let generationModel = resolveGenerationModel() else {
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
                temperature: 0.45,
                runnableModel: generationModel,
                requestSource: .dailyPulse
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
            let todayKey = Self.dayKey(for: now)
            let newRun = DailyPulseRun(
                dayKey: todayKey,
                generatedAt: now,
                headline: Self.normalizedText(parsed.headline, fallback: "今天这几条值得你看"),
                cards: cards,
                sourceDigest: input.sourceDigest
            )
            upsertRun(newRun)
            if pendingCuration?.targetDayKey == todayKey {
                pendingCuration = nil
                if !tomorrowCurationText.isEmpty {
                    tomorrowCurationText = ""
                } else {
                    Persistence.saveDailyPulsePendingCuration(nil)
                }
            }
            if notifyReadyWhenFinished {
                await DailyPulseDeliveryCoordinator.shared.notifyReadyIfNeeded(for: newRun)
            }
            logger.info("每日脉冲已生成，触发方式: \(trigger.rawValue, privacy: .public)，卡片数: \(cards.count)")
        } catch {
            if Self.isCancellationError(error) || Task.isCancelled {
                logger.info("每日脉冲生成已取消，触发方式: \(trigger.rawValue, privacy: .public)")
                return
            }

            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if trigger == .manual {
                lastErrorMessage = description
            }
            logger.error("每日脉冲生成失败: \(description, privacy: .public)")
        }
    }

    func upsertRun(_ run: DailyPulseRun) {
        var updatedRuns = runs.filter { $0.dayKey != run.dayKey }
        updatedRuns.insert(run, at: 0)
        runs = Self.trimmedRuns(updatedRuns, limit: retentionLimit)
        persistRuns()
    }

    func persistRuns() {
        Persistence.saveDailyPulseRuns(runs)
    }

    func persistTasks() {
        tasks = Self.sortedTasks(tasks)
        Persistence.saveDailyPulseTasks(tasks)
    }

    func appendFeedbackEvent(_ event: DailyPulseFeedbackEvent) {
        feedbackHistory = Self.appendingFeedbackEvent(
            event,
            to: feedbackHistory,
            limit: Self.feedbackHistoryRetentionLimit
        )
        Persistence.saveDailyPulseFeedbackHistory(feedbackHistory)
    }

    func persistPendingCurationFromDraft(referenceDate: Date = Date()) {
        let trimmed = tomorrowCurationText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            pendingCuration = nil
            Persistence.saveDailyPulsePendingCuration(nil)
            return
        }

        let note = DailyPulseCurationNote(
            id: pendingCuration?.id ?? UUID(),
            targetDayKey: Self.nextDayKey(from: referenceDate),
            text: trimmed,
            createdAt: pendingCuration?.createdAt ?? Date()
        )
        pendingCuration = note
        Persistence.saveDailyPulsePendingCuration(note)
    }

    func prunePendingCurationIfNeeded(referenceDate: Date) {
        guard let pendingCuration else { return }
        let todayKey = Self.dayKey(for: referenceDate)
        if pendingCuration.targetDayKey < todayKey {
            self.pendingCuration = nil
            if tomorrowCurationText == pendingCuration.text {
                tomorrowCurationText = ""
            }
            Persistence.saveDailyPulsePendingCuration(nil)
        }
    }

    func card(cardID: UUID, runID: UUID) -> DailyPulseCard? {
        runs.first(where: { $0.id == runID })?.cards.first(where: { $0.id == cardID })
    }

    func buildGenerationInput() async -> DailyPulseGenerationInput {
        await memoryManager.waitForInitialization()
        prunePendingCurationIfNeeded(referenceDate: Date())
        let sessionExcerpts = buildSessionExcerpts()
        let memories = buildMemoryExcerpts()
        let requestLogSummary = buildRequestLogSummary()
        let todayKey = Self.dayKey(for: Date())
        let activeTasks = pendingTasks
        let preferenceProfile = Self.makePreferenceProfile(history: feedbackHistory, recentRuns: runs)
        let externalContext = buildExternalContext()
        return DailyPulseGenerationInput(
            focusText: focusText.trimmingCharacters(in: .whitespacesAndNewlines),
            curationText: Self.activeCurationText(for: todayKey, pendingCuration: pendingCuration),
            sessionExcerpts: sessionExcerpts,
            memories: memories,
            requestLogSummary: requestLogSummary,
            activeTasks: activeTasks,
            preferenceProfile: preferenceProfile,
            externalContext: externalContext
        )
    }

    func buildExternalContext() -> DailyPulseExternalContext {
        let mcpLines: [String]
        if includeMCPContext {
            let servers = MCPServerStore.loadServers()
            let metadataByServerID = Dictionary(uniqueKeysWithValues: servers.map { server in
                (server.id, MCPServerStore.loadMetadata(for: server.id))
            })
            mcpLines = Self.makeMCPContextEntries(
                servers: servers,
                metadataByServerID: metadataByServerID,
                limit: 3
            )
        } else {
            mcpLines = []
        }

        let shortcutLines = includeShortcutContext
            ? Self.makeShortcutContextEntries(
                tools: ShortcutToolStore.loadTools(),
                limit: 4
            )
            : []
        let recentSnapshotLines = includeRecentExternalResults
            ? Self.makeRecentExternalSnapshotEntries(
                shortcutResult: ShortcutToolManager.shared.lastExecutionResult,
                mcpOperationOutput: MCPManager.shared.lastOperationOutput,
                mcpOperationError: MCPManager.shared.lastOperationError,
                limit: 3
            )
            : []
        let trendLines = includeTrendContext
            ? Self.makeTrendContextEntries(
                announcements: AnnouncementManager.shared.currentAnnouncements,
                limit: 3
            )
            : []
        let signalHistoryLines = Self.makeSignalHistoryEntries(
            signals: externalSignals,
            includeResultSignals: includeRecentExternalResults,
            includeTrendSignals: includeTrendContext,
            limit: 5
        )

        return DailyPulseExternalContext(
            mcpSourceLines: mcpLines,
            shortcutSourceLines: shortcutLines,
            recentSnapshotLines: recentSnapshotLines,
            trendSourceLines: trendLines,
            signalHistoryLines: signalHistoryLines
        )
    }

    internal nonisolated static func makePreferenceProfile(
        history: [DailyPulseFeedbackEvent],
        recentRuns: [DailyPulseRun]
    ) -> DailyPulsePreferenceProfile {
        let recentRunSlice = recentRuns
            .sorted(by: { $0.generatedAt > $1.generatedAt })
            .prefix(10)

        var positive = history
            .filter { $0.action == .liked || $0.action == .saved }
            .map(\.topicHint)
        var negative = history
            .filter { $0.action == .disliked || $0.action == .hidden }
            .map(\.topicHint)
        var recentVisible: [String] = []

        for run in recentRunSlice {
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

    func buildSessionExcerpts() -> [DailyPulseSessionExcerpt] {
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

    func buildMemoryExcerpts() -> [String] {
        memoryManager.currentMemoriesSnapshot()
            .filter { !$0.isArchived }
            .prefix(maxMemoriesInPrompt)
            .map { Self.truncated($0.content.trimmingCharacters(in: .whitespacesAndNewlines), limit: 120) }
            .filter { !$0.isEmpty }
    }

    func buildRequestLogSummary() -> String {
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

    static func makeCards(
        from cards: [DailyPulseModelCard],
        fallbackFocus: String,
        profile: DailyPulsePreferenceProfile,
        limit: Int
    ) -> [DailyPulseCard] {
        var normalizedCandidates: [DailyPulseCard] = []
        normalizedCandidates.reserveCapacity(min(cards.count, max(1, limit * 3)))
        for card in cards.prefix(max(1, limit * 3)) {
            let title = normalizedText(card.title, fallback: "今日提醒")
            let summary = normalizedText(card.summary, fallback: "暂无摘要")
            let why = normalizedText(card.why, fallback: fallbackFocus.isEmpty ? "这条内容与你最近的聊天和使用轨迹相关。" : "这条内容与你当前关注的“\(fallbackFocus)”有关。")
            let details = normalizedMultilineText(card.detailsMarkdown, fallback: summary)
            let suggestedPrompt = normalizedText(card.suggestedPrompt, fallback: "请结合这条每日脉冲继续展开，并给我更具体的下一步建议。")
            guard !title.isEmpty, !summary.isEmpty else { continue }
            normalizedCandidates.append(DailyPulseCard(
                title: truncated(title, limit: 40),
                whyRecommended: truncated(why, limit: 120),
                summary: truncated(summary, limit: 180),
                detailsMarkdown: truncated(details, limit: 2_000),
                suggestedPrompt: truncated(suggestedPrompt, limit: 160)
            ))
        }

        return selectCards(
            from: normalizedCandidates,
            profile: profile,
            focusText: fallbackFocus,
            limit: limit
        )
    }

    internal nonisolated static func selectCards(
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
                guard !matchesAnyHint(item.card, hints: profile.negativeHints) else { continue }
                guard !containsSimilarCard(item.card, in: selected) else { continue }
                selected.append(item.card)
            }
        }

        return Array(selected.prefix(max(1, limit)))
    }

    static let systemPrompt = """
    你是 ETOS LLM Studio 的“每日脉冲”策展助手。

    任务：
    - 依据用户最近聊天、长期记忆、近期使用轨迹、最近卡片反馈、外部能力上下文、用户主动填写的关注焦点与“明日想看什么”策展输入，输出一组候选卡片。
    - 如果给到了未完成的 Pulse 任务，请优先帮助用户推进这些任务，但不要把已经完成的任务原样重复成卡片标题。
    - 卡片要尽量具体、可继续对话、可直接转成一个新会话。
    - 优先推荐近期可行动、可延续、和用户真实上下文强相关的话题。
    - 不要捏造用户经历，不要凭空加入外部事实；如果上下文不足，就保守一点。
    - 如果有 MCP / 快捷指令能力上下文，可以优先推荐“能马上借助这些能力继续推进”的卡片。
    - 工具能力描述只代表“可以调用的能力”，不代表你已经读取到外部实时数据。
    - 如果给到了“最近已获取到的外部结果快照”，那部分才代表用户最近真的拿到过的外部内容。
    - 如果给到了“公告与趋势信号”，可以把它们当作近期外部变化，但不要夸大成已经完全确认的个人事实。
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

}

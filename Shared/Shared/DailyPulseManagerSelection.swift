// ============================================================================
// DailyPulseManagerSelection.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责每日脉冲管理器的卡片评分、筛选、提示词构造与主题相似度判断。
// ============================================================================

import Foundation

extension DailyPulseManager {
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

    static func makeUserPrompt(
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
        let curation = input.curationText.isEmpty ? "（无）" : input.curationText
        let logSummary = input.requestLogSummary.isEmpty ? "（无）" : input.requestLogSummary
        let taskBlock: String = {
            guard !input.activeTasks.isEmpty else { return "（无）" }
            return input.activeTasks.prefix(6).map { task in
                "- \(task.title)：\(task.details)"
            }.joined(separator: "\n")
        }()

        return """
        当前时间：\(Self.userFacingDateString(from: Date()))
        最终展示目标卡片数：\(cardsPerRun)
        候选卡片建议输出数：\(candidateCardsPerRun)

        用户关注焦点：
        \(focus)

        明日策展要求：
        \(curation)

        最近聊天摘要：
        \(sessionBlock)

        长期记忆：
        \(memoryBlock)

        最近请求日志摘要：
        \(logSummary)

        当前未完成的 Pulse 任务：
        \(taskBlock)

        最近卡片偏好与历史：
        \(input.preferenceProfile.summaryText)

        外部上下文与可用能力：
        \(input.externalContext.summaryText)

        请基于这些信息，为用户生成今日的每日脉冲候选卡片。
        """
    }

    internal nonisolated static func score(card: DailyPulseCard, profile: DailyPulsePreferenceProfile, focusText: String) -> Int {
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

    internal nonisolated static func deduplicatedTopicHints(_ topics: [String], limit: Int) -> [String] {
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

    internal nonisolated static func containsSimilarCard(_ candidate: DailyPulseCard, in cards: [DailyPulseCard]) -> Bool {
        cards.contains { existing in
            areTopicsSimilar(topicText(for: existing), topicText(for: candidate))
        }
    }

    internal nonisolated static func matchesAnyHint(_ card: DailyPulseCard, hints: [String]) -> Bool {
        let topic = topicText(for: card)
        return hints.contains(where: { hint in
            areTopicsSimilar(topic, hint) || normalizedContains(topic, hint) || normalizedContains(hint, topic)
        })
    }

    internal nonisolated static func topicText(for card: DailyPulseCard) -> String {
        "\(card.title) \(card.summary)"
    }

    internal nonisolated static func normalizedContains(_ lhs: String, _ rhs: String) -> Bool {
        let left = topicFingerprint(lhs)
        let right = topicFingerprint(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.contains(right) || right.contains(left)
    }

    internal nonisolated static func areTopicsSimilar(_ lhs: String, _ rhs: String) -> Bool {
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

    internal nonisolated static func topicFingerprint(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_CN"))
        let filteredScalars = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || isCJK(scalar)
        }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        return String(filtered.prefix(48))
    }

    private nonisolated static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private nonisolated static func categoryHint(for card: DailyPulseCard) -> String {
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
}

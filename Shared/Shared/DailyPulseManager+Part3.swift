import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#endif

extension DailyPulseManager {
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

    nonisolated static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    nonisolated static func categoryHint(for card: DailyPulseCard) -> String {
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

    internal nonisolated static func makeMCPContextEntries(
        servers: [MCPServerConfiguration],
        metadataByServerID: [UUID: MCPServerMetadataCache?],
        limit: Int
    ) -> [String] {
        let prioritizedServers = servers.sorted { lhs, rhs in
            if lhs.isSelectedForChat != rhs.isSelectedForChat {
                return lhs.isSelectedForChat && !rhs.isSelectedForChat
            }

            let lhsMetadata = metadataByServerID[lhs.id] ?? nil
            let rhsMetadata = metadataByServerID[rhs.id] ?? nil
            let lhsCapabilityCount = (lhsMetadata?.tools.count ?? 0) + (lhsMetadata?.prompts.count ?? 0) + (lhsMetadata?.resources.count ?? 0)
            let rhsCapabilityCount = (rhsMetadata?.tools.count ?? 0) + (rhsMetadata?.prompts.count ?? 0) + (rhsMetadata?.resources.count ?? 0)
            if lhsCapabilityCount != rhsCapabilityCount {
                return lhsCapabilityCount > rhsCapabilityCount
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        var entries: [String] = []
        for server in prioritizedServers {
            var parts: [String] = []

            if server.isSelectedForChat {
                parts.append("已选中用于聊天")
            }

            if let notes = normalizedOptionalText(server.notes, fallback: nil) {
                parts.append("备注：\(truncated(notes, limit: 36))")
            }

            if let metadata = metadataByServerID[server.id] ?? nil {
                let enabledToolIDs = metadata.tools
                    .filter { server.isToolEnabled($0.toolId) }
                    .map(\.toolId)
                if !enabledToolIDs.isEmpty {
                    let sample = enabledToolIDs.prefix(3).joined(separator: "、")
                    parts.append("工具 \(enabledToolIDs.count) 个（\(sample)）")
                }

                let promptNames = metadata.prompts.map(\.name)
                if !promptNames.isEmpty {
                    parts.append("提示词：\(promptNames.prefix(2).joined(separator: "、"))")
                }

                let resourceIDs = metadata.resources.map(\.resourceId)
                if !resourceIDs.isEmpty {
                    parts.append("资源：\(resourceIDs.prefix(2).joined(separator: "、"))")
                }
            }

            guard !parts.isEmpty else { continue }
            entries.append("- \(server.displayName)：\(parts.joined(separator: "；"))")
            if entries.count >= max(1, limit) {
                break
            }
        }

        return entries
    }

    internal nonisolated static func makeShortcutContextEntries(
        tools: [ShortcutToolDefinition],
        limit: Int
    ) -> [String] {
        let enabledTools = tools
            .filter(\.isEnabled)
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }

        var entries: [String] = []
        for tool in enabledTools.prefix(max(1, limit)) {
            var parts: [String] = []
            parts.append(truncated(tool.effectiveDescription, limit: 64))

            switch tool.runModeHint {
            case .bridge:
                parts.append("桥接执行")
            case .direct:
                parts.append("直接执行")
            }

            if let source = normalizedOptionalText(tool.source, fallback: nil) {
                parts.append("来源：\(truncated(source, limit: 24))")
            }

            entries.append("- \(tool.displayName)：\(parts.joined(separator: "；"))")
        }
        return entries
    }

    internal nonisolated static func makeRecentExternalSnapshotEntries(
        shortcutResult: ShortcutToolExecutionResult?,
        mcpOperationOutput: String?,
        mcpOperationError: String?,
        limit: Int
    ) -> [String] {
        var entries: [String] = []

        if let shortcutResult {
            let timeText = compactUserFacingDateString(from: shortcutResult.finishedAt)
            if shortcutResult.success {
                let preview = resultPreviewText(
                    shortcutResult.result,
                    fallback: "执行成功，但没有返回可展示的文本结果。"
                )
                entries.append("- 最近快捷指令结果（\(shortcutResult.toolName)，\(timeText)）：\(preview)")
            } else {
                let preview = resultPreviewText(
                    shortcutResult.errorMessage,
                    fallback: "执行失败，但没有返回详细错误。"
                )
                entries.append("- 最近快捷指令失败（\(shortcutResult.toolName)，\(timeText)）：\(preview)")
            }
        }

        if let output = normalizedOptionalText(mcpOperationOutput, fallback: nil) {
            entries.append("- 最近 MCP 输出：\(resultPreviewText(output, fallback: "暂无输出"))")
        } else if let error = normalizedOptionalText(mcpOperationError, fallback: nil) {
            entries.append("- 最近 MCP 错误：\(resultPreviewText(error, fallback: "暂无错误详情"))")
        }

        return Array(entries.prefix(max(1, limit)))
    }

    internal nonisolated static func makeTrendContextEntries(
        announcements: [Announcement],
        limit: Int
    ) -> [String] {
        announcements.prefix(max(1, limit)).map { announcement in
            let preview = resultPreviewText(announcement.body, fallback: announcement.title)
            return "- \(announcement.title)：\(preview)"
        }
    }

    internal nonisolated static func makeSignalHistoryEntries(
        signals: [DailyPulseExternalSignal],
        includeResultSignals: Bool,
        includeTrendSignals: Bool,
        limit: Int
    ) -> [String] {
        let filtered = signals.filter { signal in
            switch signal.source {
            case .announcement:
                return includeTrendSignals
            case .shortcutResult, .mcpOutput, .mcpError:
                return includeResultSignals
            }
        }

        return filtered
            .sorted(by: { $0.capturedAt > $1.capturedAt })
            .prefix(max(1, limit))
            .map { signal in
                let timeText = compactUserFacingDateString(from: signal.capturedAt)
                let suffix = signal.isFailure ? "（失败）" : ""
                return "- \(signal.title)\(suffix) · \(timeText)：\(resultPreviewText(signal.preview, fallback: signal.title))"
            }
    }

    internal nonisolated static func makeAnnouncementSignals(from announcements: [Announcement]) -> [DailyPulseExternalSignal] {
        announcements.map { announcement in
            DailyPulseExternalSignal(
                source: .announcement,
                title: announcement.title,
                preview: normalizedText(announcement.body, fallback: announcement.title),
                capturedAt: Date(),
                isFailure: announcement.type == .blocking
            )
        }
    }

    internal nonisolated static func syncingAnnouncementSignals(
        _ announcements: [Announcement],
        in history: [DailyPulseExternalSignal],
        limit: Int
    ) -> [DailyPulseExternalSignal] {
        var nextHistory = history.filter { $0.source != .announcement }
        let signals = makeAnnouncementSignals(from: announcements)

        for signal in signals {
            nextHistory = appendingExternalSignal(
                signal,
                to: nextHistory,
                limit: limit
            )
        }

        return trimmedExternalSignals(nextHistory, limit: limit)
    }

    internal nonisolated static func historyAction(for feedback: DailyPulseCardFeedback) -> DailyPulseHistoryAction? {
        switch feedback {
        case .liked:
            return .liked
        case .disliked:
            return .disliked
        case .hidden:
            return .hidden
        case .none:
            return nil
        }
    }

    internal nonisolated static func appendingFeedbackEvent(
        _ event: DailyPulseFeedbackEvent,
        to history: [DailyPulseFeedbackEvent],
        limit: Int
    ) -> [DailyPulseFeedbackEvent] {
        var updated = history
        if let existingIndex = updated.firstIndex(where: {
            $0.dayKey == event.dayKey
                && areTopicsSimilar($0.topicHint, event.topicHint)
                && $0.action == event.action
        }) {
            updated[existingIndex] = event
        } else {
            updated.insert(event, at: 0)
        }

        return Array(
            updated
                .sorted(by: { $0.createdAt > $1.createdAt })
                .prefix(max(1, limit))
        )
    }

    internal nonisolated static func appendingExternalSignal(
        _ signal: DailyPulseExternalSignal,
        to history: [DailyPulseExternalSignal],
        limit: Int
    ) -> [DailyPulseExternalSignal] {
        var updated = history
        if let existingIndex = updated.firstIndex(where: {
            $0.source == signal.source
                && areTopicsSimilar($0.title, signal.title)
        }) {
            if signal.capturedAt >= updated[existingIndex].capturedAt {
                updated[existingIndex] = signal
            }
        } else {
            updated.insert(signal, at: 0)
        }

        return trimmedExternalSignals(updated, limit: limit)
    }

    internal nonisolated static func mergeTask(local: DailyPulseTask, incoming: DailyPulseTask) -> DailyPulseTask {
        let base = incoming.updatedAt >= local.updatedAt ? incoming : local
        let secondary = incoming.updatedAt >= local.updatedAt ? local : incoming

        var merged = base
        if merged.completedAt == nil {
            merged.completedAt = secondary.completedAt
        }
        if merged.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.details = secondary.details
        }
        if merged.suggestedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.suggestedPrompt = secondary.suggestedPrompt
        }
        return merged
    }

    internal nonisolated static func mergeExternalSignal(local: DailyPulseExternalSignal, incoming: DailyPulseExternalSignal) -> DailyPulseExternalSignal {
        incoming.capturedAt >= local.capturedAt ? incoming : local
    }

    internal nonisolated static func activeCurationText(
        for dayKey: String,
        pendingCuration: DailyPulseCurationNote?
    ) -> String {
        guard let pendingCuration,
              pendingCuration.targetDayKey == dayKey else {
            return ""
        }
        return pendingCuration.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func mergedFeedback(base: DailyPulseCardFeedback, incoming: DailyPulseCardFeedback) -> DailyPulseCardFeedback {
        let priority: [DailyPulseCardFeedback: Int] = [
            .none: 0,
            .liked: 1,
            .disliked: 2,
            .hidden: 3
        ]
        return (priority[incoming] ?? 0) > (priority[base] ?? 0) ? incoming : base
    }

#if os(iOS)
    func beginGenerationBackgroundTaskIfNeeded() {
        guard activeBackgroundTaskIdentifier == .invalid else { return }
        activeBackgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "dailyPulse.generate.background") { [weak self] in
            guard let self else { return }
            self.endGenerationBackgroundTaskIfNeeded()
        }
    }

    func endGenerationBackgroundTaskIfNeeded() {
        guard activeBackgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(activeBackgroundTaskIdentifier)
        activeBackgroundTaskIdentifier = .invalid
    }
#else
    func beginGenerationBackgroundTaskIfNeeded() {}
    func endGenerationBackgroundTaskIfNeeded() {}
#endif

    internal nonisolated static func normalizedText(_ text: String?, fallback: String) -> String {
        let trimmed = text?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    internal nonisolated static func normalizedMultilineText(_ text: String?, fallback: String) -> String {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    internal nonisolated static func normalizedOptionalText(_ text: String?, fallback: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return fallback
        }
        return trimmed
    }

    internal nonisolated static func resultPreviewText(_ text: String?, fallback: String) -> String {
        let normalized = normalizedText(text, fallback: fallback)
        return truncated(normalized, limit: 140)
    }

    internal nonisolated static func truncated(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    public nonisolated static func dayKey(for date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public nonisolated static func nextDayKey(from date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let nextDate = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return dayKey(for: nextDate, calendar: calendar)
    }

    nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    nonisolated static func userFacingDateString(from date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    nonisolated static func compactUserFacingDateString(from date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}

// ============================================================================
// DailyPulseManagerSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责每日脉冲管理器的静态状态变换、上下文拼装与文本辅助方法。
// ============================================================================

import Foundation

extension DailyPulseManager {
    internal nonisolated static func applyingFeedback(
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

    internal nonisolated static func markingCardSaved(
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

    internal nonisolated static func trimmedRuns(_ runs: [DailyPulseRun], limit: Int) -> [DailyPulseRun] {
        runs.sorted(by: { $0.generatedAt > $1.generatedAt }).prefix(max(1, limit)).map { $0 }
    }

    internal nonisolated static func visibleRuns(from runs: [DailyPulseRun], referenceDate: Date) -> [DailyPulseRun] {
        let todayKey = dayKey(for: referenceDate)
        return runs
            .filter { $0.dayKey == todayKey }
            .sorted(by: { $0.generatedAt > $1.generatedAt })
    }

    internal nonisolated static func hasUnviewedRun(todayRunDayKey: String?, lastViewedDayKey: String?) -> Bool {
        guard let todayRunDayKey, !todayRunDayKey.isEmpty else { return false }
        return todayRunDayKey != lastViewedDayKey
    }

    internal nonisolated static func isPreparingPulse(
        preparingDayKey: String?,
        todayRunDayKey: String?,
        referenceDate: Date
    ) -> Bool {
        let todayKey = dayKey(for: referenceDate)
        return preparingDayKey == todayKey && todayRunDayKey == nil
    }

    internal nonisolated static func removingFeedbackEvent(id: UUID, from history: [DailyPulseFeedbackEvent]) -> [DailyPulseFeedbackEvent] {
        history.filter { $0.id != id }
    }

    internal nonisolated static func removingExternalSignal(id: UUID, from signals: [DailyPulseExternalSignal]) -> [DailyPulseExternalSignal] {
        signals.filter { $0.id != id }
    }

    internal nonisolated static func sortedTasks(_ tasks: [DailyPulseTask]) -> [DailyPulseTask] {
        tasks
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted {
                    return !lhs.isCompleted && rhs.isCompleted
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(Self.taskRetentionLimit)
            .map { $0 }
    }

    internal nonisolated static func trimmedExternalSignals(_ signals: [DailyPulseExternalSignal], limit: Int) -> [DailyPulseExternalSignal] {
        signals
            .sorted(by: { $0.capturedAt > $1.capturedAt })
            .prefix(max(1, limit))
            .map { $0 }
    }

    internal nonisolated static func shouldProcessScheduledDelivery(
        reminderEnabled: Bool,
        reminderHour: Int,
        reminderMinute: Int,
        referenceDate: Date,
        lastDeliveryAttemptDayKey: String?
    ) -> Bool {
        guard reminderEnabled else { return false }
        let todayKey = dayKey(for: referenceDate)
        guard lastDeliveryAttemptDayKey != todayKey else { return false }
        return DailyPulseDeliveryCoordinator.hasReachedReminderTime(
            referenceDate: referenceDate,
            hour: reminderHour,
            minute: reminderMinute
        )
    }

    internal nonisolated static func shouldUseExistingRunForScheduledDelivery(
        todayRunDayKey: String?,
        referenceDate: Date
    ) -> Bool {
        todayRunDayKey == dayKey(for: referenceDate)
    }

    internal nonisolated static func mergeRun(local: DailyPulseRun, incoming: DailyPulseRun) -> DailyPulseRun {
        let base = incoming.generatedAt >= local.generatedAt ? incoming : local
        let secondary = incoming.generatedAt >= local.generatedAt ? local : incoming

        let mergedCards = base.cards.map { baseCard in
            guard let matchingSecondary = secondary.cards.first(where: {
                areTopicsSimilar($0.title, baseCard.title) ||
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

    internal nonisolated static func cleanedJSONObjectString(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            if let firstFenceIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") }),
               let lastFenceIndex = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") }),
               lastFenceIndex > firstFenceIndex {
                let cleaned = lines[(firstFenceIndex + 1)..<lastFenceIndex]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    internal nonisolated static func parseModelResponse(from raw: String) throws -> DailyPulseModelResponse {
        let cleaned = cleanedJSONObjectString(from: raw)
        let escaped = escapedControlCharactersInJSONString(cleaned)
        let data = Data(escaped.utf8)
        let decoder = JSONDecoder()
        return try decoder.decode(DailyPulseModelResponse.self, from: data)
    }

    internal nonisolated static func escapedControlCharactersInJSONString(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var isInsideString = false
        var isEscaping = false

        for character in text {
            if isEscaping {
                result.append(character)
                isEscaping = false
                continue
            }

            if character == "\\" {
                result.append(character)
                isEscaping = true
                continue
            }

            if character == "\"" {
                result.append(character)
                isInsideString.toggle()
                continue
            }

            if isInsideString {
                switch character {
                case "\n":
                    result.append("\\n")
                    continue
                case "\r":
                    result.append("\\r")
                    continue
                case "\t":
                    result.append("\\t")
                    continue
                default:
                    break
                }
            }

            result.append(character)
        }

        return result
    }

    internal nonisolated static func archivedChatContent(for card: DailyPulseCard) -> String {
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
        return ModelPromptLanguage.appendingOutputInstruction(to: NSLocalizedString("请继续展开这条每日脉冲，并结合我的现状给出更具体建议。", comment: "Default Daily Pulse continuation prompt sent to model"))
    }

    internal nonisolated static func resolveGenerationModel(
        dedicatedModelIdentifier: String,
        selectedModel: RunnableModel?,
        activatedModels: [RunnableModel]
    ) -> RunnableModel? {
        let chatCapableModels = activatedModels.filter { $0.model.isChatModel }

        if !dedicatedModelIdentifier.isEmpty,
           let dedicatedModel = chatCapableModels.first(where: { $0.id == dedicatedModelIdentifier }) {
            return dedicatedModel
        }

        if let selectedModel, selectedModel.model.isChatModel {
            return selectedModel
        }

        return chatCapableModels.first
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

    internal nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    internal nonisolated static func userFacingDateString(from date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    internal nonisolated static func compactUserFacingDateString(from date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private nonisolated static func mergedFeedback(base: DailyPulseCardFeedback, incoming: DailyPulseCardFeedback) -> DailyPulseCardFeedback {
        let priority: [DailyPulseCardFeedback: Int] = [
            .none: 0,
            .liked: 1,
            .disliked: 2,
            .hidden: 3
        ]
        return (priority[incoming] ?? 0) > (priority[base] ?? 0) ? incoming : base
    }
}

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#endif

extension DailyPulseManager {
    public var latestRun: DailyPulseRun? {
        runs.sorted(by: { $0.generatedAt > $1.generatedAt }).first
    }

    public var todayRun: DailyPulseRun? {
        runs.first(where: { $0.dayKey == Self.dayKey(for: Date()) })
    }

    public var archivedRuns: [DailyPulseRun] {
        []
    }

    public var primaryRun: DailyPulseRun? {
        todayRun ?? latestRun
    }

    internal func notificationTarget(
        runID: UUID?,
        cardID: UUID?,
        dayKey: String?
    ) -> (runID: UUID, card: DailyPulseCard)? {
        if let runID,
           let run = runs.first(where: { $0.id == runID }) {
            if let cardID,
               let card = run.cards.first(where: { $0.id == cardID }) {
                return (runID, card)
            }
            if let fallbackCard = run.visibleCards.first ?? run.cards.first {
                return (runID, fallbackCard)
            }
        }

        let candidateRuns: [DailyPulseRun]
        if let dayKey, !dayKey.isEmpty {
            candidateRuns = runs
                .filter { $0.dayKey == dayKey }
                .sorted(by: { $0.generatedAt > $1.generatedAt })
        } else if let primaryRun {
            candidateRuns = [primaryRun]
        } else {
            candidateRuns = runs.sorted(by: { $0.generatedAt > $1.generatedAt })
        }

        for run in candidateRuns {
            if let fallbackCard = run.visibleCards.first ?? run.cards.first {
                return (run.id, fallbackCard)
            }
        }
        return nil
    }

    public var hasUnviewedTodayRun: Bool {
        Self.hasUnviewedRun(todayRunDayKey: todayRun?.dayKey, lastViewedDayKey: lastViewedDayKey)
    }

    public var isPreparingTodayPulse: Bool {
        Self.isPreparingPulse(
            preparingDayKey: preparingDayKey,
            todayRunDayKey: todayRun?.dayKey,
            referenceDate: Date()
        )
    }

    public var feedbackHistoryPreview: [DailyPulseFeedbackEvent] {
        Array(feedbackHistory.prefix(5))
    }

    public var externalSignalPreview: [DailyPulseExternalSignal] {
        Array(externalSignals.prefix(5))
    }

    public var pendingTasks: [DailyPulseTask] {
        tasks.filter { !$0.isCompleted }
    }

    public var completedTasksPreview: [DailyPulseTask] {
        Array(tasks.filter(\.isCompleted).prefix(3))
    }

    public var nextCurationTargetDayKey: String {
        Self.nextDayKey(from: Date())
    }

    public func reloadPersistedRuns() {
        let persistedRuns = Persistence.loadDailyPulseRuns().sorted(by: { $0.generatedAt > $1.generatedAt })
        let visibleRuns = Self.visibleRuns(from: persistedRuns, referenceDate: Date())
        runs = visibleRuns
        feedbackHistory = Persistence.loadDailyPulseFeedbackHistory().sorted(by: { $0.createdAt > $1.createdAt })
        let latestPending = Persistence.loadDailyPulsePendingCuration()
        pendingCuration = latestPending
        tomorrowCurationText = latestPending?.text ?? ""
        externalSignals = Self.trimmedExternalSignals(
            Persistence.loadDailyPulseExternalSignals(),
            limit: Self.externalSignalRetentionLimit
        )
        tasks = Self.sortedTasks(Persistence.loadDailyPulseTasks())
        if visibleRuns.count != persistedRuns.count {
            Persistence.saveDailyPulseRuns(visibleRuns)
        }
    }

    public func clearError() {
        lastErrorMessage = nil
    }

    public func clearFeedbackHistory() {
        feedbackHistory = []
        Persistence.saveDailyPulseFeedbackHistory(feedbackHistory)
    }

    public func clearExternalSignals() {
        externalSignals = []
        Persistence.saveDailyPulseExternalSignals(externalSignals)
    }

    public func removeFeedbackHistoryEvent(id: UUID) {
        feedbackHistory = Self.removingFeedbackEvent(id: id, from: feedbackHistory)
        Persistence.saveDailyPulseFeedbackHistory(feedbackHistory)
    }

    public func removeExternalSignal(id: UUID) {
        externalSignals = Self.removingExternalSignal(id: id, from: externalSignals)
        Persistence.saveDailyPulseExternalSignals(externalSignals)
    }

    public func clearTomorrowCuration() {
        tomorrowCurationText = ""
    }

    public func clearCompletedTasks() {
        tasks.removeAll(where: \.isCompleted)
        persistTasks()
    }

    public func removeTask(id: UUID) {
        tasks = tasks.filter { $0.id != id }
        persistTasks()
    }

    public func markTodayRunViewed(referenceDate: Date = Date()) {
        let todayKey = Self.dayKey(for: referenceDate)
        guard todayRun?.dayKey == todayKey else { return }
        guard lastViewedDayKey != todayKey else { return }
        lastViewedDayKey = todayKey
        defaults.set(todayKey, forKey: Self.lastViewedDayKeyDefaultsKey)
    }

    internal func beginPreparation(referenceDate: Date = Date()) {
        let todayKey = Self.dayKey(for: referenceDate)
        preparingDayKey = todayKey
        lastPreparationStartedAt = referenceDate
    }

    internal func finishPreparation() {
        preparingDayKey = nil
    }

    public func generateForScheduledDeliveryIfNeeded(
        reminderEnabled: Bool,
        reminderHour: Int,
        reminderMinute: Int,
        referenceDate: Date = Date()
    ) async {
        let todayKey = Self.dayKey(for: referenceDate)
        guard Self.shouldProcessScheduledDelivery(
            reminderEnabled: reminderEnabled,
            reminderHour: reminderHour,
            reminderMinute: reminderMinute,
            referenceDate: referenceDate,
            lastDeliveryAttemptDayKey: lastDeliveryAttemptDayKey
        ) else {
            return
        }

        lastDeliveryAttemptDayKey = todayKey
        defaults.set(todayKey, forKey: Self.lastDeliveryAttemptDayKeyDefaultsKey)

        if Self.shouldUseExistingRunForScheduledDelivery(
            todayRunDayKey: todayRun?.dayKey,
            referenceDate: referenceDate
        ), let run = todayRun {
            await DailyPulseDeliveryCoordinator.shared.notifyReadyIfNeeded(for: run)
            return
        }

        await generate(force: false, trigger: .delivery, notifyReadyWhenFinished: true)
    }

    @discardableResult
    public func generateForBackgroundDeliveryIfNeeded(
        reminderEnabled: Bool,
        reminderHour: Int,
        reminderMinute: Int,
        referenceDate: Date = Date()
    ) async -> Bool {
        guard reminderEnabled else { return false }
        let todayKey = Self.dayKey(for: referenceDate)
        guard todayRun?.dayKey != todayKey else { return true }

        let shouldNotifyReady = DailyPulseDeliveryCoordinator.hasReachedReminderTime(
            referenceDate: referenceDate,
            hour: reminderHour,
            minute: reminderMinute
        )
        await generate(
            force: false,
            trigger: .delivery,
            notifyReadyWhenFinished: shouldNotifyReady
        )
        return todayRun?.dayKey == todayKey
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
        let run = runs.first(where: { $0.id == runID })
        let targetCard = run?.cards.first(where: { $0.id == cardID })
        runs = Self.applyingFeedback(feedback, to: cardID, runID: runID, in: runs)
        persistRuns()
        if let action = Self.historyAction(for: feedback),
           let run,
           let targetCard {
            appendFeedbackEvent(
                .init(
                    dayKey: run.dayKey,
                    topicHint: Self.topicText(for: targetCard),
                    cardTitle: targetCard.title,
                    action: action
                )
            )
        }
    }

    @discardableResult
    public func saveCardAsSession(cardID: UUID, runID: UUID) -> ChatSession? {
        guard let run = runs.first(where: { $0.id == runID }),
              let card = card(cardID: cardID, runID: runID) else { return nil }
        let hadSavedSession = card.savedSessionID != nil
        let content = Self.archivedChatContent(for: card)
        let session = chatService.createSavedSession(
            name: card.title,
            initialMessages: [ChatMessage(role: .assistant, content: content)]
        )
        runs = Self.markingCardSaved(sessionID: session.id, cardID: cardID, runID: runID, in: runs)
        persistRuns()
        if !hadSavedSession {
            appendFeedbackEvent(
                .init(
                    dayKey: run.dayKey,
                    topicHint: Self.topicText(for: card),
                    cardTitle: card.title,
                    action: .saved
                )
            )
        }
        return session
    }

    public func linkedTask(cardID: UUID, runID: UUID) -> DailyPulseTask? {
        guard let run = runs.first(where: { $0.id == runID }) else { return nil }
        return tasks.first(where: { $0.sourceCardID == cardID && $0.sourceDayKey == run.dayKey })
    }

    @discardableResult
    public func addTaskFromCard(cardID: UUID, runID: UUID) -> DailyPulseTask? {
        guard let run = runs.first(where: { $0.id == runID }),
              let card = card(cardID: cardID, runID: runID) else { return nil }

        if let existing = tasks.first(where: { $0.sourceCardID == cardID && $0.sourceDayKey == run.dayKey }) {
            return existing
        }

        let now = Date()
        let task = DailyPulseTask(
            sourceDayKey: run.dayKey,
            sourceCardID: card.id,
            title: card.title,
            details: card.summary,
            suggestedPrompt: card.suggestedPrompt,
            createdAt: now,
            updatedAt: now
        )
        tasks = Self.sortedTasks([task] + tasks)
        persistTasks()
        return task
    }

    public func toggleTaskCompletion(id: UUID) {
        let now = Date()
        tasks = tasks.map { task in
            guard task.id == id else { return task }
            var updated = task
            updated.completedAt = task.isCompleted ? nil : now
            updated.updatedAt = now
            return updated
        }
        tasks = Self.sortedTasks(tasks)
        persistTasks()
    }

    public func appendExternalSignal(_ signal: DailyPulseExternalSignal) {
        externalSignals = Self.appendingExternalSignal(
            signal,
            to: externalSignals,
            limit: Self.externalSignalRetentionLimit
        )
        Persistence.saveDailyPulseExternalSignals(externalSignals)
    }

    public func ingestAnnouncements(_ announcements: [Announcement]) {
        let nextHistory = Self.syncingAnnouncementSignals(
            announcements,
            in: externalSignals,
            limit: Self.externalSignalRetentionLimit
        )
        guard nextHistory != externalSignals else { return }
        externalSignals = nextHistory
        Persistence.saveDailyPulseExternalSignals(externalSignals)
    }

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

    func resolveGenerationModel() -> RunnableModel? {
        let dedicatedModelIdentifier = defaults.string(forKey: Self.dedicatedModelDefaultsKey) ?? ""
        return Self.resolveGenerationModel(
            dedicatedModelIdentifier: dedicatedModelIdentifier,
            selectedModel: chatService.selectedModelSubject.value,
            activatedModels: chatService.activatedRunnableModels
        )
    }

}

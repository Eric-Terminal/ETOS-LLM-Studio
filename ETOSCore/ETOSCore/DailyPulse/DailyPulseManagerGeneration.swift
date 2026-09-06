// ============================================================================
// DailyPulseManagerGeneration.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责每日脉冲管理器的生成流程、上下文采集、持久化回写与后台任务。
// ============================================================================

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#endif

extension DailyPulseManager {
    func resolveGenerationModel() async -> RunnableModel? {
        let dedicatedModelIdentifier = await Task.detached(priority: .utility) {
            Persistence.readAppConfigText(key: AppConfigKey.dailyPulseModelIdentifier.rawValue) ?? ""
        }.value
        return Self.resolveGenerationModel(
            dedicatedModelIdentifier: dedicatedModelIdentifier,
            selectedModel: chatService.selectedModelSubject.value,
            activatedModels: chatService.activatedRunnableModels
        )
    }

    func generate(
        force: Bool,
        trigger: DailyPulseTrigger,
        targetDayKey: String? = nil,
        notifyReadyWhenFinished: Bool = false
    ) async {
        await waitForPersistedStateLoad()
        if isGenerating { return }
        guard Self.shouldStartGeneration(
            isDailyPulseEnabled: isDailyPulseEnabled,
            force: force,
            trigger: trigger,
            autoGenerateEnabled: autoGenerateEnabled
        ) else { return }
        let now = Date()
        let generationDayKey = targetDayKey ?? Self.dayKey(for: now)
        guard shouldGenerateOnCurrentDevice(trigger: trigger) else {
            logger.info("每日脉冲由当前可达的 iPhone 负责生成，手表本次跳过。")
            return
        }
        let previousAttempt = generationRuntimeState.attempts.first(where: { $0.dayKey == generationDayKey })
        guard Self.shouldAttemptGeneration(
            trigger: trigger,
            attempt: previousAttempt,
            referenceDate: now
        ) else {
            logger.info("每日脉冲仍在失败冷却时间内，目标日期: \(generationDayKey, privacy: .public)")
            return
        }
        prunePendingCurationIfNeeded(referenceDate: now)

        beginGenerationBackgroundTaskIfNeeded()
        beginPreparation(dayKey: generationDayKey, referenceDate: now)
        isGenerating = true
        lastErrorMessage = nil
        defer {
            isGenerating = false
            finishPreparation()
            endGenerationBackgroundTaskIfNeeded()
        }

        do {
            let deliveryTimes = DailyPulseDeliveryCoordinator.shared.deliveryTimes
            let requestedCardCount = deliveryTimes.count
            let input = await buildGenerationInput(
                for: generationDayKey,
                sessionLimit: requestedCardCount
            )
            guard input.hasUsableContext else {
                throw DailyPulseGenerationError.insufficientContext
            }
            guard let generationModel = await resolveGenerationModel() else {
                throw DailyPulseGenerationError.noModelSelected
            }

            let scheduledDeliveries = DailyPulseDeliveryCoordinator
                .groupedCardDeliveryTimes(deliveryTimes)
                .compactMap { deliveryGroup -> (deliveryTimes: [DailyPulseDeliveryTime], scheduledAt: Date)? in
                    guard let firstDeliveryTime = deliveryGroup.first,
                          let scheduledAt = DailyPulseDeliveryCoordinator.deliveryDate(
                              dayKey: generationDayKey,
                              time: firstDeliveryTime
                          ) else {
                        return nil
                    }
                    return (deliveryGroup, scheduledAt)
                }
            guard !scheduledDeliveries.isEmpty else {
                throw DailyPulseGenerationError.invalidModelOutput
            }
            let sessionGroups = Self.partitionedSessionExcerpts(
                input.sessionExcerpts,
                cardCounts: scheduledDeliveries.map { $0.deliveryTimes.count },
                scheduledDeliveryDates: scheduledDeliveries.map(\.scheduledAt)
            )
            let scheduleSignature = Self.generationScheduleSignature(
                deliveryTimes: deliveryTimes,
                modelIdentifier: generationModel.id
            )
            var checkpoint = Self.resumableCheckpoint(
                from: generationRuntimeState.checkpoints,
                dayKey: generationDayKey,
                scheduleSignature: scheduleSignature
            ) ?? DailyPulseGenerationCheckpoint(
                dayKey: generationDayKey,
                scheduleSignature: scheduleSignature,
                sourceDigest: input.sourceDigest
            )
            replaceGenerationCheckpoint(checkpoint)

            for (index, scheduledDelivery) in scheduledDeliveries.enumerated() {
                let deliveryGroup = scheduledDelivery.deliveryTimes
                let scheduledAt = scheduledDelivery.scheduledAt
                let cardsAtTime = deliveryGroup.count
                if checkpoint.hasCompletedDeliveryGroup(deliveryGroup) {
                    continue
                }
                let deliveryTimeIDs = Set(deliveryGroup.map(\.id))
                let incompleteCardIDs = Set(
                    checkpoint.deliveryBatches
                        .filter { deliveryTimeIDs.contains($0.deliveryTimeID) }
                        .flatMap(\.cardIDs)
                )
                checkpoint.deliveryBatches.removeAll {
                    deliveryTimeIDs.contains($0.deliveryTimeID)
                }
                checkpoint.generatedCards.removeAll { incompleteCardIDs.contains($0.id) }
                let existingCards = checkpoint.generatedCards

                let userPrompt = Self.makeUserPrompt(
                    from: input,
                    sessionExcerpts: sessionGroups.indices.contains(index) ? sessionGroups[index] : [],
                    cardsPerDelivery: cardsAtTime,
                    candidateCardsPerDelivery: cardsAtTime * 2,
                    scheduledDeliveryDate: scheduledAt,
                    excludedTopics: existingCards.map(\.title)
                )
                let raw = try await chatService.generateDetachedChatCompletion(
                    systemPrompt: Self.systemPrompt,
                    userPrompt: userPrompt,
                    temperature: 0.45,
                    runnableModel: generationModel,
                    requestSource: .dailyPulse,
                    responseValidator: { rawResponse in
                        let parsed = try Self.parseModelResponse(from: rawResponse)
                        let cards = Self.makeCards(
                            from: parsed.cards,
                            fallbackFocus: input.focusText,
                            profile: input.preferenceProfile,
                            limit: cardsAtTime,
                            excluding: existingCards
                        )
                        guard cards.count == cardsAtTime else {
                            throw DailyPulseGenerationError.invalidModelOutput
                        }
                    }
                )
                let parsed = try Self.parseModelResponse(from: raw)
                let cards = Self.makeCards(
                    from: parsed.cards,
                    fallbackFocus: input.focusText,
                    profile: input.preferenceProfile,
                    limit: cardsAtTime,
                    excluding: existingCards
                )
                guard cards.count == cardsAtTime else {
                    throw DailyPulseGenerationError.invalidModelOutput
                }

                let headline = Self.normalizedText(
                    parsed.headline,
                    fallback: NSLocalizedString("这次有几条值得你看", comment: "Daily Pulse delivery batch fallback headline")
                )
                checkpoint.firstHeadline = checkpoint.firstHeadline ?? headline
                checkpoint.generatedCards.append(contentsOf: cards)
                checkpoint.deliveryBatches.append(contentsOf: zip(deliveryGroup, cards).map { pair in
                    DailyPulseDeliveryBatch(
                        deliveryTimeID: pair.0.id,
                        scheduledAt: scheduledAt,
                        headline: headline,
                        cardIDs: [pair.1.id]
                    )
                })
                checkpoint.updatedAt = Date()
                replaceGenerationCheckpoint(checkpoint)
                await persistGenerationRuntimeState()
            }
            guard checkpoint.generatedCards.count == deliveryTimes.count,
                  checkpoint.deliveryBatches.count == deliveryTimes.count,
                  scheduledDeliveries.allSatisfy({
                      checkpoint.hasCompletedDeliveryGroup($0.deliveryTimes)
                  }) else {
                throw DailyPulseGenerationError.invalidModelOutput
            }

            let newRun = DailyPulseRun(
                dayKey: generationDayKey,
                generatedAt: Date(),
                headline: checkpoint.firstHeadline ?? NSLocalizedString("今天这几条值得你看", comment: "Daily Pulse fallback headline"),
                cards: checkpoint.generatedCards,
                sourceDigest: checkpoint.sourceDigest,
                deliveryBatches: checkpoint.deliveryBatches
            )
            upsertRun(newRun)
            clearGenerationRuntimeState(for: generationDayKey)
            await persistGenerationRuntimeState()
            if pendingCuration?.targetDayKey == generationDayKey {
                pendingCuration = nil
                if !tomorrowCurationText.isEmpty {
                    tomorrowCurationText = ""
                } else {
                    Persistence.saveDailyPulsePendingCuration(nil)
                }
            }
            await DailyPulseDeliveryCoordinator.shared.refreshReminderSchedule()
            if notifyReadyWhenFinished {
                await DailyPulseDeliveryCoordinator.shared.notifyReadyIfNeeded(for: newRun)
            }
            logger.info("每日脉冲已生成，触发方式: \(trigger.rawValue, privacy: .public)，卡片数: \(checkpoint.generatedCards.count)")
        } catch {
            if Self.isCancellationError(error) || Task.isCancelled {
                logger.info("每日脉冲生成已取消，触发方式: \(trigger.rawValue, privacy: .public)")
                return
            }

            recordGenerationFailure(dayKey: generationDayKey, referenceDate: Date())
            await persistGenerationRuntimeState()
            let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if trigger == .manual {
                lastErrorMessage = description
            }
            logger.error("每日脉冲生成失败: \(description, privacy: .public)")
        }
    }

    nonisolated static func shouldStartGeneration(
        isDailyPulseEnabled: Bool,
        force: Bool,
        trigger: DailyPulseTrigger,
        autoGenerateEnabled: Bool
    ) -> Bool {
        guard isDailyPulseEnabled else { return false }
        return force || autoGenerateEnabled || trigger == .manual || trigger == .delivery
    }

    func upsertRun(_ run: DailyPulseRun) {
        var updatedRuns = runs.filter { $0.dayKey != run.dayKey }
        updatedRuns.insert(run, at: 0)
        runs = Self.retainedRuns(
            from: Self.trimmedRuns(updatedRuns, limit: retentionLimit),
            referenceDate: Date()
        )
        persistRuns()
    }

    func persistRuns() {
        Persistence.saveDailyPulseRuns(runs)
    }

    func replaceGenerationCheckpoint(_ checkpoint: DailyPulseGenerationCheckpoint) {
        generationRuntimeState.checkpoints.removeAll(where: { $0.dayKey == checkpoint.dayKey })
        generationRuntimeState.checkpoints.append(checkpoint)
    }

    func clearGenerationRuntimeState(for dayKey: String) {
        generationRuntimeState.checkpoints.removeAll(where: { $0.dayKey == dayKey })
        generationRuntimeState.attempts.removeAll(where: { $0.dayKey == dayKey })
    }

    func recordGenerationFailure(dayKey: String, referenceDate: Date) {
        let previousAttempt = generationRuntimeState.attempts.first(where: { $0.dayKey == dayKey })
        let attempt = Self.failedGenerationAttempt(
            dayKey: dayKey,
            previousAttempt: previousAttempt,
            referenceDate: referenceDate
        )
        generationRuntimeState.attempts.removeAll(where: { $0.dayKey == dayKey })
        generationRuntimeState.attempts.append(attempt)
    }

    func persistGenerationRuntimeState() async {
        let snapshot = generationRuntimeState
        let previousTask = generationRuntimePersistenceTask
        let persistenceTask = Task.detached(priority: .utility) {
            await previousTask?.value
            Persistence.saveDailyPulseGenerationRuntimeState(snapshot)
        }
        generationRuntimePersistenceTask = persistenceTask
        await persistenceTask.value
    }

    func persistGenerationRuntimeStateInBackground() {
        let snapshot = generationRuntimeState
        let previousTask = generationRuntimePersistenceTask
        generationRuntimePersistenceTask = Task.detached(priority: .utility) {
            await previousTask?.value
            Persistence.saveDailyPulseGenerationRuntimeState(snapshot)
        }
    }

    private func shouldGenerateOnCurrentDevice(trigger: DailyPulseTrigger) -> Bool {
#if os(watchOS) && canImport(WatchConnectivity)
        return Self.shouldGenerateOnCurrentDevice(
            trigger: trigger,
            isWatchOS: true,
            syncEnabled: isWatchConnectivitySyncEnabled(),
            companionReachable: WatchSyncManager.shared.isCompanionReachable
        )
#else
        return true
#endif
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
            let shouldInvalidatePreparedRun = pendingCuration != nil
                && (runs.contains(where: { $0.dayKey == Self.nextDayKey(from: referenceDate) })
                    || generationRuntimeState.checkpoints.contains(where: {
                        $0.dayKey == Self.nextDayKey(from: referenceDate)
                    }))
            pendingCuration = nil
            Persistence.saveDailyPulsePendingCuration(nil)
            if shouldInvalidatePreparedRun {
                invalidatePreparedTomorrowRun(referenceDate: referenceDate)
            }
            return
        }

        let targetDayKey = Self.nextDayKey(from: referenceDate)
        let shouldInvalidatePreparedRun = pendingCuration?.text != trimmed
            && (runs.contains(where: { $0.dayKey == targetDayKey })
                || generationRuntimeState.checkpoints.contains(where: { $0.dayKey == targetDayKey }))
        let note = DailyPulseCurationNote(
            id: pendingCuration?.id ?? UUID(),
            targetDayKey: targetDayKey,
            text: trimmed,
            createdAt: pendingCuration?.createdAt ?? Date()
        )
        pendingCuration = note
        Persistence.saveDailyPulsePendingCuration(note)
        if shouldInvalidatePreparedRun {
            invalidatePreparedTomorrowRun(referenceDate: referenceDate)
        }
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

    public func card(cardID: UUID, runID: UUID) -> DailyPulseCard? {
        runs.first(where: { $0.id == runID })?.cards.first(where: { $0.id == cardID })
    }

    private func buildGenerationInput(
        for targetDayKey: String,
        sessionLimit: Int
    ) async -> DailyPulseGenerationInput {
        await memoryManager.waitForInitialization()
        prunePendingCurationIfNeeded(referenceDate: Date())
        let sessionExcerpts = await buildSessionExcerpts(limit: sessionLimit)
        let memories = buildMemoryExcerpts()
        let requestLogSummary = buildRequestLogSummary()
        let activeTasks = pendingTasks
        let preferenceProfile = Self.makePreferenceProfile(history: feedbackHistory, recentRuns: runs)
        let externalContext = buildExternalContext()
        let globalSystemPrompt = GlobalSystemPromptStore.load().activeSystemPrompt
        return DailyPulseGenerationInput(
            focusText: focusText.trimmingCharacters(in: .whitespacesAndNewlines),
            curationText: Self.activeCurationText(for: targetDayKey, pendingCuration: pendingCuration),
            globalSystemPrompt: globalSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionExcerpts: sessionExcerpts,
            memories: memories,
            requestLogSummary: requestLogSummary,
            activeTasks: activeTasks,
            preferenceProfile: preferenceProfile,
            externalContext: externalContext
        )
    }

    private func buildExternalContext() -> DailyPulseExternalContext {
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

    private func buildSessionExcerpts(limit: Int) async -> [DailyPulseSessionExcerpt] {
        var orderedSessions = chatService.chatSessionsSubject.value
        if let current = chatService.currentSessionSubject.value,
           !orderedSessions.contains(where: { $0.id == current.id }) {
            orderedSessions.insert(current, at: 0)
        }
        let sessions = orderedSessions
        let excerptLimit = max(1, limit)
        let messageLimit = maxMessagesPerSession
        let userRole = NSLocalizedString("用户", comment: "Daily Pulse prompt user role label")
        let assistantRole = NSLocalizedString("助手", comment: "Daily Pulse prompt assistant role label")
        let untitledName = NSLocalizedString("未命名会话", comment: "Untitled session fallback")

        return await Task.detached(priority: .utility) {
            let loaded = sessions.enumerated().compactMap { offset, session -> (Int, DailyPulseSessionExcerpt)? in
                let messages = Persistence.loadMessages(for: session.id)
                    .filter { $0.role == .user || $0.role == .assistant }
                guard !messages.isEmpty else { return nil }

                let latestActivityAt = messages.compactMap(Self.messageActivityDate).max()
                let lines = messages.suffix(messageLimit).compactMap { message -> String? in
                    let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    let prefix = message.role == .user ? userRole : assistantRole
                    let content = String(
                        format: NSLocalizedString("%@：%@", comment: "Daily Pulse prompt role line"),
                        prefix,
                        Self.truncated(trimmed, limit: 180)
                    )
                    guard let activityAt = Self.messageActivityDate(message) else { return content }
                    return "[\(Self.promptTimestampString(from: activityAt))] \(content)"
                }
                guard !lines.isEmpty else { return nil }

                let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return (
                    offset,
                    DailyPulseSessionExcerpt(
                        name: name.isEmpty ? untitledName : name,
                        lines: Array(lines),
                        lastActivityAt: latestActivityAt
                    )
                )
            }

            return loaded
                .sorted { lhs, rhs in
                    switch (lhs.1.lastActivityAt, rhs.1.lastActivityAt) {
                    case let (left?, right?):
                        return left == right ? lhs.0 < rhs.0 : left > right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        return lhs.0 < rhs.0
                    }
                }
                .prefix(excerptLimit)
                .map { $0.1 }
        }.value
    }

    private func buildMemoryExcerpts() -> [String] {
        let now = Date()
        return memoryManager.currentMemoriesSnapshot()
            .filter { $0.isValid(at: now) }
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
            String(format: NSLocalizedString("最近 7 天请求数：%d", comment: "Daily Pulse request count summary"), summary.totalRequests),
            providerSummary.isEmpty ? "" : String(format: NSLocalizedString("常用提供商：%@", comment: "Daily Pulse top provider summary"), providerSummary),
            modelSummary.isEmpty ? "" : String(format: NSLocalizedString("常用模型：%@", comment: "Daily Pulse top model summary"), modelSummary)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

#if os(iOS)
    private func beginGenerationBackgroundTaskIfNeeded() {
        guard activeBackgroundTaskIdentifier == .invalid else { return }
        activeBackgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "dailyPulse.generate.background") { [weak self] in
            guard let self else { return }
            self.endGenerationBackgroundTaskIfNeeded()
        }
    }

    private func endGenerationBackgroundTaskIfNeeded() {
        guard activeBackgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(activeBackgroundTaskIdentifier)
        activeBackgroundTaskIdentifier = .invalid
    }
#else
    private func beginGenerationBackgroundTaskIfNeeded() {}
    private func endGenerationBackgroundTaskIfNeeded() {}
#endif
}

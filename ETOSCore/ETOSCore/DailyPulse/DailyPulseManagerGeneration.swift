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
    func resolveGenerationModel() -> RunnableModel? {
        let dedicatedModelIdentifier = Persistence.readAppConfigText(key: AppConfigKey.dailyPulseModelIdentifier.rawValue) ?? ""
        return Self.resolveGenerationModel(
            dedicatedModelIdentifier: dedicatedModelIdentifier,
            selectedModel: chatService.selectedModelSubject.value,
            activatedModels: chatService.activatedRunnableModels
        )
    }

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
                headline: Self.normalizedText(parsed.headline, fallback: NSLocalizedString("今天这几条值得你看", comment: "Daily Pulse fallback headline")),
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

    private func buildGenerationInput() async -> DailyPulseGenerationInput {
        await memoryManager.waitForInitialization()
        prunePendingCurationIfNeeded(referenceDate: Date())
        let sessionExcerpts = buildSessionExcerpts()
        let memories = buildMemoryExcerpts()
        let requestLogSummary = buildRequestLogSummary()
        let todayKey = Self.dayKey(for: Date())
        let activeTasks = pendingTasks
        let preferenceProfile = Self.makePreferenceProfile(history: feedbackHistory, recentRuns: runs)
        let externalContext = buildExternalContext()
        let globalSystemPrompt = GlobalSystemPromptStore.load().activeSystemPrompt
        return DailyPulseGenerationInput(
            focusText: focusText.trimmingCharacters(in: .whitespacesAndNewlines),
            curationText: Self.activeCurationText(for: todayKey, pendingCuration: pendingCuration),
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
                let prefix = message.role == .user
                    ? NSLocalizedString("用户", comment: "Daily Pulse prompt user role label")
                    : NSLocalizedString("助手", comment: "Daily Pulse prompt assistant role label")
                return String(
                    format: NSLocalizedString("%@：%@", comment: "Daily Pulse prompt role line"),
                    prefix,
                    Self.truncated(trimmed, limit: 180)
                )
            }
            guard !lines.isEmpty else { continue }

            let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(
                DailyPulseSessionExcerpt(
                    name: name.isEmpty ? NSLocalizedString("未命名会话", comment: "Untitled session fallback") : name,
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

// ============================================================================
// SyncEngineArtifacts.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载同步包中的反馈、每日脉冲与 AppStorage 合并逻辑。
// ============================================================================

import Foundation

extension SyncEngine {
    // MARK: - Feedback Tickets

    static func mergeFeedbackTickets(_ incoming: [FeedbackTicket]) -> (imported: Int, skipped: Int) {
        FeedbackStore.mergeTickets(incoming)
    }

    // MARK: - Daily Pulse

    static func mergeDailyPulseArtifacts(
        runs incomingRuns: [DailyPulseRun],
        feedbackHistory incomingHistory: [DailyPulseFeedbackEvent],
        pendingCuration incomingCuration: DailyPulseCurationNote?,
        externalSignals incomingSignals: [DailyPulseExternalSignal],
        tasks incomingTasks: [DailyPulseTask]
    ) -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0

        var localRuns = Persistence.loadDailyPulseRuns()
        if incomingRuns.isEmpty {
            if localRuns.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseRuns([])
                imported += 1
            }
        } else {
            for run in incomingRuns.sorted(by: { $0.generatedAt < $1.generatedAt }) {
                if let existingIndex = localRuns.firstIndex(where: { $0.dayKey == run.dayKey }) {
                    let merged = DailyPulseManager.mergeRun(local: localRuns[existingIndex], incoming: run)
                    if merged == localRuns[existingIndex] {
                        skipped += 1
                        continue
                    }
                    localRuns[existingIndex] = merged
                    imported += 1
                    continue
                }

                localRuns.append(run)
                imported += 1
            }
            let trimmedRuns = DailyPulseManager.trimmedRuns(
                localRuns,
                limit: DailyPulseManager.persistedRetentionLimit
            )
            Persistence.saveDailyPulseRuns(trimmedRuns)
        }

        if incomingHistory.isEmpty {
            let localHistory = Persistence.loadDailyPulseFeedbackHistory()
            if localHistory.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseFeedbackHistory([])
                imported += 1
            }
        } else {
            var localHistory = Persistence.loadDailyPulseFeedbackHistory()
            let original = localHistory
            for event in incomingHistory.sorted(by: { $0.createdAt < $1.createdAt }) {
                localHistory = DailyPulseManager.appendingFeedbackEvent(
                    event,
                    to: localHistory,
                    limit: DailyPulseManager.feedbackHistoryRetentionLimit
                )
            }
            Persistence.saveDailyPulseFeedbackHistory(localHistory)
            if localHistory == original {
                skipped += incomingHistory.count
            } else {
                imported += max(1, localHistory.count - original.count)
            }
        }

        let localCuration = Persistence.loadDailyPulsePendingCuration()
        if localCuration != nil || incomingCuration != nil {
            if localCuration == incomingCuration {
                skipped += 1
            } else if let incomingCuration {
                let shouldReplace = localCuration == nil
                    || incomingCuration.createdAt >= (localCuration?.createdAt ?? .distantPast)
                if shouldReplace {
                    Persistence.saveDailyPulsePendingCuration(incomingCuration)
                    imported += 1
                } else {
                    skipped += 1
                }
            } else {
                Persistence.saveDailyPulsePendingCuration(nil)
                imported += 1
            }
        }

        if incomingSignals.isEmpty {
            let localSignals = Persistence.loadDailyPulseExternalSignals()
            if localSignals.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseExternalSignals([])
                imported += 1
            }
        } else {
            var localSignals = Persistence.loadDailyPulseExternalSignals()
            let original = localSignals
            for signal in incomingSignals.sorted(by: { $0.capturedAt < $1.capturedAt }) {
                localSignals = DailyPulseManager.appendingExternalSignal(
                    signal,
                    to: localSignals,
                    limit: DailyPulseManager.externalSignalRetentionLimit
                )
            }
            Persistence.saveDailyPulseExternalSignals(localSignals)
            if localSignals == original {
                skipped += incomingSignals.count
            } else {
                imported += max(1, localSignals.count - original.count)
            }
        }

        if incomingTasks.isEmpty {
            let localTasks = Persistence.loadDailyPulseTasks()
            if localTasks.isEmpty {
                skipped += 1
            } else {
                Persistence.saveDailyPulseTasks([])
                imported += 1
            }
        } else {
            var localTasks = Persistence.loadDailyPulseTasks()
            let original = localTasks
            for task in incomingTasks {
                if let existingIndex = localTasks.firstIndex(where: { existing in
                    if existing.id == task.id {
                        return true
                    }
                    if let localCardID = existing.sourceCardID, let incomingCardID = task.sourceCardID {
                        return localCardID == incomingCardID && existing.sourceDayKey == task.sourceDayKey
                    }
                    return false
                }) {
                    let merged = DailyPulseManager.mergeTask(local: localTasks[existingIndex], incoming: task)
                    if merged == localTasks[existingIndex] {
                        skipped += 1
                    } else {
                        localTasks[existingIndex] = merged
                        imported += 1
                    }
                } else {
                    localTasks.append(task)
                    imported += 1
                }
            }
            let sortedTasks = DailyPulseManager.sortedTasks(localTasks)
            Persistence.saveDailyPulseTasks(sortedTasks)
            if sortedTasks == original {
                skipped += incomingTasks.count
            }
        }

        return (imported, skipped)
    }

    // MARK: - AppStorage

    static func mergeAppStorage(
        _ snapshotData: Data?,
        legacyGlobalSystemPrompt: String?,
        userDefaults: UserDefaults
    ) async -> (imported: Int, skipped: Int) {
        var incomingSnapshot: [String: Any] = [:]

        if let snapshotData, let decoded = decodeAppStorageSnapshot(snapshotData) {
            incomingSnapshot = decoded
        } else if let legacyGlobalSystemPrompt {
            incomingSnapshot[legacyGlobalSystemPromptKey] = legacyGlobalSystemPrompt
        } else {
            return (0, 1)
        }

        guard !incomingSnapshot.isEmpty else {
            return (0, 0)
        }

        let normalized = normalizedAppConfigSnapshot(
            incomingSnapshot,
            legacyGlobalSystemPrompt: legacyGlobalSystemPrompt
        )
        let currentSnapshot = collectAppStorageSnapshot(userDefaults: userDefaults)
        var imported = 0
        var skipped = normalized.skipped
        var acceptedSnapshot: [String: Any] = [:]

        for (key, incomingValue) in normalized.snapshot {
            let localValue = currentSnapshot[key]
            if appStorageValuesEqual(localValue, incomingValue) {
                skipped += 1
                continue
            }

            acceptedSnapshot[key] = incomingValue
            imported += 1
        }

        if !acceptedSnapshot.isEmpty {
            await AppConfigStore.shared.apply(snapshot: acceptedSnapshot)
            await reloadAppConfigBackedManagersIfNeeded(changedKeys: Set(acceptedSnapshot.keys))
        }
        if let prompt = normalized.snapshot[AppConfigKey.systemPrompt.rawValue] as? String {
            GlobalSystemPromptStore.saveActiveSystemPrompt(prompt)
        }

        return (imported, skipped)
    }

    @MainActor
    private static func reloadAppConfigBackedManagersIfNeeded(changedKeys: Set<String>) {
        if changedKeys.contains(AppConfigKey.appToolsChatToolsEnabled.rawValue)
            || changedKeys.contains(AppConfigKey.appToolsEnabledToolIDs.rawValue)
            || changedKeys.contains(AppConfigKey.appToolsToolApprovalPolicies.rawValue) {
            AppToolManager.shared.reloadAppConfigBackedState()
        }
        if changedKeys.contains(AppConfigKey.mcpChatToolsEnabled.rawValue) {
            MCPManager.shared.reloadAppConfigBackedState()
        }
        if changedKeys.contains(AppConfigKey.shortcutChatToolsEnabled.rawValue) {
            ShortcutToolManager.shared.reloadAppConfigBackedState()
        }
        if changedKeys.contains(AppConfigKey.modelOrderRunnableModels.rawValue)
            || changedKeys.contains(AppConfigKey.providerOrderIDs.rawValue)
            || changedKeys.contains(AppConfigKey.selectedRunnableModelID.rawValue) {
            ChatService.shared.reloadAppConfigBackedModelState()
        }
        if changedKeys.contains(AppConfigKey.messageRegexRules.rawValue) {
            MessageRegexRuleStore.shared.reload(notify: true)
        }
    }

    static func encodeAppStorageSnapshot(_ snapshot: [String: Any]) -> Data? {
        guard PropertyListSerialization.propertyList(snapshot, isValidFor: .binary) else {
            return nil
        }
        return try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0)
    }

    static func decodeAppStorageSnapshot(_ data: Data) -> [String: Any]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func collectAppStorageSnapshot(userDefaults _: UserDefaults) -> [String: Any] {
        AppConfigStore.persistentSnapshot()
            .filter { isCandidateAppStorageKey($0.key) && isPropertyListEncodableValue($0.value) }
    }

    static func normalizedAppConfigSnapshot(
        _ snapshot: [String: Any],
        legacyGlobalSystemPrompt: String?
    ) -> (snapshot: [String: Any], skipped: Int) {
        var remainingSnapshot = snapshot
        let legacyPromptResult = extractLegacyGlobalSystemPrompt(
            from: &remainingSnapshot,
            fallback: legacyGlobalSystemPrompt
        )
        if let prompt = legacyPromptResult.prompt,
           remainingSnapshot[AppConfigKey.systemPrompt.rawValue] == nil {
            remainingSnapshot[AppConfigKey.systemPrompt.rawValue] = prompt
        }

        var normalizedSnapshot: [String: Any] = [:]
        var skipped = legacyPromptResult.skipped
        for (rawKey, value) in remainingSnapshot {
            guard isCandidateAppStorageKey(rawKey),
                  let key = AppConfigKey(rawValue: rawKey),
                  key.participatesInSync,
                  let normalizedValue = normalizedAppConfigValue(value, for: key),
                  isPropertyListEncodableValue(normalizedValue) else {
                skipped += 1
                continue
            }
            normalizedSnapshot[rawKey] = normalizedValue
        }
        return (normalizedSnapshot, skipped)
    }

    static func extractLegacyGlobalSystemPrompt(
        from snapshot: inout [String: Any],
        fallback: String?
    ) -> (prompt: String?, skipped: Int) {
        let entriesData = snapshot.removeValue(forKey: GlobalSystemPromptStore.entriesStorageKey) as? Data
        let selectedRawID = snapshot.removeValue(forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey) as? String
        var skipped = 0
        if entriesData != nil {
            skipped += 1
        }
        if selectedRawID != nil {
            skipped += 1
        }

        if let entriesData,
           let entries = try? JSONDecoder().decode([GlobalSystemPromptEntry].self, from: entriesData) {
            let selectedID = selectedRawID.flatMap(UUID.init(uuidString:))
            let selectedEntry = selectedID.flatMap { id in entries.first { $0.id == id } } ?? entries.first
            if let selectedEntry {
                return (selectedEntry.content, skipped)
            }
        }

        return (snapshot[legacyGlobalSystemPromptKey] as? String ?? fallback, skipped)
    }

    static func normalizedAppConfigValue(_ value: Any, for key: AppConfigKey) -> Any? {
        switch key.defaultValue {
        case .bool:
            if let value = value as? Bool {
                return value
            }
            if let value = value as? NSNumber {
                return value.boolValue
            }
            if let value = value as? String {
                switch value.lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    return nil
                }
            }
            return nil
        case .integer:
            if let value = value as? Int {
                return value
            }
            if let value = value as? NSNumber {
                return value.intValue
            }
            if let value = value as? String {
                return Int(value)
            }
            return nil
        case .real:
            if let value = value as? Double {
                return value
            }
            if let value = value as? NSNumber {
                return value.doubleValue
            }
            if let value = value as? String {
                return Double(value)
            }
            return nil
        case .text:
            if let value = value as? String {
                return value
            }
            if let value = value as? NSString {
                return value as String
            }
            return nil
        }
    }

    static func isPropertyListEncodableValue(_ value: Any) -> Bool {
        PropertyListSerialization.propertyList(["value": value], isValidFor: .binary)
    }

    static func isCandidateAppStorageKey(_ key: String) -> Bool {
        if key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple.") {
            return false
        }
        if appStorageExcludedExactKeys.contains(key) {
            return false
        }
        if appStorageExcludedPrefixes.contains(where: { key.hasPrefix($0) }) {
            return false
        }
        return true
    }

    static func appStorageValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (nil, _), (_, nil):
            return false
        default:
            break
        }

        if let lhsObject = lhs as? NSObject, let rhsObject = rhs as? NSObject {
            return lhsObject.isEqual(rhsObject)
        }

        return String(describing: lhs) == String(describing: rhs)
    }
}

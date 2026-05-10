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
    ) -> (imported: Int, skipped: Int) {
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

        var imported = 0
        var skipped = 0
        let globalPromptMergeResult = mergeGlobalSystemPromptStorageKeys(
            in: &incomingSnapshot,
            legacyGlobalSystemPrompt: legacyGlobalSystemPrompt,
            userDefaults: userDefaults
        )
        imported += globalPromptMergeResult.imported
        skipped += globalPromptMergeResult.skipped

        for (key, incomingValue) in incomingSnapshot {
            guard isCandidateAppStorageKey(key) else {
                skipped += 1
                continue
            }
            let localValue = userDefaults.object(forKey: key)
            if appStorageValuesEqual(localValue, incomingValue) {
                skipped += 1
                continue
            }

            userDefaults.set(incomingValue, forKey: key)
            imported += 1
        }

        return (imported, skipped)
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

    static func collectAppStorageSnapshot(userDefaults: UserDefaults) -> [String: Any] {
        var snapshot: [String: Any]
        if userDefaults === UserDefaults.standard,
           let bundleIdentifier = Bundle.main.bundleIdentifier,
           let domain = userDefaults.persistentDomain(forName: bundleIdentifier),
           !domain.isEmpty {
            snapshot = domain.filter { isCandidateAppStorageKey($0.key) && isPropertyListEncodableValue($0.value) }
        } else {
            snapshot = userDefaults.dictionaryRepresentation()
                .filter { isCandidateAppStorageKey($0.key) && isPropertyListEncodableValue($0.value) }
        }

        let globalPromptSnapshot = GlobalSystemPromptStore.load(userDefaults: userDefaults)
        snapshot[legacyGlobalSystemPromptKey] = globalPromptSnapshot.activeSystemPrompt
        if globalPromptSnapshot.entries.isEmpty {
            snapshot.removeValue(forKey: GlobalSystemPromptStore.entriesStorageKey)
            snapshot.removeValue(forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey)
        } else {
            if let encoded = try? JSONEncoder().encode(globalPromptSnapshot.entries) {
                snapshot[GlobalSystemPromptStore.entriesStorageKey] = encoded
            }
            snapshot[GlobalSystemPromptStore.selectedEntryIDStorageKey] = globalPromptSnapshot.selectedEntryID?.uuidString
        }
        return snapshot
    }

    static func mergeGlobalSystemPromptStorageKeys(
        in snapshot: inout [String: Any],
        legacyGlobalSystemPrompt: String?,
        userDefaults: UserDefaults
    ) -> (imported: Int, skipped: Int) {
        let entriesData = snapshot.removeValue(forKey: GlobalSystemPromptStore.entriesStorageKey) as? Data
        let selectedRawID = snapshot.removeValue(forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey) as? String
        let activePrompt = snapshot.removeValue(forKey: legacyGlobalSystemPromptKey) as? String
        let touchedKeyCount = [entriesData as Any?, selectedRawID as Any?, activePrompt as Any?]
            .filter { $0 != nil }
            .count

        if let entriesData {
            let incomingEntries = (try? JSONDecoder().decode([GlobalSystemPromptEntry].self, from: entriesData)) ?? []
            let before = GlobalSystemPromptStore.load(userDefaults: userDefaults)
            let after = GlobalSystemPromptStore.save(
                entries: incomingEntries,
                selectedEntryID: selectedRawID.flatMap(UUID.init(uuidString:)),
                userDefaults: userDefaults
            )
            let keyCount = max(1, touchedKeyCount)
            return before == after ? (0, keyCount) : (keyCount, 0)
        }

        guard let legacyPrompt = activePrompt ?? legacyGlobalSystemPrompt else {
            return (0, 0)
        }

        let before = GlobalSystemPromptStore.load(userDefaults: userDefaults)
        if before.activeSystemPrompt == legacyPrompt {
            return (0, max(1, touchedKeyCount))
        }

        var entries = before.entries
        if let selectedID = before.selectedEntryID,
           let index = entries.firstIndex(where: { $0.id == selectedID }) {
            entries[index].content = legacyPrompt
            entries[index].updatedAt = Date()
        } else {
            let entry = GlobalSystemPromptEntry(
                title: legacyPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "历史提示词" : "同步提示词",
                content: legacyPrompt,
                updatedAt: Date()
            )
            entries.insert(entry, at: 0)
        }

        _ = GlobalSystemPromptStore.save(
            entries: entries,
            selectedEntryID: entries.first?.id,
            userDefaults: userDefaults
        )
        return (max(1, touchedKeyCount), 0)
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

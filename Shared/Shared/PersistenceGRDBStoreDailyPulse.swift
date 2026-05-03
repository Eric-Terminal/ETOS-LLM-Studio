// ============================================================================
// PersistenceGRDBStoreDailyPulse.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 的 Daily Pulse JSON Blob 读写。
// ============================================================================

import Foundation

extension PersistenceGRDBStore {
    func saveDailyPulseRuns(_ runs: [DailyPulseRun]) {
        saveBlob(runs, forKey: BlobKey.dailyPulseRuns)
    }

    func loadDailyPulseRuns() -> [DailyPulseRun] {
        loadBlob([DailyPulseRun].self, forKey: BlobKey.dailyPulseRuns) ?? []
    }

    func saveDailyPulseFeedbackHistory(_ history: [DailyPulseFeedbackEvent]) {
        saveBlob(history, forKey: BlobKey.dailyPulseFeedbackHistory)
    }

    func loadDailyPulseFeedbackHistory() -> [DailyPulseFeedbackEvent] {
        loadBlob([DailyPulseFeedbackEvent].self, forKey: BlobKey.dailyPulseFeedbackHistory) ?? []
    }

    func saveDailyPulsePendingCuration(_ note: DailyPulseCurationNote?) {
        guard let note else {
            removeBlob(forKey: BlobKey.dailyPulsePendingCuration)
            return
        }
        saveBlob(note, forKey: BlobKey.dailyPulsePendingCuration)
    }

    func loadDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        loadBlob(DailyPulseCurationNote.self, forKey: BlobKey.dailyPulsePendingCuration)
    }

    func saveDailyPulseExternalSignals(_ signals: [DailyPulseExternalSignal]) {
        saveBlob(signals, forKey: BlobKey.dailyPulseExternalSignals)
    }

    func loadDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        loadBlob([DailyPulseExternalSignal].self, forKey: BlobKey.dailyPulseExternalSignals) ?? []
    }

    func saveDailyPulseTasks(_ tasks: [DailyPulseTask]) {
        saveBlob(tasks, forKey: BlobKey.dailyPulseTasks)
    }

    func loadDailyPulseTasks() -> [DailyPulseTask] {
        loadBlob([DailyPulseTask].self, forKey: BlobKey.dailyPulseTasks) ?? []
    }
}

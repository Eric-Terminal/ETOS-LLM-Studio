// ============================================================================
// PersistenceDailyPulseStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责每日脉冲运行记录、反馈、策展输入、外部信号和任务的文件持久化。
// ============================================================================

import Foundation
import os.log

extension Persistence {
    // MARK: - 每日脉冲持久化

    /// 保存每日脉冲运行记录。
    public static func saveDailyPulseRuns(_ runs: [DailyPulseRun]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseRuns(runs)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        let fileURL = dailyPulseRunsFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(runs)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存每日脉冲记录失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲运行记录。
    public static func loadDailyPulseRuns() -> [DailyPulseRun] {
        if let store = activeGRDBStore() {
            return store.loadDailyPulseRuns()
        }

        let fileURL = dailyPulseRunsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseRun].self, from: data)
        } catch {
            logger.error("读取每日脉冲记录失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存每日脉冲反馈历史。
    public static func saveDailyPulseFeedbackHistory(_ history: [DailyPulseFeedbackEvent]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseFeedbackHistory(history)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        let fileURL = dailyPulseFeedbackHistoryFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(history)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存每日脉冲反馈历史失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲反馈历史。
    public static func loadDailyPulseFeedbackHistory() -> [DailyPulseFeedbackEvent] {
        if let store = activeGRDBStore() {
            return store.loadDailyPulseFeedbackHistory()
        }

        let fileURL = dailyPulseFeedbackHistoryFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseFeedbackEvent].self, from: data)
        } catch {
            logger.error("读取每日脉冲反馈历史失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存待消费的每日脉冲策展输入。
    public static func saveDailyPulsePendingCuration(_ note: DailyPulseCurationNote?) {
        if let store = activeGRDBStore() {
            store.saveDailyPulsePendingCuration(note)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        let fileURL = dailyPulsePendingCurationFileURL()

        guard let note else {
            try? removeItemIfExists(at: fileURL)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(note)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存每日脉冲策展输入失败: \(error.localizedDescription)")
        }
    }

    /// 读取待消费的每日脉冲策展输入。
    public static func loadDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        if let store = activeGRDBStore() {
            return store.loadDailyPulsePendingCuration()
        }

        let fileURL = dailyPulsePendingCurationFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(DailyPulseCurationNote.self, from: data)
        } catch {
            logger.error("读取每日脉冲策展输入失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 保存每日脉冲外部信号历史。
    public static func saveDailyPulseExternalSignals(_ signals: [DailyPulseExternalSignal]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseExternalSignals(signals)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        let fileURL = dailyPulseExternalSignalsFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(signals)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存每日脉冲外部信号历史失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲外部信号历史。
    public static func loadDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        if let store = activeGRDBStore() {
            return store.loadDailyPulseExternalSignals()
        }

        let fileURL = dailyPulseExternalSignalsFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseExternalSignal].self, from: data)
        } catch {
            logger.error("读取每日脉冲外部信号历史失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 保存每日脉冲任务。
    public static func saveDailyPulseTasks(_ tasks: [DailyPulseTask]) {
        if let store = activeGRDBStore() {
            store.saveDailyPulseTasks(tasks)
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
            return
        }

        let fileURL = dailyPulseTasksFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
        } catch {
            logger.error("保存每日脉冲任务失败: \(error.localizedDescription)")
        }
    }

    /// 读取每日脉冲任务。
    public static func loadDailyPulseTasks() -> [DailyPulseTask] {
        if let store = activeGRDBStore() {
            return store.loadDailyPulseTasks()
        }

        let fileURL = dailyPulseTasksFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([DailyPulseTask].self, from: data)
        } catch {
            logger.error("读取每日脉冲任务失败: \(error.localizedDescription)")
            return []
        }
    }
}

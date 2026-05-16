// ============================================================================
// SyncDeltaEngineState.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 SyncDeltaEngine 使用的版本跟踪与检查点状态模型。
// ============================================================================

import Foundation

struct SyncVersionTrackerEntry: Codable {
    var checksum: String
    var updatedAt: Date
}

struct DailyPulseBundleDigest: Encodable {
    var runs: [DailyPulseRun]
    var feedbackHistory: [DailyPulseFeedbackEvent]
    var pendingCuration: DailyPulseCurationNote?
    var externalSignals: [DailyPulseExternalSignal]
    var tasks: [DailyPulseTask]
}

struct SyncVersionTrackerState: Codable {
    var entries: [String: SyncVersionTrackerEntry] = [:]
}

enum SyncVersionTrackerStore {
    private static let keyPrefix = "sync.delta.version-tracker."

    static func load(channel: String, userDefaults: UserDefaults) -> SyncVersionTrackerState {
        let key = keyPrefix + normalized(channel)
        let data: Data?
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            data = Persistence.readAppConfigData(key: key)
        } else {
            data = userDefaults.data(forKey: key)
        }
        guard let data,
              let state = try? JSONDecoder().decode(SyncVersionTrackerState.self, from: data) else {
            return SyncVersionTrackerState()
        }
        return state
    }

    static func save(_ state: SyncVersionTrackerState, channel: String, userDefaults: UserDefaults) {
        let key = keyPrefix + normalized(channel)
        guard let data = try? JSONEncoder().encode(state) else { return }
        if userDefaults === UserDefaults.standard {
            Persistence.writeAppConfig(key: key, data: data)
        } else {
            userDefaults.set(data, forKey: key)
        }
    }

    private static func normalized(_ channel: String) -> String {
        channel.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
    }
}

struct SyncCheckpointState: Codable {
    var previousLocalRecords: [String: SyncRecordDescriptor] = [:]
    var tombstones: [String: Date] = [:]
}

enum SyncCheckpointStore {
    private static let keyPrefix = "sync.delta.checkpoint."

    static func load(channel: String, userDefaults: UserDefaults) -> SyncCheckpointState {
        let key = keyPrefix + normalized(channel)
        let data: Data?
        if userDefaults === UserDefaults.standard {
            AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
            data = Persistence.readAppConfigData(key: key)
        } else {
            data = userDefaults.data(forKey: key)
        }
        guard let data,
              let state = try? JSONDecoder().decode(SyncCheckpointState.self, from: data) else {
            return SyncCheckpointState()
        }
        return state
    }

    static func save(_ state: SyncCheckpointState, channel: String, userDefaults: UserDefaults) {
        let key = keyPrefix + normalized(channel)
        guard let data = try? JSONEncoder().encode(state) else { return }
        if userDefaults === UserDefaults.standard {
            Persistence.writeAppConfig(key: key, data: data)
        } else {
            userDefaults.set(data, forKey: key)
        }
    }

    private static func normalized(_ channel: String) -> String {
        channel.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
    }
}

// ============================================================================
// Persistence.swift
// ============================================================================
// ETOS LLM Studio Watch App 数据持久化文件
//
// 功能特性:
// - 提供保存和加载聊天会话列表的功能
// - 提供保存和加载单个会话消息记录的功能
// - 管理文件系统中的存储路径
// ============================================================================

import Foundation
import os.log
import SQLite3
import GRDB
#if canImport(CoreText)
import CoreText
#endif

let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Persistence")

enum RelationalJSONValueCodec {
    struct EncodedValue {
        let type: String
        let stringValue: String?
        let numberValue: Double?
        let boolValue: Int?
        let jsonValueText: String?
    }

    static func encode(_ value: JSONValue) -> EncodedValue {
        switch value {
        case .string(let value):
            return EncodedValue(type: "string", stringValue: value, numberValue: nil, boolValue: nil, jsonValueText: nil)
        case .int(let value):
            return EncodedValue(type: "int", stringValue: nil, numberValue: Double(value), boolValue: nil, jsonValueText: nil)
        case .double(let value):
            return EncodedValue(type: "double", stringValue: nil, numberValue: value, boolValue: nil, jsonValueText: nil)
        case .bool(let value):
            return EncodedValue(type: "bool", stringValue: nil, numberValue: nil, boolValue: value ? 1 : 0, jsonValueText: nil)
        case .null:
            return EncodedValue(type: "null", stringValue: nil, numberValue: nil, boolValue: nil, jsonValueText: nil)
        case .array, .dictionary:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let jsonText = (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "null"
            return EncodedValue(type: "json", stringValue: nil, numberValue: nil, boolValue: nil, jsonValueText: jsonText)
        }
    }

    static func decode(
        type: String,
        stringValue: String?,
        numberValue: Double?,
        boolValue: Int?,
        jsonValueText: String?
    ) -> JSONValue {
        switch type {
        case "string":
            return .string(stringValue ?? "")
        case "int":
            return .int(Int(numberValue ?? 0))
        case "double":
            return .double(numberValue ?? 0)
        case "bool":
            return .bool((boolValue ?? 0) != 0)
        case "null":
            return .null
        case "json":
            guard let jsonValueText,
                  let data = jsonValueText.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return .null
            }
            return decoded
        default:
            return .null
        }
    }
}

enum RelationalFloatArrayCodec {
    static func encode(_ values: [Float]) -> Data {
        let copiedValues = values
        return copiedValues.withUnsafeBytes { Data($0) }
    }

    static func decode(_ data: Data) -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard data.count % stride == 0 else { return [] }
        let count = data.count / stride
        var values = Array(repeating: Float.zero, count: count)
        _ = values.withUnsafeMutableBytes { buffer in
            data.copyBytes(to: buffer)
        }
        return values
    }
}

public enum Persistence {
    static let sessionStoreSchemaVersion = 3
    static let sessionFoldersFileSchemaVersion = 1
    static let messagesFileSchemaVersion = 2
    static let requestLogSchemaVersion = 1
    static let defaultRequestLogRetentionLimit = 10_000
    static let migrationLogPrefix = "[(迁移)]"
    static let compatibilityReminderPrefix = "[(迁移)][兼容提醒]"
    static let compatibilityReminderLock = NSLock()
    static let requestLogLock = NSLock()
    static let grdbStoreLock = NSLock()
    static var cachedGRDBStore: PersistenceGRDBStore?
    static var lastGRDBStoreInitializationFailedAt: Date?
    static let grdbStoreRetryInterval: TimeInterval = 2
    static let auxiliaryStoreLock = NSLock()
    static var cachedAuxiliaryStores: [AuxiliaryStoreKind: PersistenceAuxiliaryGRDBStore] = [:]
    static var lastAuxiliaryStoreInitializationFailedAt: [AuxiliaryStoreKind: Date] = [:]
    static let auxiliaryStoreRetryInterval: TimeInterval = 2
    static let auxiliaryConfigBlobKeys: Set<String> = [
        "providers",
        "providers_v1",
        "worldbooks",
        "worldbooks_v1",
        "shortcut_tools",
        "shortcut_tools_v1",
        "feedback_tickets",
        "feedback_tickets_v1",
        "mcp_servers_records",
        "mcp_servers_records_v1"
    ]
    static let auxiliaryMemoryBlobKeys: Set<String> = [
        "memory_raw_memories",
        "memory_raw_memories_v1",
        "conversation_user_profile",
        "conversation_user_profile_v1"
    ]
    static var grdbEnabledOverrideForTests: Bool?
    static var requestLogRetentionLimitOverride: Int?
    static var hasLoggedCompatibilityReminder = false
    public static let launchBackupEnabledKey = "sync.backup.createOnLaunch"
    static let launchRecoveryNoticeUserDefaultsKey = "persistence.launchRecoveryNotice"
    static let launchBackupDirectoryName = "StartupBackups"
    static let launchBackupAndRecoveryLock = NSLock()
    static var hasPreparedLaunchDatabases = false
    static var launchPreparationResult = LaunchPreparationResult()
    static var hasCreatedLaunchBackupPoint = false
    static var hasScheduledLaunchBackupPoint = false

    static var deferredLaunchBackupDelay: TimeInterval {
        #if os(watchOS)
        120
        #else
        30
        #endif
    }

    struct LaunchPreparationResult {
        var restoredKinds: [LaunchDatabaseKind] = []
        var failedKinds: [LaunchDatabaseKind] = []
        var missingBackupKinds: [LaunchDatabaseKind] = []

        var needsChatFTSRebuild: Bool {
            restoredKinds.contains(.chat)
        }
    }

    public enum LegacyJSONMigrationStage: String, Sendable {
        case preparing
        case importingSessions
        case completed
    }

    public struct LegacyJSONMigrationStatus: Sendable {
        public let hasLegacyArtifacts: Bool
        public let importCompleted: Bool
        public let cleanupCompleted: Bool
        public let requiresImportDecision: Bool
        public let requiresCleanupDecision: Bool
        public let estimatedLegacyBytes: Int64
        public let estimatedSessionCount: Int

        public var estimatedLegacyMegabytes: Double {
            guard estimatedLegacyBytes > 0 else { return 0 }
            return Double(estimatedLegacyBytes) / 1_048_576
        }
    }

    public struct LegacyJSONMigrationProgress: Sendable {
        public let stage: LegacyJSONMigrationStage
        public let processedSessions: Int
        public let totalSessions: Int
        public let importedMessages: Int
        public let estimatedTotalBytes: Int64
        public let processedBytes: Int64
        public let currentSessionName: String?

        public var fractionCompleted: Double {
            if estimatedTotalBytes > 0 {
                return min(1, max(0, Double(processedBytes) / Double(estimatedTotalBytes)))
            }
            guard totalSessions > 0 else { return stage == .completed ? 1 : 0 }
            return min(1, max(0, Double(processedSessions) / Double(totalSessions)))
        }
    }

    public struct LegacyJSONMigrationResult: Sendable {
        public let importedSessions: Int
        public let importedMessages: Int
        public let hadLegacyArtifacts: Bool
        public let cleanupAttempted: Bool
        public let cleanupSucceeded: Bool
    }

    public enum LegacyJSONMigrationError: LocalizedError {
        case grdbUnavailable
        case importFailed(String)
        case cleanupFailed(String)

        public var errorDescription: String? {
            switch self {
            case .grdbUnavailable:
                return "当前无法访问 SQLite 数据库，暂时不能执行 JSON 迁移。"
            case .importFailed(let reason):
                return "迁移失败：\(reason)"
            case .cleanupFailed(let reason):
                return "清理失败：\(reason)"
            }
        }
    }

    enum LaunchDatabaseKind: CaseIterable {
        case chat
        case config
        case memory

        var displayName: String {
            switch self {
            case .chat:
                return "聊天数据库"
            case .config:
                return "配置数据库"
            case .memory:
                return "记忆数据库"
            }
        }
    }

    enum AuxiliaryStoreKind: String {
        case config = "config-store.sqlite"
        case memory = "memory-store.sqlite"

        var loggerCategory: String {
            switch self {
            case .config:
                return "PersistenceAuxConfig"
            case .memory:
                return "PersistenceAuxMemory"
            }
        }
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static let sessionIndexFileName = "index.json"
    static let sessionFoldersFileName = "folders.json"
    static let sessionRecordsDirectoryName = "sessions"
    static let requestLogsDirectoryName = "RequestLogs"
    static let requestLogsFileName = "index.json"
    static let dailyPulseDirectoryName = "DailyPulse"
    static let dailyPulseRunsFileName = "runs.json"
    static let dailyPulseFeedbackHistoryFileName = "feedback-history.json"
    static let dailyPulsePendingCurationFileName = "pending-curation.json"
    static let dailyPulseExternalSignalsFileName = "external-signals.json"
    static let dailyPulseTasksFileName = "tasks.json"
    static let legacySessionDirectoryName = "v3"
    static let legacyArchiveDirectoryName = "legacy"

    struct ChatMessagesFileEnvelope: Codable {
        let schemaVersion: Int
        let messages: [ChatMessage]
    }

    struct SessionIndexFilePayload: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let sessions: [SessionIndexItemPayload]
    }

    struct SessionIndexItemPayload: Codable {
        let id: UUID
        let name: String
        let updatedAt: String
    }

    struct SessionFoldersFileEnvelope: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let folders: [SessionFolder]
    }

    struct SessionPromptsPayload: Codable {
        let topicPrompt: String?
        let enhancedPrompt: String?
    }

    struct SessionMetaPayload: Codable {
        let id: UUID
        let name: String
        let folderID: UUID?
        let lorebookIDs: [UUID]
        let worldbookContextIsolationEnabled: Bool?
        let conversationSummary: String?
        let conversationSummaryUpdatedAt: String?
    }

    struct SessionRecordFilePayload: Codable {
        let schemaVersion: Int
        let session: SessionMetaPayload
        let prompts: SessionPromptsPayload
        let messages: [ChatMessage]
    }

    struct SessionRecordSummaryPayload: Codable {
        let schemaVersion: Int
        let session: SessionMetaPayload
        let prompts: SessionPromptsPayload
    }

    struct RequestLogFileEnvelope: Codable {
        let schemaVersion: Int
        let updatedAt: String
        let logs: [RequestLogEntry]
    }

    struct LegacyMessagesReadResult {
        let messages: [ChatMessage]
        let didMigrateFileSchema: Bool
        let didMigratePlacement: Bool
    }
}

// ============================================================================
// Persistence.swift
// ============================================================================
// ETOS LLM Studio
//
// Persistence 的入口与共享状态定义；具体存储逻辑已拆分到相邻文件。
// ============================================================================

import Foundation
import os.log
import GRDB

public enum Persistence {
    static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Persistence")
    static let sessionStoreSchemaVersion = 3
    static let sessionFoldersFileSchemaVersion = 1
    static let sessionTagsFileSchemaVersion = 1
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
    static let launchRecoveryNoticeKey = "persistence.launchRecoveryNotice"
    static let launchBackupDirectoryName = "StartupBackups"
    static let launchBackupAndRecoveryLock = NSLock()
    static var hasPreparedLaunchDatabases = false
    static var launchPreparationResult = LaunchPreparationResult()
    static var pendingLaunchRecoveryNotice: String?
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
    static let sessionTagsFileName = "tags.json"
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

}
// ============================================================================
// BatchJobStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责本地持久�?BatchJob 的状态。采�?JSON 文件存储，适合小规模任务�?// ============================================================================

import Foundation
import os.log

public final class BatchJobStore: @unchecked Sendable {
    public static let shared = BatchJobStore()
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "BatchJobStore")
    
    private var jobs: [String: BatchJob] = [:]
    private let queue = DispatchQueue(label: "com.ETOS.LLM.Studio.BatchJobStore")
    
    private var fileURL: URL {
        let docsDir = Persistence.documentsDirectory
        let batchDir = docsDir.appendingPathComponent("BatchJobs")
        if !FileManager.default.fileExists(atPath: batchDir.path) {
            try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
        }
        return batchDir.appendingPathComponent("jobs.json")
    }
    
    private init() {
        load()
    }
    
    public func saveJob(_ job: BatchJob) {
        queue.async {
            self.jobs[job.id] = job
            self.persist()
        }
    }
    
    public func getJob(id: String) -> BatchJob? {
        queue.sync {
            return jobs[id]
        }
    }
    
    public func getAllJobs() -> [BatchJob] {
        queue.sync {
            return Array(jobs.values).sorted(by: { $0.createdAt > $1.createdAt })
        }
    }
    
    public func removeJob(id: String) {
        queue.async {
            self.jobs.removeValue(forKey: id)
            self.persist()
        }
    }
    
    private func load() {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([String: BatchJob].self, from: data)
                self.jobs = decoded
                logger.info("成功加载�?\(decoded.count) �?Batch 任务�?)
            } catch {
                logger.error("加载 Batch 任务失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func persist() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("保存 Batch 任务失败: \(error.localizedDescription)")
        }
    }
}

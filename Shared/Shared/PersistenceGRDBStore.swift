import Foundation
import GRDB
import os.log

enum DatabaseMaintenanceLaunchDeferral {
    static let delayNanoseconds: UInt64 = {
        #if os(watchOS)
        return 30_000_000_000
        #else
        return 8_000_000_000
        #endif
    }()
}

/// GRDB 持久化存储实现（会话、消息、请求日志、Daily Pulse 等）。
final class PersistenceGRDBStore {
    enum MetaKey {
        static let jsonImportCompleted = "json_import_completed"
        static let jsonCleanupCompleted = "json_cleanup_completed"
        static let legacyJSONImportCompleted = "json_import_completed_v1"
        static let legacyJSONCleanupCompleted = "json_cleanup_completed_v1"

        static let jsonImportCompletedCandidates = [jsonImportCompleted, legacyJSONImportCompleted]
        static let jsonCleanupCompletedCandidates = [jsonCleanupCompleted, legacyJSONCleanupCompleted]
    }

    enum BlobKey {
        static let dailyPulseRuns = "daily_pulse_runs"
        static let dailyPulseFeedbackHistory = "daily_pulse_feedback_history"
        static let dailyPulsePendingCuration = "daily_pulse_pending_curation"
        static let dailyPulseExternalSignals = "daily_pulse_external_signals"
        static let dailyPulseTasks = "daily_pulse_tasks"
    }

    struct LegacySessionIndexFile: Decodable {
        struct Item: Decodable {
            let id: UUID
            let name: String
            let updatedAt: String
        }

        let schemaVersion: Int
        let updatedAt: String
        let sessions: [Item]
    }

    struct LegacySessionPrompts: Decodable {
        let topicPrompt: String?
        let enhancedPrompt: String?
    }

    struct LegacySessionMeta: Decodable {
        let id: UUID
        let name: String
        let folderID: UUID?
        let lorebookIDs: [UUID]
        let worldbookContextIsolationEnabled: Bool?
        let conversationSummary: String?
        let conversationSummaryUpdatedAt: String?
    }

    struct LegacySessionRecordFile: Decodable {
        let schemaVersion: Int
        let session: LegacySessionMeta
        let prompts: LegacySessionPrompts
        let messages: [ChatMessage]
    }

    struct ChatMessagesFileEnvelope: Decodable {
        let schemaVersion: Int
        let messages: [ChatMessage]
    }

    struct SessionFoldersFileEnvelope: Decodable {
        let schemaVersion: Int
        let updatedAt: String
        let folders: [SessionFolder]
    }

    struct RequestLogFileEnvelope: Decodable {
        let schemaVersion: Int
        let updatedAt: String
        let logs: [RequestLogEntry]
    }

    struct LegacySessionSnapshot {
        let session: ChatSession
        let messages: [ChatMessage]
        let sortIndex: Int
        let updatedAt: Date
        let conversationSummary: String?
        let conversationSummaryUpdatedAt: Date?
    }

    struct LegacySnapshot {
        let sessions: [LegacySessionSnapshot]
        let folders: [SessionFolder]
        let requestLogs: [RequestLogEntry]
        let dailyPulseRuns: [DailyPulseRun]
        let dailyPulseFeedbackHistory: [DailyPulseFeedbackEvent]
        let dailyPulsePendingCuration: DailyPulseCurationNote?
        let dailyPulseExternalSignals: [DailyPulseExternalSignal]
        let dailyPulseTasks: [DailyPulseTask]

        var messageCount: Int {
            sessions.reduce(into: 0) { partialResult, item in
                partialResult += item.messages.count
            }
        }

        var hasAnyData: Bool {
            !sessions.isEmpty ||
            !folders.isEmpty ||
            !requestLogs.isEmpty ||
            !dailyPulseRuns.isEmpty ||
            !dailyPulseFeedbackHistory.isEmpty ||
            dailyPulsePendingCuration != nil ||
            !dailyPulseExternalSignals.isEmpty ||
            !dailyPulseTasks.isEmpty
        }
    }

    struct LegacySessionImportPlan {
        let id: UUID
        let fallbackSession: ChatSession
        let sortIndex: Int
        let fallbackUpdatedAt: Date
        let sessionRecordURL: URL?
        let legacyMessagesURL: URL?
        let estimatedBytes: Int64
    }

    struct LegacyImportPlan {
        let sessionPlans: [LegacySessionImportPlan]
        let sessionIDsForCleanup: [UUID]
        let estimatedBytes: Int64
        let candidateURLs: [URL]

        var hasAnyData: Bool {
            !candidateURLs.isEmpty
        }
    }

    enum LegacyIncrementalImportError: LocalizedError {
        case malformedSessionRecord(sessionID: UUID, path: String)
        case malformedMessagesFile(sessionID: UUID, path: String)

        var errorDescription: String? {
            switch self {
            case .malformedSessionRecord(let sessionID, let path):
                return "会话 \(sessionID.uuidString) 的旧版会话文件无法解析：\(path)"
            case .malformedMessagesFile(let sessionID, let path):
                return "会话 \(sessionID.uuidString) 的旧版消息文件无法解析：\(path)"
            }
        }
    }

    struct PersistedMessageRecord: Equatable {
        var id: String
        let sessionID: String
        let role: String
        let requestedAt: Double?
        let content: String
        let contentVersionsJSON: Data
        let currentVersionIndex: Int
        let reasoningContent: String?
        let toolCallsJSON: Data?
        let toolCallsPlacement: String?
        let tokenUsageJSON: Data?
        let audioFileName: String?
        let imageFileNamesJSON: Data?
        let fileFileNamesJSON: Data?
        let fullErrorContent: String?
        let responseMetricsJSON: Data?
        let responseGroupID: String?
        let responseAttemptID: String?
        let responseAttemptIndex: Int?
        let selectedResponseAttemptID: String?
        let position: Int
        let createdAt: Double
    }

    struct UsageDayKeyFilter {
        let sql: String
        let arguments: StatementArguments
        let shouldQuery: Bool
    }

    let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "PersistenceGRDB")
    static let incrementalVacuumTriggerPages = 8_192
    static let incrementalVacuumTriggerRatio = 0.2
    static let incrementalVacuumBatchPages = 4_096
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    let chatsDirectory: URL
    let databaseURL: URL
    let dbPool: DatabasePool
    let messageWriteQueue = DispatchQueue(
        label: "com.etos.persistence.messages.write.queue",
        qos: .userInitiated
    )
    let messageWriteQueueSpecificKey = DispatchSpecificKey<UInt8>()

}

/// 辅助分库存储（JSON Blob + 关系化扩展表）。
final class PersistenceAuxiliaryGRDBStore {
    let logger: Logger
    static let incrementalVacuumTriggerPages = 1_024
    static let incrementalVacuumTriggerRatio = 0.25
    static let incrementalVacuumBatchPages = 512
    let databaseURL: URL
    let supportsConfigRelationalSchema: Bool
    let supportsMemoryRelationalSchema: Bool
    let dbPool: DatabasePool

}

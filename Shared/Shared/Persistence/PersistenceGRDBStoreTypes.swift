// ============================================================================
// PersistenceGRDBStoreTypes.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 拆分后共享的内部数据结构与迁移错误定义。
// ============================================================================

import Foundation
import GRDB

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

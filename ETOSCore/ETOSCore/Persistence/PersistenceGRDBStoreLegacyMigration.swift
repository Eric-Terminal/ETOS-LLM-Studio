// ============================================================================
// PersistenceGRDBStoreLegacyMigration.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 PersistenceGRDBStore 的旧 JSON 数据迁移、导入校验与清理流程。
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    func legacyJSONMigrationStatus() -> Persistence.LegacyJSONMigrationStatus {
        let plan = buildLegacyImportPlan()
        let metaState: (importCompleted: Bool, cleanupCompleted: Bool) = (try? dbPool.read { db in
            let importValue = try readMetaValue(db, candidateKeys: MetaKey.jsonImportCompletedCandidates)
            let cleanupValue = try readMetaValue(db, candidateKeys: MetaKey.jsonCleanupCompletedCandidates)
            return (importValue == "1", cleanupValue == "1")
        }) ?? (false, false)

        let hasLegacyArtifacts = !plan.candidateURLs.isEmpty
        let requiresImportDecision = hasLegacyArtifacts && !metaState.importCompleted
        let requiresCleanupDecision = hasLegacyArtifacts && metaState.importCompleted && !metaState.cleanupCompleted

        return Persistence.LegacyJSONMigrationStatus(
            hasLegacyArtifacts: hasLegacyArtifacts,
            importCompleted: metaState.importCompleted,
            cleanupCompleted: metaState.cleanupCompleted,
            requiresImportDecision: requiresImportDecision,
            requiresCleanupDecision: requiresCleanupDecision,
            estimatedLegacyBytes: plan.estimatedBytes,
            estimatedSessionCount: plan.sessionPlans.count
        )
    }

    func migrateLegacyJSONIncrementally(
        shouldCleanupLegacyJSONAfterImport: Bool,
        throttleInterval: TimeInterval,
        progressHandler: (@Sendable (Persistence.LegacyJSONMigrationProgress) -> Void)?
    ) throws -> Persistence.LegacyJSONMigrationResult {
        let plan = buildLegacyImportPlan()
        guard plan.hasAnyData else {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted, MetaKey.legacyJSONCleanupCompleted])
            }
            let completionProgress = Persistence.LegacyJSONMigrationProgress(
                stage: .completed,
                processedSessions: 0,
                totalSessions: 0,
                importedMessages: 0,
                estimatedTotalBytes: 0,
                processedBytes: 0,
                currentSessionName: nil
            )
            progressHandler?(completionProgress)
            return Persistence.LegacyJSONMigrationResult(
                importedSessions: 0,
                importedMessages: 0,
                hadLegacyArtifacts: false,
                cleanupAttempted: true,
                cleanupSucceeded: true
            )
        }

        let initialProgress = Persistence.LegacyJSONMigrationProgress(
            stage: .preparing,
            processedSessions: 0,
            totalSessions: plan.sessionPlans.count,
            importedMessages: 0,
            estimatedTotalBytes: plan.estimatedBytes,
            processedBytes: 0,
            currentSessionName: nil
        )
        progressHandler?(initialProgress)

        var importedSessions = 0
        var importedMessages = 0
        var processedBytes: Int64 = 0
        for (index, sessionPlan) in plan.sessionPlans.enumerated() {
            let sessionProgress = Persistence.LegacyJSONMigrationProgress(
                stage: .importingSessions,
                processedSessions: index,
                totalSessions: plan.sessionPlans.count,
                importedMessages: importedMessages,
                estimatedTotalBytes: plan.estimatedBytes,
                processedBytes: processedBytes,
                currentSessionName: sessionPlan.fallbackSession.name
            )
            progressHandler?(sessionProgress)

            let snapshot = try loadLegacySessionSnapshot(from: sessionPlan)
            let insertedMessages = try mergeLegacySessionSnapshotIntoDatabase(snapshot)
            importedMessages += insertedMessages
            importedSessions += 1

            processedBytes += sessionPlan.estimatedBytes
            let afterSessionProgress = Persistence.LegacyJSONMigrationProgress(
                stage: .importingSessions,
                processedSessions: index + 1,
                totalSessions: plan.sessionPlans.count,
                importedMessages: importedMessages,
                estimatedTotalBytes: plan.estimatedBytes,
                processedBytes: min(processedBytes, plan.estimatedBytes),
                currentSessionName: sessionPlan.fallbackSession.name
            )
            progressHandler?(afterSessionProgress)

            if throttleInterval > 0 {
                Thread.sleep(forTimeInterval: throttleInterval)
            }
        }

        try importLegacySupplementaryArtifacts()

        try dbPool.write { db in
            try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
            try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted])
        }

        var cleanupAttempted = false
        var cleanupSucceeded = false
        if shouldCleanupLegacyJSONAfterImport {
            cleanupAttempted = true
            cleanupSucceeded = removeLegacyJSONArtifacts(sessionIDs: plan.sessionIDsForCleanup)
            if cleanupSucceeded {
                try dbPool.write { db in
                    try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                    try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
                }
            }
        } else {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "0")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
            }
        }

        let completionProgress = Persistence.LegacyJSONMigrationProgress(
            stage: .completed,
            processedSessions: plan.sessionPlans.count,
            totalSessions: plan.sessionPlans.count,
            importedMessages: importedMessages,
            estimatedTotalBytes: plan.estimatedBytes,
            processedBytes: plan.estimatedBytes,
            currentSessionName: nil
        )
        progressHandler?(completionProgress)

        return Persistence.LegacyJSONMigrationResult(
            importedSessions: importedSessions,
            importedMessages: importedMessages,
            hadLegacyArtifacts: true,
            cleanupAttempted: cleanupAttempted,
            cleanupSucceeded: cleanupSucceeded
        )
    }

    @discardableResult
    func cleanupLegacyJSONArtifactsAfterImport() throws -> Bool {
        let plan = buildLegacyImportPlan()
        guard plan.hasAnyData else {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
            }
            return true
        }

        let didCleanup = removeLegacyJSONArtifacts(sessionIDs: plan.sessionIDsForCleanup)
        if didCleanup {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
            }
        }
        return didCleanup
    }

    private func importLegacySupplementaryArtifacts() throws {
        let folders = readSessionFolders()
        let requestLogs = readRequestLogs()
        let dailyPulseRuns = readDailyPulseRuns()
        let dailyPulseFeedbackHistory = readDailyPulseFeedbackHistory()
        let dailyPulsePendingCuration = readDailyPulsePendingCuration()
        let dailyPulseExternalSignals = readDailyPulseExternalSignals()
        let dailyPulseTasks = readDailyPulseTasks()

        try dbPool.write { db in
            for folder in folders {
                try db.execute(
                    sql: """
                    INSERT INTO session_folders (id, name, parent_id, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        parent_id = excluded.parent_id,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        folder.id.uuidString,
                        folder.name,
                        folder.parentID?.uuidString,
                        folder.updatedAt.timeIntervalSince1970
                    ]
                )
            }

            for entry in requestLogs {
                try db.execute(
                    sql: """
                    INSERT INTO request_logs (
                        id, request_id, session_id, provider_id, provider_name, model_id,
                        requested_at, finished_at, is_streaming, status, token_usage_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        request_id = excluded.request_id,
                        session_id = excluded.session_id,
                        provider_id = excluded.provider_id,
                        provider_name = excluded.provider_name,
                        model_id = excluded.model_id,
                        requested_at = excluded.requested_at,
                        finished_at = excluded.finished_at,
                        is_streaming = excluded.is_streaming,
                        status = excluded.status,
                        token_usage_json = excluded.token_usage_json
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.requestID.uuidString,
                        entry.sessionID?.uuidString,
                        entry.providerID?.uuidString,
                        entry.providerName,
                        entry.modelID,
                        entry.requestedAt.timeIntervalSince1970,
                        entry.finishedAt.timeIntervalSince1970,
                        entry.isStreaming ? 1 : 0,
                        entry.status.rawValue,
                        encodeJSON(entry.tokenUsage)
                    ]
                )
            }

            if !dailyPulseRuns.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseRuns, value: dailyPulseRuns)
            }
            if !dailyPulseFeedbackHistory.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseFeedbackHistory, value: dailyPulseFeedbackHistory)
            }
            if let note = dailyPulsePendingCuration {
                try writeBlob(db, key: BlobKey.dailyPulsePendingCuration, value: note)
            }
            if !dailyPulseExternalSignals.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseExternalSignals, value: dailyPulseExternalSignals)
            }
            if !dailyPulseTasks.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseTasks, value: dailyPulseTasks)
            }
        }
    }

    private func mergeLegacySessionSnapshotIntoDatabase(_ snapshot: LegacySessionSnapshot) throws -> Int {
        try dbPool.write { db in
            try upsertSession(
                db,
                session: snapshot.session,
                sortIndex: snapshot.sortIndex,
                updatedAt: snapshot.updatedAt,
                conversationSummary: snapshot.conversationSummary,
                conversationSummaryUpdatedAt: snapshot.conversationSummaryUpdatedAt,
                preserveExistingSummary: true
            )

            let existingMessageCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                arguments: [snapshot.session.id.uuidString]
            ) ?? 0
            if existingMessageCount > 0 {
                self.logger.info("会话 \(snapshot.session.id.uuidString, privacy: .public) 已存在消息，跳过覆盖旧 JSON 内容。")
                return 0
            }

            for (position, message) in snapshot.messages.enumerated() {
                try insertMessage(
                    db,
                    message: message,
                    sessionID: snapshot.session.id,
                    position: position,
                    fallbackTimestamp: snapshot.updatedAt.addingTimeInterval(Double(position) * 0.000_001)
                )
            }
            return snapshot.messages.count
        }
    }


    private func totalMessageCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
    }
}

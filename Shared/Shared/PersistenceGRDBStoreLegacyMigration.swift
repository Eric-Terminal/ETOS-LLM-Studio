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

    private func importLegacyJSONIfNeeded() throws {
        let snapshot = collectLegacySnapshot()
        guard snapshot.hasAnyData else {
            try dbPool.write { db in
                try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
                try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted, MetaKey.legacyJSONCleanupCompleted])
            }
            return
        }

        let metaState = try dbPool.read { db -> (importCompleted: Bool, cleanupCompleted: Bool) in
            let importValue = try readMetaValue(db, candidateKeys: MetaKey.jsonImportCompletedCandidates)
            let cleanupValue = try readMetaValue(db, candidateKeys: MetaKey.jsonCleanupCompletedCandidates)
            return (importValue == "1", cleanupValue == "1")
        }
        var importCompleted = metaState.importCompleted
        var didRepairIncompleteImport = false

        let existingMessageCountBeforeImport = try totalMessageCount()
        if snapshot.messageCount == 0, existingMessageCountBeforeImport > 0 {
            self.logger.error("检测到旧 JSON 快照消息为 0，但数据库已有 \(existingMessageCountBeforeImport) 条消息，已跳过导入与清理。")
            return
        }
        var importedBefore = try isLegacySnapshotImported(snapshot)
        if existingMessageCountBeforeImport > 0, !importCompleted {
            if importedBefore {
                self.logger.info("检测到数据库已有消息且旧 JSON 快照已完成导入，补写导入完成标记并继续清理流程。")
                try dbPool.write { db in
                    try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
                    try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted])
                }
                importCompleted = true
            } else if try canRepairIncompleteImport(snapshot) {
                self.logger.warning("检测到未完成的历史 JSON 导入，已进入修复性重导入流程。")
                try mergeLegacySnapshotIntoDatabase(snapshot)
                importedBefore = true
                didRepairIncompleteImport = true
            } else {
                self.logger.error("检测到数据库已有 \(existingMessageCountBeforeImport) 条消息且 JSON 导入状态未完成，已跳过自动导入与清理以避免覆盖现有数据。")
                return
            }
        }

        if (!importCompleted || !importedBefore), !didRepairIncompleteImport {
            try mergeLegacySnapshotIntoDatabase(snapshot)
            importedBefore = true
        }

        let existingMessageCountAfterImport = try totalMessageCount()
        if existingMessageCountBeforeImport > 0,
           existingMessageCountAfterImport < existingMessageCountBeforeImport {
            self.logger.error("检测到导入后消息总数下降（\(existingMessageCountBeforeImport) -> \(existingMessageCountAfterImport)），已中止清理旧 JSON 文件。")
            return
        }

        let verificationPassed = try isLegacySnapshotImported(snapshot)
        guard verificationPassed else {
            logger.error("JSON 数据导入校验失败，已保留旧 JSON 文件。")
            return
        }

        try dbPool.write { db in
            try writeMeta(db, key: MetaKey.jsonImportCompleted, value: "1")
            try removeMetaEntries(db, keys: [MetaKey.legacyJSONImportCompleted])
        }

        if !snapshot.sessions.isEmpty, snapshot.messageCount == 0 {
            self.logger.warning("旧 JSON 快照包含会话但消息总数为 0，已禁用自动清理旧 JSON，等待人工确认。")
            return
        }

        if snapshot.sessions.isEmpty, hasUnindexedLegacySessionArtifacts() {
            self.logger.warning("检测到未建索引的旧会话 JSON 文件，已跳过自动清理，避免误删潜在对话数据。")
            return
        }

        let shouldCleanupLegacyJSON = !metaState.cleanupCompleted || hasLegacyJSONArtifacts(sessionIDs: snapshot.sessions.map(\.session.id))
        if shouldCleanupLegacyJSON {
            let didCleanupAllLegacyJSON = removeLegacyJSONArtifacts(sessionIDs: snapshot.sessions.map(\.session.id))
            if didCleanupAllLegacyJSON {
                try dbPool.write { db in
                    try writeMeta(db, key: MetaKey.jsonCleanupCompleted, value: "1")
                    try removeMetaEntries(db, keys: [MetaKey.legacyJSONCleanupCompleted])
                }
                self.logger.info("JSON 数据已导入并校验，旧 JSON 文件已清理，数据库路径: \(self.databaseURL.path)")
            } else {
                self.logger.warning("JSON 数据已导入并校验，但旧 JSON 文件未完全清理。")
            }
            return
        }

        self.logger.info("JSON 数据已导入并校验，数据库路径: \(self.databaseURL.path)")
    }

    private func totalMessageCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
    }

    private func collectLegacySnapshot() -> LegacySnapshot {
        let sessions = readCurrentLayoutSessions() ?? readLegacyLayoutSessions()
        let folders = readSessionFolders()
        let requestLogs = readRequestLogs()
        let dailyPulseRuns = readDailyPulseRuns()
        let dailyPulseFeedbackHistory = readDailyPulseFeedbackHistory()
        let dailyPulsePendingCuration = readDailyPulsePendingCuration()
        let dailyPulseExternalSignals = readDailyPulseExternalSignals()
        let dailyPulseTasks = readDailyPulseTasks()

        return LegacySnapshot(
            sessions: sessions,
            folders: folders,
            requestLogs: requestLogs,
            dailyPulseRuns: dailyPulseRuns,
            dailyPulseFeedbackHistory: dailyPulseFeedbackHistory,
            dailyPulsePendingCuration: dailyPulsePendingCuration,
            dailyPulseExternalSignals: dailyPulseExternalSignals,
            dailyPulseTasks: dailyPulseTasks
        )
    }

    private func mergeLegacySnapshotIntoDatabase(_ snapshot: LegacySnapshot) throws {
        try dbPool.write { db in
            for item in snapshot.sessions {
                try upsertSession(
                    db,
                    session: item.session,
                    sortIndex: item.sortIndex,
                    updatedAt: item.updatedAt,
                    conversationSummary: item.conversationSummary,
                    conversationSummaryUpdatedAt: item.conversationSummaryUpdatedAt,
                    preserveExistingSummary: false
                )

                let existingMessageCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                    arguments: [item.session.id.uuidString]
                ) ?? 0
                if item.messages.isEmpty, existingMessageCount > 0 {
                    self.logger.warning("检测到旧 JSON 快照消息为空，已跳过覆盖会话消息: \(item.session.id.uuidString)")
                    continue
                }

                try db.execute(
                    sql: "DELETE FROM messages WHERE session_id = ?",
                    arguments: [item.session.id.uuidString]
                )
                for (position, message) in item.messages.enumerated() {
                    try insertMessage(
                        db,
                        message: message,
                        sessionID: item.session.id,
                        position: position,
                        fallbackTimestamp: item.updatedAt.addingTimeInterval(Double(position) * 0.000_001)
                    )
                }
            }

            for folder in snapshot.folders {
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

            for entry in snapshot.requestLogs {
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

            if !snapshot.dailyPulseRuns.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseRuns, value: snapshot.dailyPulseRuns)
            }
            if !snapshot.dailyPulseFeedbackHistory.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseFeedbackHistory, value: snapshot.dailyPulseFeedbackHistory)
            }
            if let note = snapshot.dailyPulsePendingCuration {
                try writeBlob(db, key: BlobKey.dailyPulsePendingCuration, value: note)
            }
            if !snapshot.dailyPulseExternalSignals.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseExternalSignals, value: snapshot.dailyPulseExternalSignals)
            }
            if !snapshot.dailyPulseTasks.isEmpty {
                try writeBlob(db, key: BlobKey.dailyPulseTasks, value: snapshot.dailyPulseTasks)
            }
        }
    }

    private func isLegacySnapshotImported(_ snapshot: LegacySnapshot) throws -> Bool {
        try dbPool.read { db in
            for item in snapshot.sessions {
                let sessionExists = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sessions WHERE id = ?",
                    arguments: [item.session.id.uuidString]
                ) ?? 0) > 0
                guard sessionExists else { return false }

                let messageCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM messages WHERE session_id = ?",
                    arguments: [item.session.id.uuidString]
                ) ?? 0
                guard messageCount >= item.messages.count else { return false }
            }

            for folder in snapshot.folders {
                let folderExists = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM session_folders WHERE id = ?",
                    arguments: [folder.id.uuidString]
                ) ?? 0) > 0
                guard folderExists else { return false }
            }

            for entry in snapshot.requestLogs {
                let logExists = (try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM request_logs WHERE id = ?",
                    arguments: [entry.id.uuidString]
                ) ?? 0) > 0
                guard logExists else { return false }
            }

            if !snapshot.dailyPulseRuns.isEmpty {
                let runs: [DailyPulseRun]? = try readBlob(db, type: [DailyPulseRun].self, key: BlobKey.dailyPulseRuns)
                guard (runs?.count ?? 0) >= snapshot.dailyPulseRuns.count else { return false }
            }
            if !snapshot.dailyPulseFeedbackHistory.isEmpty {
                let history: [DailyPulseFeedbackEvent]? = try readBlob(
                    db,
                    type: [DailyPulseFeedbackEvent].self,
                    key: BlobKey.dailyPulseFeedbackHistory
                )
                guard (history?.count ?? 0) >= snapshot.dailyPulseFeedbackHistory.count else { return false }
            }
            if snapshot.dailyPulsePendingCuration != nil {
                let note: DailyPulseCurationNote? = try readBlob(
                    db,
                    type: DailyPulseCurationNote.self,
                    key: BlobKey.dailyPulsePendingCuration
                )
                guard note != nil else { return false }
            }
            if !snapshot.dailyPulseExternalSignals.isEmpty {
                let signals: [DailyPulseExternalSignal]? = try readBlob(
                    db,
                    type: [DailyPulseExternalSignal].self,
                    key: BlobKey.dailyPulseExternalSignals
                )
                guard (signals?.count ?? 0) >= snapshot.dailyPulseExternalSignals.count else { return false }
            }
            if !snapshot.dailyPulseTasks.isEmpty {
                let tasks: [DailyPulseTask]? = try readBlob(db, type: [DailyPulseTask].self, key: BlobKey.dailyPulseTasks)
                guard (tasks?.count ?? 0) >= snapshot.dailyPulseTasks.count else { return false }
            }

            return true
        }
    }

    private func canRepairIncompleteImport(_ snapshot: LegacySnapshot) throws -> Bool {
        guard !snapshot.sessions.isEmpty else { return false }
        let snapshotSessionIDs = Set(snapshot.sessions.map { $0.session.id.uuidString })
        return try dbPool.read { db in
            let dbSessionIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM sessions"))
            guard !dbSessionIDs.isEmpty else { return false }
            return dbSessionIDs.isSubset(of: snapshotSessionIDs)
        }
    }

    private func readBlob<T: Decodable>(_ db: Database, type: T.Type, key: String) throws -> T? {
        guard let data = try Data.fetchOne(
            db,
            sql: "SELECT json_data FROM json_blobs WHERE key = ?",
            arguments: [key]
        ) else {
            return nil
        }
        guard isValidUTF8JSONData(data) else {
            return nil
        }
        return try makeISO8601Decoder().decode(T.self, from: data)
    }
}

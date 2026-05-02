import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    func repairCoreSchemaIfNeeded() throws {
        try dbPool.write { db in
            try createCoreTablesIfMissing(db)
            try requireColumns(db, table: "sessions", columns: ["id", "name"])
            try requireColumns(db, table: "messages", columns: ["id", "session_id", "role", "content"])
            try requireColumns(db, table: "request_logs", columns: ["id", "request_id", "provider_name", "model_id"])
            try requireColumns(db, table: "session_folders", columns: ["id", "name"])

            try ensureColumn(db, table: "sessions", column: "topic_prompt", definition: "topic_prompt TEXT")
            try ensureColumn(db, table: "sessions", column: "enhanced_prompt", definition: "enhanced_prompt TEXT")
            try ensureColumn(db, table: "sessions", column: "folder_id", definition: "folder_id TEXT")
            try ensureColumn(db, table: "sessions", column: "lorebook_ids_json", definition: "lorebook_ids_json BLOB NOT NULL DEFAULT X'5B5D'")
            try ensureColumn(db, table: "sessions", column: "worldbook_context_isolation_enabled", definition: "worldbook_context_isolation_enabled INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "sessions", column: "is_temporary", definition: "is_temporary INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "sessions", column: "sort_index", definition: "sort_index INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "sessions", column: "updated_at", definition: "updated_at REAL NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "sessions", column: "conversation_summary", definition: "conversation_summary TEXT")
            try ensureColumn(db, table: "sessions", column: "conversation_summary_updated_at", definition: "conversation_summary_updated_at REAL")

            try ensureColumn(db, table: "messages", column: "requested_at", definition: "requested_at REAL")
            try ensureColumn(db, table: "messages", column: "content_versions_json", definition: "content_versions_json BLOB NOT NULL DEFAULT X'5B5D'")
            try ensureColumn(db, table: "messages", column: "current_version_index", definition: "current_version_index INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "messages", column: "reasoning_content", definition: "reasoning_content TEXT")
            try ensureColumn(db, table: "messages", column: "tool_calls_json", definition: "tool_calls_json BLOB")
            try ensureColumn(db, table: "messages", column: "tool_calls_placement", definition: "tool_calls_placement TEXT CHECK(tool_calls_placement IN ('afterReasoning', 'afterContent'))")
            try ensureColumn(db, table: "messages", column: "token_usage_json", definition: "token_usage_json BLOB")
            try ensureColumn(db, table: "messages", column: "audio_file_name", definition: "audio_file_name TEXT")
            try ensureColumn(db, table: "messages", column: "image_file_names_json", definition: "image_file_names_json BLOB")
            try ensureColumn(db, table: "messages", column: "file_file_names_json", definition: "file_file_names_json BLOB")
            try ensureColumn(db, table: "messages", column: "full_error_content", definition: "full_error_content TEXT")
            try ensureColumn(db, table: "messages", column: "response_metrics_json", definition: "response_metrics_json BLOB")
            try ensureColumn(db, table: "messages", column: "response_group_id", definition: "response_group_id TEXT")
            try ensureColumn(db, table: "messages", column: "response_attempt_id", definition: "response_attempt_id TEXT")
            try ensureColumn(db, table: "messages", column: "response_attempt_index", definition: "response_attempt_index INTEGER")
            try ensureColumn(db, table: "messages", column: "selected_response_attempt_id", definition: "selected_response_attempt_id TEXT")
            try ensureColumn(db, table: "messages", column: "position", definition: "position INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "messages", column: "created_at", definition: "created_at REAL NOT NULL DEFAULT 0")

            try ensureColumn(db, table: "request_logs", column: "session_id", definition: "session_id TEXT")
            try ensureColumn(db, table: "request_logs", column: "provider_id", definition: "provider_id TEXT")
            try ensureColumn(db, table: "request_logs", column: "requested_at", definition: "requested_at REAL NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "finished_at", definition: "finished_at REAL NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "is_streaming", definition: "is_streaming INTEGER NOT NULL DEFAULT 0")
            try ensureColumn(db, table: "request_logs", column: "status", definition: "status TEXT NOT NULL DEFAULT 'failed'")
            try ensureColumn(db, table: "request_logs", column: "token_usage_json", definition: "token_usage_json BLOB")

            try ensureColumn(db, table: "session_folders", column: "parent_id", definition: "parent_id TEXT")
            try ensureColumn(db, table: "session_folders", column: "updated_at", definition: "updated_at REAL NOT NULL DEFAULT 0")

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_sort ON sessions(sort_index ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_sessions_updated_at ON sessions(updated_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_position ON messages(session_id, position ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session_requested ON messages(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_requested_at ON request_logs(requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_session_id ON request_logs(session_id, requested_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_request_logs_provider_model ON request_logs(provider_name, model_id, requested_at DESC)")
            try ensureMessagesFTSObjects(db)
        }
    }

    func createCoreTablesIfMissing(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                topic_prompt TEXT,
                enhanced_prompt TEXT,
                folder_id TEXT,
                lorebook_ids_json BLOB NOT NULL DEFAULT X'5B5D',
                worldbook_context_isolation_enabled INTEGER NOT NULL DEFAULT 0,
                is_temporary INTEGER NOT NULL DEFAULT 0,
                sort_index INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL DEFAULT 0,
                conversation_summary TEXT,
                conversation_summary_updated_at REAL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                role TEXT NOT NULL CHECK(role IN ('system', 'user', 'assistant', 'tool', 'error')),
                requested_at REAL,
                content TEXT NOT NULL,
                content_versions_json BLOB NOT NULL DEFAULT X'5B5D',
                current_version_index INTEGER NOT NULL DEFAULT 0,
                reasoning_content TEXT,
                tool_calls_json BLOB,
                tool_calls_placement TEXT CHECK(tool_calls_placement IN ('afterReasoning', 'afterContent')),
                token_usage_json BLOB,
                audio_file_name TEXT,
                image_file_names_json BLOB,
                file_file_names_json BLOB,
                full_error_content TEXT,
                response_metrics_json BLOB,
                response_group_id TEXT,
                response_attempt_id TEXT,
                response_attempt_index INTEGER,
                selected_response_attempt_id TEXT,
                position INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL DEFAULT 0
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session_folders (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                parent_id TEXT,
                updated_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS request_logs (
                id TEXT PRIMARY KEY NOT NULL,
                request_id TEXT NOT NULL,
                session_id TEXT,
                provider_id TEXT,
                provider_name TEXT NOT NULL,
                model_id TEXT NOT NULL,
                requested_at REAL NOT NULL DEFAULT 0,
                finished_at REAL NOT NULL DEFAULT 0,
                is_streaming INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'failed',
                token_usage_json BLOB
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS json_blobs (
                key TEXT PRIMARY KEY NOT NULL,
                json_data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
    }

    func ensureMessagesFTSObjects(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
            USING fts5(
                message_id UNINDEXED,
                session_id UNINDEXED,
                content,
                tokenize = 'unicode61'
            )
        """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages
            BEGIN
                INSERT INTO messages_fts(message_id, session_id, content)
                VALUES (new.id, new.session_id, new.content);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages
            BEGIN
                DELETE FROM messages_fts WHERE message_id = old.id;
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages
            BEGIN
                DELETE FROM messages_fts WHERE message_id = old.id;
                INSERT INTO messages_fts(message_id, session_id, content)
                VALUES (new.id, new.session_id, new.content);
            END
        """)
    }

    func requireColumns(_ db: Database, table: String, columns: [String]) throws {
        let existing = try columnNames(db, table: table)
        for column in columns where !existing.contains(column) {
            throw NSError(domain: "PersistenceGRDBStore.SchemaRepair", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "数据库表 \(table) 缺少关键字段 \(column)，需要自动重建。"
            ])
        }
    }

    func ensureColumn(_ db: Database, table: String, column: String, definition: String) throws {
        guard !(try columnNames(db, table: table).contains(column)) else { return }
        try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(definition)")
        logger.info("已自动补齐数据库字段 \(table).\(column)。")
    }

    func columnNames(_ db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { row in
            let name: String? = row["name"]
            return name
        })
    }

    func scheduleDatabaseMaintenanceIfNeeded() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let delay = DatabaseMaintenanceLaunchDeferral.delayNanoseconds
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            self.runDatabaseMaintenanceIfNeeded()
        }
    }

    func runDatabaseMaintenanceIfNeeded() {
        do {
            try self.dbPool.barrierWriteWithoutTransaction { db in
                let autoVacuumMode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
                if autoVacuumMode != 2 {
                    try db.execute(sql: "PRAGMA auto_vacuum=INCREMENTAL")
                    try db.execute(sql: "VACUUM")
                    self.logger.info("主数据库已升级为 auto_vacuum=INCREMENTAL，并完成一次 VACUUM。")
                }

                let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                guard pageCount > 0 else { return }

                let freeRatio = Double(freelistCount) / Double(pageCount)
                let shouldVacuum = freelistCount >= Self.incrementalVacuumTriggerPages
                    || freeRatio >= Self.incrementalVacuumTriggerRatio
                guard shouldVacuum, freelistCount > 0 else { return }

                let vacuumPages = min(freelistCount, Self.incrementalVacuumBatchPages)
                _ = try? db.checkpoint(.passive)
                try db.execute(sql: "PRAGMA incremental_vacuum(\(vacuumPages))")

                let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
                let reclaimedMB = Double(vacuumPages * pageSize) / (1024 * 1024)
                let reclaimedText = String(format: "%.2f", reclaimedMB)
                self.logger.info("主数据库已执行增量回收，回收页数=\(vacuumPages)，预计回收=\(reclaimedText)MB。")
            }
        } catch {
            self.logger.warning("主数据库维护任务执行失败: \(error.localizedDescription)")
        }
    }

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

    func importLegacySupplementaryArtifacts() throws {
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

    func mergeLegacySessionSnapshotIntoDatabase(_ snapshot: LegacySessionSnapshot) throws -> Int {
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

    func loadLegacySessionSnapshot(from plan: LegacySessionImportPlan) throws -> LegacySessionSnapshot {
        if let recordURL = plan.sessionRecordURL,
           let record: LegacySessionRecordFile = decodeFile(LegacySessionRecordFile.self, at: recordURL) {
            let session = ChatSession(
                id: record.session.id,
                name: record.session.name.isEmpty ? plan.fallbackSession.name : record.session.name,
                topicPrompt: record.prompts.topicPrompt,
                enhancedPrompt: record.prompts.enhancedPrompt,
                lorebookIDs: record.session.lorebookIDs,
                worldbookContextIsolationEnabled: record.session.worldbookContextIsolationEnabled ?? false,
                folderID: record.session.folderID,
                isTemporary: false
            )
            let summary = record.session.conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSummary = (summary?.isEmpty == false) ? summary : nil
            let summaryUpdatedAt = parseISO8601Date(record.session.conversationSummaryUpdatedAt)
            return LegacySessionSnapshot(
                session: session,
                messages: normalizeToolCallsPlacement(in: record.messages),
                sortIndex: plan.sortIndex,
                updatedAt: plan.fallbackUpdatedAt,
                conversationSummary: normalizedSummary,
                conversationSummaryUpdatedAt: summaryUpdatedAt
            )
        }

        if let recordURL = plan.sessionRecordURL, plan.legacyMessagesURL == nil {
            logger.error("旧版会话文件解析失败，且没有可回退的消息文件: \(recordURL.path, privacy: .public)")
            throw LegacyIncrementalImportError.malformedSessionRecord(sessionID: plan.id, path: recordURL.path)
        }

        if let recordURL = plan.sessionRecordURL, plan.legacyMessagesURL != nil {
            logger.warning("旧版会话文件解析失败，将回退到旧版消息文件: \(recordURL.path, privacy: .public)")
        }

        let messages = try readLegacyMessagesFromURL(plan.legacyMessagesURL, sessionID: plan.id)
        return LegacySessionSnapshot(
            session: plan.fallbackSession,
            messages: messages,
            sortIndex: plan.sortIndex,
            updatedAt: plan.fallbackUpdatedAt,
            conversationSummary: nil,
            conversationSummaryUpdatedAt: nil
        )
    }

    func buildLegacyImportPlan() -> LegacyImportPlan {
        let sessionPlans = buildLegacySessionImportPlans()
        let sessionIDsForCleanup = sessionPlans.map(\.id)
        let candidateSet = Set(
            legacyJSONArtifactURLs(sessionIDs: sessionIDsForCleanup)
            + legacyRootMessageJSONFiles()
            + sessionPlans.compactMap(\.sessionRecordURL)
            + sessionPlans.compactMap(\.legacyMessagesURL)
        )
        let existingCandidates = candidateSet.filter { FileManager.default.fileExists(atPath: $0.path) }
        let estimatedBytes = existingCandidates.reduce(into: Int64(0)) { partialResult, url in
            partialResult += fileSize(at: url)
        }
        return LegacyImportPlan(
            sessionPlans: sessionPlans,
            sessionIDsForCleanup: sessionIDsForCleanup,
            estimatedBytes: estimatedBytes,
            candidateURLs: Array(existingCandidates)
        )
    }

    func buildLegacySessionImportPlans() -> [LegacySessionImportPlan] {
        if let index: LegacySessionIndexFile = decodeFile(
            LegacySessionIndexFile.self,
            at: chatsDirectory.appendingPathComponent("index.json")
        ) {
            let sessionsDirectory = chatsDirectory.appendingPathComponent("sessions")
            return index.sessions.enumerated().map { position, item in
                let recordURL = sessionsDirectory.appendingPathComponent("\(item.id.uuidString).json")
                let legacyMessagesURL = chatsDirectory.appendingPathComponent("\(item.id.uuidString).json")
                let fallbackSession = ChatSession(id: item.id, name: item.name, isTemporary: false)
                let fallbackUpdatedAt = parseISO8601Date(item.updatedAt) ?? Date()
                let estimatedBytes = fileSize(at: recordURL) + fileSize(at: legacyMessagesURL)
                return LegacySessionImportPlan(
                    id: item.id,
                    fallbackSession: fallbackSession,
                    sortIndex: position,
                    fallbackUpdatedAt: fallbackUpdatedAt,
                    sessionRecordURL: FileManager.default.fileExists(atPath: recordURL.path) ? recordURL : nil,
                    legacyMessagesURL: FileManager.default.fileExists(atPath: legacyMessagesURL.path) ? legacyMessagesURL : nil,
                    estimatedBytes: estimatedBytes
                )
            }
        }

        if let sessions: [ChatSession] = decodeFile(
            [ChatSession].self,
            at: chatsDirectory.appendingPathComponent("sessions.json")
        ) {
            return sessions
                .filter { !$0.isTemporary }
                .enumerated()
                .map { position, session in
                    let legacyMessagesURL = chatsDirectory.appendingPathComponent("\(session.id.uuidString).json")
                    return LegacySessionImportPlan(
                        id: session.id,
                        fallbackSession: session,
                        sortIndex: position,
                        fallbackUpdatedAt: Date(),
                        sessionRecordURL: nil,
                        legacyMessagesURL: FileManager.default.fileExists(atPath: legacyMessagesURL.path) ? legacyMessagesURL : nil,
                        estimatedBytes: fileSize(at: legacyMessagesURL)
                    )
                }
        }

        let orphanMessageFiles = legacyRootMessageJSONFiles()
        return orphanMessageFiles.enumerated().compactMap { position, url in
            let baseName = url.deletingPathExtension().lastPathComponent
            guard let sessionID = UUID(uuidString: baseName) else { return nil }
            let fallbackSession = ChatSession(id: sessionID, name: "历史会话", isTemporary: false)
            return LegacySessionImportPlan(
                id: sessionID,
                fallbackSession: fallbackSession,
                sortIndex: position,
                fallbackUpdatedAt: Date(),
                sessionRecordURL: nil,
                legacyMessagesURL: url,
                estimatedBytes: fileSize(at: url)
            )
        }
    }

    func readLegacyMessagesFromURL(_ url: URL?, sessionID: UUID) throws -> [ChatMessage] {
        guard let url else { return [] }
        if let envelope: ChatMessagesFileEnvelope = decodeFile(ChatMessagesFileEnvelope.self, at: url) {
            return normalizeToolCallsPlacement(in: envelope.messages)
        }
        if let messages: [ChatMessage] = decodeFile([ChatMessage].self, at: url) {
            return normalizeToolCallsPlacement(in: messages)
        }
        logger.error("旧版消息文件解析失败: \(url.path, privacy: .public)")
        throw LegacyIncrementalImportError.malformedMessagesFile(sessionID: sessionID, path: url.path)
    }

    func fileSize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let rawSize = attributes[.size] as? NSNumber else {
            return 0
        }
        return rawSize.int64Value
    }

}

import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    func importLegacyJSONIfNeeded() throws {
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

    func totalMessageCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
    }

    func collectLegacySnapshot() -> LegacySnapshot {
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

    func mergeLegacySnapshotIntoDatabase(_ snapshot: LegacySnapshot) throws {
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

    func isLegacySnapshotImported(_ snapshot: LegacySnapshot) throws -> Bool {
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

    func canRepairIncompleteImport(_ snapshot: LegacySnapshot) throws -> Bool {
        guard !snapshot.sessions.isEmpty else { return false }
        let snapshotSessionIDs = Set(snapshot.sessions.map { $0.session.id.uuidString })
        return try dbPool.read { db in
            let dbSessionIDs = Set(try String.fetchAll(db, sql: "SELECT id FROM sessions"))
            guard !dbSessionIDs.isEmpty else { return false }
            return dbSessionIDs.isSubset(of: snapshotSessionIDs)
        }
    }

    func readBlob<T: Decodable>(_ db: Database, type: T.Type, key: String) throws -> T? {
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

    func hasLegacyJSONArtifacts(sessionIDs: [UUID]) -> Bool {
        let fileManager = FileManager.default
        let candidates = legacyJSONArtifactURLs(sessionIDs: sessionIDs) + legacyRootMessageJSONFiles()
        return candidates.contains { fileManager.fileExists(atPath: $0.path) }
    }

    func removeLegacyJSONArtifacts(sessionIDs: [UUID]) -> Bool {
        let fileManager = FileManager.default
        let candidates = legacyJSONArtifactURLs(sessionIDs: sessionIDs) + legacyRootMessageJSONFiles()
        var failedPaths: [String] = []

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failedPaths.append(url.path)
                logger.warning("清理旧 JSON 文件失败: \(url.path) - \(error.localizedDescription)")
            }
        }

        removeDirectoryIfEmpty(chatsDirectory.appendingPathComponent("RequestLogs"))
        removeDirectoryIfEmpty(chatsDirectory.appendingPathComponent("DailyPulse"))

        if !failedPaths.isEmpty {
            return false
        }
        return !hasLegacyJSONArtifacts(sessionIDs: sessionIDs)
    }

    func legacyJSONArtifactURLs(sessionIDs: [UUID]) -> [URL] {
        var urls: [URL] = [
            chatsDirectory.appendingPathComponent("index.json"),
            chatsDirectory.appendingPathComponent("sessions"),
            chatsDirectory.appendingPathComponent("sessions.json"),
            chatsDirectory.appendingPathComponent("folders.json"),
            chatsDirectory.appendingPathComponent("RequestLogs").appendingPathComponent("index.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("runs.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("feedback-history.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("pending-curation.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("external-signals.json"),
            chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("tasks.json"),
            chatsDirectory.appendingPathComponent("v3"),
            chatsDirectory.appendingPathComponent("legacy")
        ]

        urls.append(contentsOf: sessionIDs.map { chatsDirectory.appendingPathComponent("\($0.uuidString).json") })
        return urls
    }

    func legacyRootMessageJSONFiles() -> [URL] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: chatsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.filter { url in
            guard url.pathExtension.lowercased() == "json" else { return false }
            let name = url.deletingPathExtension().lastPathComponent
            return UUID(uuidString: name) != nil
        }
    }

    func hasUnindexedLegacySessionArtifacts() -> Bool {
        if !legacyRootMessageJSONFiles().isEmpty {
            return true
        }

        let fileManager = FileManager.default
        let candidateDirectories = [
            chatsDirectory.appendingPathComponent("sessions", isDirectory: true),
            chatsDirectory.appendingPathComponent("v3", isDirectory: true).appendingPathComponent("sessions", isDirectory: true)
        ]

        for directoryURL in candidateDirectories {
            guard fileManager.fileExists(atPath: directoryURL.path),
                  let fileURLs = try? fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            if fileURLs.contains(where: { $0.pathExtension.lowercased() == "json" }) {
                return true
            }
        }

        return false
    }

    func removeDirectoryIfEmpty(_ directoryURL: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        guard let children = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        guard children.isEmpty else { return }
        try? fileManager.removeItem(at: directoryURL)
    }

    func readCurrentLayoutSessions() -> [LegacySessionSnapshot]? {
        let indexURL = chatsDirectory.appendingPathComponent("index.json")
        guard let index: LegacySessionIndexFile = decodeFile(LegacySessionIndexFile.self, at: indexURL) else {
            return nil
        }

        let sessionsDirectory = chatsDirectory.appendingPathComponent("sessions")
        var snapshots: [LegacySessionSnapshot] = []
        snapshots.reserveCapacity(index.sessions.count)

        for (indexPosition, item) in index.sessions.enumerated() {
            let sessionFileURL = sessionsDirectory.appendingPathComponent("\(item.id.uuidString).json")
            let fallbackUpdatedAt = parseISO8601Date(item.updatedAt) ?? Date()

            if let record: LegacySessionRecordFile = decodeFile(LegacySessionRecordFile.self, at: sessionFileURL) {
                let session = ChatSession(
                    id: record.session.id,
                    name: record.session.name.isEmpty ? item.name : record.session.name,
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

                snapshots.append(
                    LegacySessionSnapshot(
                        session: session,
                        messages: normalizeToolCallsPlacement(in: record.messages),
                        sortIndex: indexPosition,
                        updatedAt: fallbackUpdatedAt,
                        conversationSummary: normalizedSummary,
                        conversationSummaryUpdatedAt: summaryUpdatedAt
                    )
                )
            } else {
                let fallbackSession = ChatSession(id: item.id, name: item.name, isTemporary: false)
                snapshots.append(
                    LegacySessionSnapshot(
                        session: fallbackSession,
                        messages: readLegacyMessages(for: item.id),
                        sortIndex: indexPosition,
                        updatedAt: fallbackUpdatedAt,
                        conversationSummary: nil,
                        conversationSummaryUpdatedAt: nil
                    )
                )
            }
        }

        return snapshots
    }

    func readLegacyLayoutSessions() -> [LegacySessionSnapshot] {
        let legacySessionsURL = chatsDirectory.appendingPathComponent("sessions.json")
        guard let sessions: [ChatSession] = decodeFile([ChatSession].self, at: legacySessionsURL) else {
            return []
        }

        let normalizedSessions = sessions.filter { !$0.isTemporary }
        return normalizedSessions.enumerated().map { index, session in
            LegacySessionSnapshot(
                session: session,
                messages: readLegacyMessages(for: session.id),
                sortIndex: index,
                updatedAt: Date(),
                conversationSummary: nil,
                conversationSummaryUpdatedAt: nil
            )
        }
    }

    func readLegacyMessages(for sessionID: UUID) -> [ChatMessage] {
        let legacyURL = chatsDirectory.appendingPathComponent("\(sessionID.uuidString).json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return []
        }

        if let envelope: ChatMessagesFileEnvelope = decodeFile(ChatMessagesFileEnvelope.self, at: legacyURL) {
            return normalizeToolCallsPlacement(in: envelope.messages)
        }
        if let messages: [ChatMessage] = decodeFile([ChatMessage].self, at: legacyURL) {
            return normalizeToolCallsPlacement(in: messages)
        }
        return []
    }

    func readSessionFolders() -> [SessionFolder] {
        let url = chatsDirectory.appendingPathComponent("folders.json")
        if let envelope: SessionFoldersFileEnvelope = decodeFile(SessionFoldersFileEnvelope.self, at: url) {
            return normalizeSessionFoldersForPersistence(envelope.folders)
        }
        return []
    }

    func readRequestLogs() -> [RequestLogEntry] {
        let url = chatsDirectory.appendingPathComponent("RequestLogs").appendingPathComponent("index.json")
        if let envelope: RequestLogFileEnvelope = decodeFile(RequestLogFileEnvelope.self, at: url) {
            return envelope.logs
        }
        return []
    }

    func readDailyPulseRuns() -> [DailyPulseRun] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("runs.json")
        return decodeFile([DailyPulseRun].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    func readDailyPulseFeedbackHistory() -> [DailyPulseFeedbackEvent] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("feedback-history.json")
        return decodeFile([DailyPulseFeedbackEvent].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    func readDailyPulsePendingCuration() -> DailyPulseCurationNote? {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("pending-curation.json")
        return decodeFile(DailyPulseCurationNote.self, at: url, decoder: makeISO8601Decoder())
    }

    func readDailyPulseExternalSignals() -> [DailyPulseExternalSignal] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("external-signals.json")
        return decodeFile([DailyPulseExternalSignal].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    func readDailyPulseTasks() -> [DailyPulseTask] {
        let url = chatsDirectory.appendingPathComponent("DailyPulse").appendingPathComponent("tasks.json")
        return decodeFile([DailyPulseTask].self, at: url, decoder: makeISO8601Decoder()) ?? []
    }

    func ensureSessionExists(_ db: Database, sessionID: UUID) throws {
        let exists = try (Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sessions WHERE id = ?",
            arguments: [sessionID.uuidString]
        ) ?? 0) > 0

        guard !exists else { return }

        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
            INSERT INTO sessions (
                id, name, topic_prompt, enhanced_prompt, folder_id, lorebook_ids_json,
                worldbook_context_isolation_enabled, is_temporary, sort_index, updated_at,
                conversation_summary, conversation_summary_updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                sessionID.uuidString,
                "新的对话",
                nil,
                nil,
                nil,
                encodeJSON([UUID]()) ?? Data("[]".utf8),
                0,
                1,
                Int.max / 2,
                now,
                nil,
                nil
            ]
        )
    }

    func upsertSession(
        _ db: Database,
        session: ChatSession,
        sortIndex: Int,
        updatedAt: Date,
        conversationSummary: String?,
        conversationSummaryUpdatedAt: Date?,
        preserveExistingSummary: Bool
    ) throws {
        let lorebookData = encodeJSON(session.lorebookIDs) ?? Data("[]".utf8)
        let normalizedSummary = conversationSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (normalizedSummary?.isEmpty == false) ? normalizedSummary : nil
        let summaryUpdated = summary == nil ? nil : conversationSummaryUpdatedAt?.timeIntervalSince1970

        if preserveExistingSummary {
            try db.execute(
                sql: """
                INSERT INTO sessions (
                    id, name, topic_prompt, enhanced_prompt, folder_id, lorebook_ids_json,
                    worldbook_context_isolation_enabled, is_temporary, sort_index, updated_at,
                    conversation_summary, conversation_summary_updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    topic_prompt = excluded.topic_prompt,
                    enhanced_prompt = excluded.enhanced_prompt,
                    folder_id = excluded.folder_id,
                    lorebook_ids_json = excluded.lorebook_ids_json,
                    worldbook_context_isolation_enabled = excluded.worldbook_context_isolation_enabled,
                    is_temporary = excluded.is_temporary,
                    sort_index = excluded.sort_index,
                    updated_at = excluded.updated_at,
                    conversation_summary = COALESCE(sessions.conversation_summary, excluded.conversation_summary),
                    conversation_summary_updated_at = COALESCE(sessions.conversation_summary_updated_at, excluded.conversation_summary_updated_at)
                """,
                arguments: [
                    session.id.uuidString,
                    session.name,
                    session.topicPrompt,
                    session.enhancedPrompt,
                    session.folderID?.uuidString,
                    lorebookData,
                    session.worldbookContextIsolationEnabled ? 1 : 0,
                    session.isTemporary ? 1 : 0,
                    sortIndex,
                    updatedAt.timeIntervalSince1970,
                    summary,
                    summaryUpdated
                ]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO sessions (
                    id, name, topic_prompt, enhanced_prompt, folder_id, lorebook_ids_json,
                    worldbook_context_isolation_enabled, is_temporary, sort_index, updated_at,
                    conversation_summary, conversation_summary_updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    topic_prompt = excluded.topic_prompt,
                    enhanced_prompt = excluded.enhanced_prompt,
                    folder_id = excluded.folder_id,
                    lorebook_ids_json = excluded.lorebook_ids_json,
                    worldbook_context_isolation_enabled = excluded.worldbook_context_isolation_enabled,
                    is_temporary = excluded.is_temporary,
                    sort_index = excluded.sort_index,
                    updated_at = excluded.updated_at,
                    conversation_summary = excluded.conversation_summary,
                    conversation_summary_updated_at = excluded.conversation_summary_updated_at
                """,
                arguments: [
                    session.id.uuidString,
                    session.name,
                    session.topicPrompt,
                    session.enhancedPrompt,
                    session.folderID?.uuidString,
                    lorebookData,
                    session.worldbookContextIsolationEnabled ? 1 : 0,
                    session.isTemporary ? 1 : 0,
                    sortIndex,
                    updatedAt.timeIntervalSince1970,
                    summary,
                    summaryUpdated
                ]
            )
        }
    }

    func fetchPersistedMessageRecords(
        _ db: Database,
        sessionID: UUID
    ) throws -> [String: PersistedMessageRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, session_id, role, requested_at, content, content_versions_json,
                   current_version_index, reasoning_content, tool_calls_json, tool_calls_placement,
                   token_usage_json, audio_file_name, image_file_names_json, file_file_names_json,
                   full_error_content, response_metrics_json,
                   response_group_id, response_attempt_id, response_attempt_index, selected_response_attempt_id,
                   position, created_at
            FROM messages
            WHERE session_id = ?
            """,
            arguments: [sessionID.uuidString]
        )

        var records: [String: PersistedMessageRecord] = [:]
        records.reserveCapacity(rows.count)
        for row in rows {
            let record = PersistedMessageRecord(
                id: row["id"],
                sessionID: row["session_id"],
                role: row["role"],
                requestedAt: row["requested_at"],
                content: row["content"],
                contentVersionsJSON: row["content_versions_json"],
                currentVersionIndex: row["current_version_index"],
                reasoningContent: row["reasoning_content"],
                toolCallsJSON: row["tool_calls_json"],
                toolCallsPlacement: row["tool_calls_placement"],
                tokenUsageJSON: row["token_usage_json"],
                audioFileName: row["audio_file_name"],
                imageFileNamesJSON: row["image_file_names_json"],
                fileFileNamesJSON: row["file_file_names_json"],
                fullErrorContent: row["full_error_content"],
                responseMetricsJSON: row["response_metrics_json"],
                responseGroupID: row["response_group_id"],
                responseAttemptID: row["response_attempt_id"],
                responseAttemptIndex: row["response_attempt_index"],
                selectedResponseAttemptID: row["selected_response_attempt_id"],
                position: row["position"],
                createdAt: row["created_at"]
            )
            records[record.id] = record
        }
        return records
    }

}

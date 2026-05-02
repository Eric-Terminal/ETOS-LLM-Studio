import Foundation
import os.log

extension Persistence {
    // MARK: - 目录管理

    /// 获取用于存储聊天记录的目录URL
    /// - Returns: 存储目录的URL路径
    public static func getChatsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let chatsDirectory = paths[0].appendingPathComponent("ChatSessions")
        if !FileManager.default.fileExists(atPath: chatsDirectory.path) {
            logger.info("Chat history directory does not exist, creating: \(chatsDirectory.path)")
            try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
        }
        return chatsDirectory
    }

    // MARK: - 会话持久化

    /// 保存所有聊天会话的列表
    public static func saveChatSessions(_ sessions: [ChatSession]) {
        if let store = activeGRDBStore() {
            store.saveChatSessions(sessions)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let sessionsToSave = sessions.filter { !$0.isTemporary }
        logger.info("准备保存 \(sessionsToSave.count) 个会话到会话索引。")

        do {
            for session in sessionsToSave {
                try ensureSessionRecordMetadataUpToDate(for: session)
            }

            let now = iso8601Timestamp()
            let index = SessionIndexFilePayload(
                schemaVersion: sessionStoreSchemaVersion,
                updatedAt: now,
                sessions: sessionsToSave.map { session in
                    SessionIndexItemPayload(
                        id: session.id,
                        name: session.name,
                        updatedAt: now
                    )
                }
            )
            try writeSessionIndexFile(index)
            logger.info("会话索引保存成功。")
        } catch {
            logger.error("保存会话索引失败: \(error.localizedDescription)")
        }
    }

    /// 加载所有聊天会话的列表
    public static func loadChatSessions() -> [ChatSession] {
        if let store = activeGRDBStore() {
            return store.loadChatSessions()
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()
        logCompatibilityReminderIfNeeded(trigger: "loadChatSessions")

        if let sessions = loadChatSessionsFromIndexedFiles() {
            logger.info("已从会话索引加载 \(sessions.count) 个会话。")
            cleanupLegacyArtifactsIfPossible()
            return sessions
        }

        let legacySessions = loadLegacySessions()
        guard !legacySessions.isEmpty else {
            logger.info("未检测到可用会话索引，返回空会话列表。")
            return []
        }

        logger.info("\(migrationLogPrefix) 检测到旧版会话索引，开始全量迁移。")
        do {
            try migrateLegacyStoreToIndexedFiles(legacySessions: legacySessions)
            if let migratedSessions = loadChatSessionsFromIndexedFiles() {
                logger.info("\(migrationLogPrefix) 已完成迁移，加载到 \(migratedSessions.count) 个会话。")
                cleanupLegacyArtifactsIfPossible()
                return migratedSessions
            }
            logger.warning("\(migrationLogPrefix) 迁移后未读取到会话索引，回退返回旧会话列表。")
            return legacySessions
        } catch {
            logger.error("\(migrationLogPrefix) 迁移失败，回退旧会话列表: \(error.localizedDescription)")
            return legacySessions
        }
    }

    // MARK: - 会话文件夹持久化

    /// 保存会话文件夹列表。
    public static func saveSessionFolders(_ folders: [SessionFolder]) {
        if let store = activeGRDBStore() {
            store.saveSessionFolders(folders)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let normalizedFolders = normalizeSessionFoldersForPersistence(folders)
        let envelope = SessionFoldersFileEnvelope(
            schemaVersion: sessionFoldersFileSchemaVersion,
            updatedAt: iso8601Timestamp(),
            folders: normalizedFolders
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: sessionFoldersFileURL(), options: .atomic)
            logger.info("会话文件夹保存成功，共 \(normalizedFolders.count) 个。")
        } catch {
            logger.error("保存会话文件夹失败: \(error.localizedDescription)")
        }
    }

    /// 加载会话文件夹列表。
    public static func loadSessionFolders() -> [SessionFolder] {
        if let store = activeGRDBStore() {
            return store.loadSessionFolders()
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        let fileURL = sessionFoldersFileURL()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let envelope = try JSONDecoder().decode(SessionFoldersFileEnvelope.self, from: data)
            let normalizedFolders = normalizeSessionFoldersForPersistence(envelope.folders)
            let shouldRewrite = envelope.schemaVersion != sessionFoldersFileSchemaVersion
                || normalizedFolders != envelope.folders
            if shouldRewrite {
                saveSessionFolders(normalizedFolders)
            }
            return normalizedFolders
        } catch {
            logger.warning("读取会话文件夹失败: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 消息持久化

    /// 阻塞等待 GRDB 消息写队列清空，确保随后读取拿到最新消息快照。
    public static func flushPendingMessageWritesForSyncSnapshot() {
        activeGRDBStore()?.flushPendingMessageWrites()
    }

    public static func flushPendingMessageWritesForSyncSnapshotAsync() async {
        guard let store = activeGRDBStore() else { return }
        await store.flushPendingMessageWritesAsync()
    }

    /// 保存指定会话的聊天消息
    public static func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
        if let store = activeGRDBStore() {
            store.saveMessages(messages, for: sessionID)
            return
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()

        do {
            let normalized = normalizeToolCallsPlacement(in: messages, sessionID: sessionID)
            let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
            let record = makeSessionRecordPayload(session: sessionSnapshot, messages: normalized.messages)
            try writeSessionRecordFile(record, for: sessionID)
            logger.info("会话 \(sessionID.uuidString) 的消息已保存到会话存储（\(normalized.messages.count) 条）。")
        } catch {
            logger.error("保存会话 \(sessionID.uuidString) 消息失败: \(error.localizedDescription)")
        }
    }

    /// 加载指定会话的聊天消息
    public static func loadMessages(for sessionID: UUID) -> [ChatMessage] {
        if let store = activeGRDBStore() {
            return store.loadMessages(for: sessionID)
        }

        migrateLegacySessionDirectoryToCurrentLayoutIfNeeded()
        logCompatibilityReminderIfNeeded(trigger: "loadMessages")

        if let loadedMessages = loadMessagesFromIndexedFiles(for: sessionID) {
            logger.info("会话 \(sessionID.uuidString) 已从会话存储加载 \(loadedMessages.count) 条消息。")
            cleanupLegacyArtifactsIfPossible()
            return loadedMessages
        }

        let legacyURL = legacyMessagesFileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            logger.warning("未找到会话 \(sessionID.uuidString) 的消息文件，返回空列表。")
            return []
        }

        logger.info("\(migrationLogPrefix) 检测到旧版消息文件，开始迁移会话 \(sessionID.uuidString)。")
        do {
            let legacy = try readLegacyMessages(for: sessionID)
            let sessionSnapshot = resolveSessionSnapshot(for: sessionID)
            let record = makeSessionRecordPayload(session: sessionSnapshot, messages: legacy.messages)
            try writeSessionRecordFile(record, for: sessionID)
            try removeItemIfExists(at: legacyURL)
            cleanupLegacyArtifactsIfPossible()
            logger.info("\(migrationLogPrefix) 会话 \(sessionID.uuidString) 消息迁移完成，共 \(legacy.messages.count) 条。")
            return legacy.messages
        } catch {
            logger.warning("加载会话 \(sessionID.uuidString) 消息失败，返回空列表: \(error.localizedDescription)")
            return []
        }
    }

    /// 统计指定会话的消息数量。
    public static func loadMessageCount(for sessionID: UUID) -> Int {
        if let store = activeGRDBStore() {
            return store.loadMessageCount(for: sessionID)
        }
        return loadMessages(for: sessionID).count
    }

}

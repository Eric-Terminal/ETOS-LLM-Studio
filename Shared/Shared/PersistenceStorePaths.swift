// ============================================================================
// PersistenceStorePaths.swift
// ============================================================================
// ETOS LLM Studio
//
// Persistence 的目录、路径、时间戳、legacy 迁移与兼容提醒辅助。
// ============================================================================

import Foundation

extension Persistence {
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

    static func migrateLegacySessionDirectoryToCurrentLayoutIfNeeded() {
        let legacySessionDirectory = legacySessionDirectoryURL()
        guard FileManager.default.fileExists(atPath: legacySessionDirectory.path) else {
            return
        }

        let legacySessionIndex = legacySessionDirectoryIndexFileURL()
        let legacySessionRecordsDirectory = legacySessionRecordsDirectoryURL()
        let currentIndexURL = sessionIndexFileURLCurrent()
        let currentSessionsDirectory = currentSessionRecordsDirectory()

        do {
            try ensureDirectoryExists(currentSessionsDirectory)

            if FileManager.default.fileExists(atPath: legacySessionIndex.path) {
                if FileManager.default.fileExists(atPath: currentIndexURL.path) {
                    try mergeLegacySessionIndexIntoCurrentIfNeeded(
                        currentIndexURL: currentIndexURL,
                        legacyIndexURL: legacySessionIndex
                    )
                    try removeItemIfExists(at: legacySessionIndex)
                } else {
                    try moveItemIfExists(from: legacySessionIndex, to: currentIndexURL)
                }
            }

            if FileManager.default.fileExists(atPath: legacySessionRecordsDirectory.path) {
                let sessionFiles = try FileManager.default.contentsOfDirectory(
                    at: legacySessionRecordsDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )

                for sourceURL in sessionFiles where sourceURL.pathExtension.lowercased() == "json" {
                    let targetURL = currentSessionsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try removeItemIfExists(at: sourceURL)
                    } else {
                        try moveItemIfExists(from: sourceURL, to: targetURL)
                    }
                }
            }

            try removeItemIfExists(at: legacySessionDirectory)
            logger.info("\(migrationLogPrefix) 旧目录数据已迁移到 ChatSessions 根目录并清理完成。")
        } catch {
            logger.warning("\(migrationLogPrefix) 旧目录迁移失败: \(error.localizedDescription)")
        }
    }

    static func moveItemIfExists(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try ensureDirectoryExists(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    static func removeItemIfExists(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func removeSQLiteSidecars(at url: URL) {
        let fileManager = FileManager.default
        let walPath = url.path + "-wal"
        let shmPath = url.path + "-shm"
        if fileManager.fileExists(atPath: walPath) {
            try? fileManager.removeItem(atPath: walPath)
        }
        if fileManager.fileExists(atPath: shmPath) {
            try? fileManager.removeItem(atPath: shmPath)
        }
    }

    static func cleanupLegacyArtifactsIfPossible() {
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacySessionIndexFileURL().path)
        let hasLegacyMessages = hasLegacyMessageFiles()
        guard !hasLegacyIndex && !hasLegacyMessages else {
            return
        }

        let legacyArchiveURL = legacyArchiveDirectoryURL()
        guard FileManager.default.fileExists(atPath: legacyArchiveURL.path) else {
            return
        }

        do {
            try removeItemIfExists(at: legacyArchiveURL)
            logger.info("\(migrationLogPrefix) legacy 目录已自动清理。")
        } catch {
            logger.warning("\(migrationLogPrefix) 清理 legacy 目录失败: \(error.localizedDescription)")
        }
    }

    static func mergeLegacySessionIndexIntoCurrentIfNeeded(
        currentIndexURL: URL,
        legacyIndexURL: URL
    ) throws {
        let decoder = JSONDecoder()
        let currentData = try Data(contentsOf: currentIndexURL)
        let legacyData = try Data(contentsOf: legacyIndexURL)
        let currentIndex = try decoder.decode(SessionIndexFilePayload.self, from: currentData)
        let legacyIndex = try decoder.decode(SessionIndexFilePayload.self, from: legacyData)

        var existingIDs = Set(currentIndex.sessions.map(\.id))
        var mergedSessions = currentIndex.sessions
        for item in legacyIndex.sessions where !existingIDs.contains(item.id) {
            mergedSessions.append(item)
            existingIDs.insert(item.id)
        }

        guard mergedSessions.count != currentIndex.sessions.count else {
            return
        }

        let mergedIndex = SessionIndexFilePayload(
            schemaVersion: sessionStoreSchemaVersion,
            updatedAt: iso8601Timestamp(),
            sessions: mergedSessions
        )
        try writeSessionIndexFile(mergedIndex)
        logger.info("\(migrationLogPrefix) 已合并旧目录与当前会话索引，新增 \(mergedSessions.count - currentIndex.sessions.count) 个会话条目。")
    }

    static func logCompatibilityReminderIfNeeded(trigger: String) {
        compatibilityReminderLock.lock()
        defer { compatibilityReminderLock.unlock() }

        guard !hasLoggedCompatibilityReminder else { return }

        let hasCurrentIndex = FileManager.default.fileExists(atPath: sessionIndexFileURLCurrent().path)
        let hasLegacySessionDirectory = hasLegacySessionArtifacts()
        let hasLegacyIndex = FileManager.default.fileExists(atPath: legacySessionIndexFileURL().path)
        let hasLegacyMessages = hasLegacyMessageFiles()

        let legacyStatus: String
        if hasLegacySessionDirectory {
            legacyStatus = "检测到旧目录历史文件，将自动迁移到 ChatSessions 根目录。"
        } else if hasLegacyIndex || hasLegacyMessages {
            legacyStatus = "检测到 legacy 文件，已启用前向兼容读取。"
        } else {
            legacyStatus = "当前未检测到旧目录或 legacy 历史文件。"
        }

        logger.info("\(compatibilityReminderPrefix) 触发点=\(trigger)，存储状态: currentIndex=\(hasCurrentIndex), legacySessionDirectory=\(hasLegacySessionDirectory), legacyIndex=\(hasLegacyIndex), legacyMessages=\(hasLegacyMessages)。\(legacyStatus)")
        hasLoggedCompatibilityReminder = true
    }

    static func hasLegacySessionArtifacts() -> Bool {
        let legacySessionDirectory = legacySessionDirectoryURL()
        return FileManager.default.fileExists(atPath: legacySessionDirectory.path)
    }

    static func hasLegacyMessageFiles() -> Bool {
        let chatsDirectory = getChatsDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: chatsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return entries.contains { entry in
            let fileName = entry.lastPathComponent
            return fileName.range(of: "^[0-9A-Fa-f-]{36}\\.json$", options: .regularExpression) != nil
        }
    }

    static func ensureDirectoryExists(_ directoryURL: URL) throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    static func currentSessionRecordsDirectory() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(sessionRecordsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func requestLogsDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(requestLogsDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func dailyPulseDirectoryURL() -> URL {
        let directory = getChatsDirectory().appendingPathComponent(dailyPulseDirectoryName)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    static func sessionIndexFileURLCurrent() -> URL {
        getChatsDirectory().appendingPathComponent(sessionIndexFileName)
    }

    static func sessionFoldersFileURL() -> URL {
        getChatsDirectory().appendingPathComponent(sessionFoldersFileName)
    }

    static func requestLogsFileURL() -> URL {
        requestLogsDirectoryURL().appendingPathComponent(requestLogsFileName)
    }

    static func effectiveRequestLogRetentionLimit() -> Int {
        max(requestLogRetentionLimitOverride ?? defaultRequestLogRetentionLimit, 1)
    }

    static func dailyPulseRunsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseRunsFileName)
    }

    static func dailyPulseFeedbackHistoryFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseFeedbackHistoryFileName)
    }

    static func dailyPulsePendingCurationFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulsePendingCurationFileName)
    }

    static func dailyPulseExternalSignalsFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseExternalSignalsFileName)
    }

    static func dailyPulseTasksFileURL() -> URL {
        dailyPulseDirectoryURL().appendingPathComponent(dailyPulseTasksFileName)
    }

    static func sessionRecordFileURL(for sessionID: UUID) -> URL {
        currentSessionRecordsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    static func legacySessionDirectoryURL() -> URL {
        getChatsDirectory().appendingPathComponent(legacySessionDirectoryName)
    }

    static func legacySessionDirectoryIndexFileURL() -> URL {
        legacySessionDirectoryURL().appendingPathComponent(sessionIndexFileName)
    }

    static func legacySessionRecordsDirectoryURL() -> URL {
        legacySessionDirectoryURL().appendingPathComponent(sessionRecordsDirectoryName)
    }

    static func legacySessionRecordFileURL(for sessionID: UUID) -> URL {
        legacySessionRecordsDirectoryURL().appendingPathComponent("\(sessionID.uuidString).json")
    }

    static func legacySessionIndexFileURL() -> URL {
        getChatsDirectory().appendingPathComponent("sessions.json")
    }

    static func legacyMessagesFileURL(for sessionID: UUID) -> URL {
        getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    }

    static func legacyArchiveDirectoryURL() -> URL {
        getChatsDirectory().appendingPathComponent(legacyArchiveDirectoryName)
    }

    static func iso8601Timestamp() -> String {
        iso8601Timestamp(from: Date())
    }

    static func iso8601Timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

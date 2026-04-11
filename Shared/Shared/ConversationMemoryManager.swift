// ============================================================================
// ConversationMemoryManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责管理“跨对话记忆”：
// - 会话级摘要（存放在会话持久化存储中）
// - 用户画像（优先存放在 SQLite，失败时回退 Memory/user_profile.json）
// ============================================================================

import Foundation
import GRDB
import os.log

public struct ConversationSessionSummary: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let sessionName: String
    public let summary: String
    public let updatedAt: Date

    public init(sessionID: UUID, sessionName: String, summary: String, updatedAt: Date) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.summary = summary
        self.updatedAt = updatedAt
    }
}

public struct ConversationUserProfile: Codable, Hashable, Sendable {
    public let content: String
    public let updatedAt: Date
    public let sourceSessionID: UUID?

    public init(content: String, updatedAt: Date, sourceSessionID: UUID? = nil) {
        self.content = content
        self.updatedAt = updatedAt
        self.sourceSessionID = sourceSessionID
    }
}

public extension Notification.Name {
    static let conversationMemoryDidChange = Notification.Name("com.ETOS.LLM.Studio.conversationMemory.didChange")
}

public enum ConversationMemoryManager {
    private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConversationMemory")
    private static let profileStore = ConversationUserProfileStore()

    public static func loadRecentSessionSummaries(limit: Int, excludingSessionID: UUID? = nil) -> [ConversationSessionSummary] {
        let safeLimit = max(0, limit)
        guard safeLimit > 0 else { return [] }
        return Persistence.loadConversationSessionSummaries(limit: safeLimit, excludingSessionID: excludingSessionID)
    }

    public static func loadAllSessionSummaries() -> [ConversationSessionSummary] {
        Persistence.loadConversationSessionSummaries(limit: nil, excludingSessionID: nil)
    }

    public static func loadSessionSummary(for sessionID: UUID) -> ConversationSessionSummary? {
        Persistence.loadConversationSessionSummary(for: sessionID)
    }

    public static func saveSessionSummary(sessionID: UUID, summary: String, updatedAt: Date = Date()) {
        Persistence.upsertConversationSessionSummary(summary, for: sessionID, updatedAt: updatedAt)
        NotificationCenter.default.post(name: .conversationMemoryDidChange, object: nil)
    }

    public static func removeSessionSummary(sessionID: UUID) {
        Persistence.clearConversationSessionSummary(for: sessionID)
        NotificationCenter.default.post(name: .conversationMemoryDidChange, object: nil)
    }

    @discardableResult
    public static func clearAllSessionSummaries() -> Int {
        let removed = Persistence.clearAllConversationSessionSummaries()
        if removed > 0 {
            NotificationCenter.default.post(name: .conversationMemoryDidChange, object: nil)
        }
        return removed
    }

    public static func loadUserProfile() -> ConversationUserProfile? {
        profileStore.loadProfile()
    }

    public static func saveUserProfile(content: String, updatedAt: Date = Date(), sourceSessionID: UUID? = nil) throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clearUserProfile()
            return
        }
        let profile = ConversationUserProfile(content: trimmed, updatedAt: updatedAt, sourceSessionID: sourceSessionID)
        try profileStore.saveProfile(profile)
        NotificationCenter.default.post(name: .conversationMemoryDidChange, object: nil)
    }

    public static func clearUserProfile() throws {
        do {
            try profileStore.clearProfile()
            NotificationCenter.default.post(name: .conversationMemoryDidChange, object: nil)
        } catch {
            logger.error("清理用户画像失败: \(error.localizedDescription)")
            throw error
        }
    }

    public static func shouldUpdateUserProfile(existingProfile: ConversationUserProfile?, on now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let existingProfile else { return true }
        return !calendar.isDate(existingProfile.updatedAt, inSameDayAs: now)
    }

    public static func shouldUpdateUserProfile(on now: Date = Date(), calendar: Calendar = .current) -> Bool {
        shouldUpdateUserProfile(existingProfile: loadUserProfile(), on: now, calendar: calendar)
    }
}

private struct ConversationUserProfileStore {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConversationUserProfileStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rootDirectory: URL?
    private let grdbBlobKey = "conversation_user_profile_v1"

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadProfile() -> ConversationUserProfile? {
        if canUseGRDB {
            let sqliteResult = loadProfileFromSQLite()
            if sqliteResult.didRead {
                return sqliteResult.profile
            }
        }

        let fileURL = MemoryStoragePaths.userProfileFileURL(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let profile = try decoder.decode(ConversationUserProfile.self, from: data)
            if canUseGRDB, saveProfileToSQLite(profile) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return profile
        } catch {
            logger.error("读取用户画像失败: \(error.localizedDescription)")
            return nil
        }
    }

    func saveProfile(_ profile: ConversationUserProfile) throws {
        if canUseGRDB, saveProfileToSQLite(profile) {
            let fileURL = MemoryStoragePaths.userProfileFileURL(rootDirectory: rootDirectory)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }

        MemoryStoragePaths.ensureRootDirectory(rootDirectory: rootDirectory)
        let fileURL = MemoryStoragePaths.userProfileFileURL(rootDirectory: rootDirectory)
        let data = try encoder.encode(profile)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
    }

    func clearProfile() throws {
        if canUseGRDB {
            _ = clearProfileFromSQLite()
            _ = Persistence.removeAuxiliaryBlob(forKey: grdbBlobKey)
        }
        let fileURL = MemoryStoragePaths.userProfileFileURL(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private var canUseGRDB: Bool {
        rootDirectory == nil
    }

    private func loadProfileFromSQLite() -> (didRead: Bool, profile: ConversationUserProfile?) {
        guard let profile = Persistence.withMemoryDatabaseRead({ db -> ConversationUserProfile? in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT content, updated_at, source_session_id
                FROM conversation_user_profile
                WHERE singleton_key = 1
                """
            ) else {
                return nil
            }

            let sourceSessionIDRaw: String? = row["source_session_id"]
            return ConversationUserProfile(
                content: row["content"],
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
                sourceSessionID: sourceSessionIDRaw.flatMap(UUID.init(uuidString:))
            )
        }) else {
            return (false, nil)
        }

        if profile == nil,
           Persistence.auxiliaryBlobExists(forKey: grdbBlobKey),
           let legacy = Persistence.loadAuxiliaryBlob(ConversationUserProfile.self, forKey: grdbBlobKey) {
            if saveProfileToSQLite(legacy) {
                _ = Persistence.removeAuxiliaryBlob(forKey: grdbBlobKey)
            }
            return (true, legacy)
        }

        return (true, profile)
    }

    @discardableResult
    private func saveProfileToSQLite(_ profile: ConversationUserProfile) -> Bool {
        let didSave = Persistence.withMemoryDatabaseWrite { db in
            try db.execute(
                sql: """
                INSERT INTO conversation_user_profile (singleton_key, content, updated_at, source_session_id)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(singleton_key) DO UPDATE SET
                    content = excluded.content,
                    updated_at = excluded.updated_at,
                    source_session_id = excluded.source_session_id
                """,
                arguments: [
                    profile.content,
                    profile.updatedAt.timeIntervalSince1970,
                    profile.sourceSessionID?.uuidString
                ]
            )
            return true
        } ?? false

        if didSave {
            _ = Persistence.removeAuxiliaryBlob(forKey: grdbBlobKey)
        }
        return didSave
    }

    @discardableResult
    private func clearProfileFromSQLite() -> Bool {
        Persistence.withMemoryDatabaseWrite { db in
            try db.execute(sql: "DELETE FROM conversation_user_profile WHERE singleton_key = 1")
            return true
        } ?? false
    }
}

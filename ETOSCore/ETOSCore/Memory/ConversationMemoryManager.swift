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

public enum ConversationProfileFactCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case identity
    case communication
    case expertise
    case interest
    case workStyle
    case goal
    case constraint
    case relationship
    case other

    public var localizedTitle: String {
        switch self {
        case .identity: return NSLocalizedString("身份背景", comment: "Profile fact category")
        case .communication: return NSLocalizedString("沟通偏好", comment: "Profile fact category")
        case .expertise: return NSLocalizedString("技能与专长", comment: "Profile fact category")
        case .interest: return NSLocalizedString("兴趣关注", comment: "Profile fact category")
        case .workStyle: return NSLocalizedString("工作方式", comment: "Profile fact category")
        case .goal: return NSLocalizedString("长期目标", comment: "Profile fact category")
        case .constraint: return NSLocalizedString("约束与边界", comment: "Profile fact category")
        case .relationship: return NSLocalizedString("长期关系", comment: "Profile fact category")
        case .other: return NSLocalizedString("其他", comment: "Profile fact category")
        }
    }
}

public struct ConversationProfileFact: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let category: ConversationProfileFactCategory
    public let statement: String
    public let confidence: Double
    public let evidenceCount: Int
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let sourceSessionIDs: [UUID]

    public init(
        id: UUID = UUID(),
        category: ConversationProfileFactCategory,
        statement: String,
        confidence: Double = 1,
        evidenceCount: Int = 1,
        firstObservedAt: Date = Date(),
        lastObservedAt: Date = Date(),
        sourceSessionIDs: [UUID] = []
    ) {
        self.id = id
        self.category = category
        self.statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = min(max(confidence, 0), 1)
        self.evidenceCount = max(1, evidenceCount)
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.sourceSessionIDs = Array(Set(sourceSessionIDs)).sorted { $0.uuidString < $1.uuidString }
    }
}

public struct ConversationUserProfile: Codable, Hashable, Sendable {
    public let content: String
    public let updatedAt: Date
    public let sourceSessionID: UUID?
    public let needsLLMDedup: Bool
    public let facts: [ConversationProfileFact]
    public let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case content
        case updatedAt
        case sourceSessionID
        case needsLLMDedup
        case facts
        case schemaVersion
    }

    public init(
        content: String,
        updatedAt: Date,
        sourceSessionID: UUID? = nil,
        needsLLMDedup: Bool = false,
        facts: [ConversationProfileFact] = [],
        schemaVersion: Int = 2
    ) {
        self.content = content
        self.updatedAt = updatedAt
        self.sourceSessionID = sourceSessionID
        self.needsLLMDedup = needsLLMDedup
        self.facts = facts.filter { !$0.statement.isEmpty }
        self.schemaVersion = max(1, schemaVersion)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        sourceSessionID = try container.decodeIfPresent(UUID.self, forKey: .sourceSessionID)
        needsLLMDedup = try container.decodeIfPresent(Bool.self, forKey: .needsLLMDedup) ?? false
        facts = try container.decodeIfPresent([ConversationProfileFact].self, forKey: .facts) ?? []
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    public var promptRepresentation: String {
        guard !facts.isEmpty else { return content }
        let grouped = Dictionary(grouping: facts, by: \.category)
        let factBlocks = ConversationProfileFactCategory.allCases.compactMap { category -> String? in
            guard let values = grouped[category], !values.isEmpty else { return nil }
            let lines = values
                .sorted { $0.confidence > $1.confidence }
                .map { fact in
                    "- \(fact.statement) [confidence=\(String(format: "%.2f", fact.confidence)), evidence=\(fact.evidenceCount)]"
                }
                .joined(separator: "\n")
            return "<\(category.rawValue)>\n\(lines)\n</\(category.rawValue)>"
        }
        return ([content] + factBlocks).filter { !$0.isEmpty }.joined(separator: "\n\n")
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

    static func loadUserProfile(from db: Database) throws -> ConversationUserProfile? {
        try ConversationUserProfileStore.loadProfile(from: db)
    }

    static func loadLegacyUserProfile(from store: PersistenceAuxiliaryGRDBStore) -> ConversationUserProfile? {
        ConversationUserProfileStore.loadLegacyProfile(from: store)
    }

    public static func saveUserProfile(
        content: String,
        updatedAt: Date = Date(),
        sourceSessionID: UUID? = nil,
        needsLLMDedup: Bool = false
    ) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try clearUserProfile()
            return
        }
        let existingFacts = loadUserProfile()?.facts ?? []
        try saveUserProfile(
            ConversationUserProfile(
                content: content,
                updatedAt: updatedAt,
                sourceSessionID: sourceSessionID,
                needsLLMDedup: needsLLMDedup,
                facts: existingFacts
            )
        )
    }

    public static func saveUserProfile(_ profile: ConversationUserProfile) throws {
        let trimmed = profile.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !profile.facts.isEmpty else {
            try clearUserProfile()
            return
        }
        let normalized = ConversationUserProfile(
            content: trimmed,
            updatedAt: profile.updatedAt,
            sourceSessionID: profile.sourceSessionID,
            needsLLMDedup: profile.needsLLMDedup,
            facts: profile.facts,
            schemaVersion: profile.schemaVersion
        )
        try profileStore.saveProfile(normalized)
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
        if existingProfile.needsLLMDedup { return true }
        return !calendar.isDate(existingProfile.updatedAt, inSameDayAs: now)
    }

    public static func shouldUpdateUserProfile(on now: Date = Date(), calendar: Calendar = .current) -> Bool {
        shouldUpdateUserProfile(existingProfile: loadUserProfile(), on: now, calendar: calendar)
    }

    public static func decodeGeneratedProfile(
        _ text: String,
        updatedAt: Date = Date(),
        sourceSessionID: UUID?
    ) -> ConversationUserProfile? {
        let normalized = normalizedGeneratedJSON(text)
        guard let data = normalized.data(using: .utf8),
              let document = try? JSONDecoder().decode(GeneratedProfileDocument.self, from: data) else {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { return nil }
            return ConversationUserProfile(
                content: fallback,
                updatedAt: updatedAt,
                sourceSessionID: sourceSessionID
            )
        }
        let facts = document.facts.compactMap { item -> ConversationProfileFact? in
            let statement = item.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else { return nil }
            return ConversationProfileFact(
                category: ConversationProfileFactCategory(rawValue: item.category) ?? .other,
                statement: statement,
                confidence: item.confidence ?? 0.8,
                evidenceCount: item.evidenceCount ?? 1,
                firstObservedAt: updatedAt,
                lastObservedAt: updatedAt,
                sourceSessionIDs: sourceSessionID.map { [$0] } ?? []
            )
        }
        let overview = (document.overview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty || !facts.isEmpty else { return nil }
        return ConversationUserProfile(
            content: overview,
            updatedAt: updatedAt,
            sourceSessionID: sourceSessionID,
            facts: facts
        )
    }

    private static func normalizedGeneratedJSON(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 3 {
                value = lines.dropFirst().dropLast().joined(separator: "\n")
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct GeneratedProfileDocument: Decodable {
        struct Fact: Decodable {
            let category: String
            let statement: String
            let confidence: Double?
            let evidenceCount: Int?

            enum CodingKeys: String, CodingKey {
                case category, statement, confidence
                case evidenceCount = "evidence_count"
            }
        }

        let overview: String?
        let facts: [Fact]
    }
}

private struct ConversationUserProfileStore {
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConversationUserProfileStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rootDirectory: URL?
    private let grdbBlobKey = "conversation_user_profile"
    private var legacyBlobKeys: [String] { [grdbBlobKey, "conversation_user_profile_v1"] }

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
            if let sqliteProfile = sqliteResult.profile {
                return sqliteProfile
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
            WatchDatabaseSyncService.markDatabaseChanged(.memory)
            return
        }

        MemoryStoragePaths.ensureRootDirectory(rootDirectory: rootDirectory)
        let fileURL = MemoryStoragePaths.userProfileFileURL(rootDirectory: rootDirectory)
        let data = try encoder.encode(profile)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        WatchDatabaseSyncService.markDatabaseChanged(.memory)
    }

    func clearProfile() throws {
        if canUseGRDB {
            _ = clearProfileFromSQLite()
            removeLegacyProfileBlobs()
            WatchDatabaseSyncService.markDatabaseChanged(.memory)
        }
        let fileURL = MemoryStoragePaths.userProfileFileURL(rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
        WatchDatabaseSyncService.markDatabaseChanged(.memory)
    }

    private var canUseGRDB: Bool {
        rootDirectory == nil
    }

    private func loadProfileFromSQLite() -> (didRead: Bool, profile: ConversationUserProfile?) {
        guard let profile = Persistence.withMemoryDatabaseRead({ db -> ConversationUserProfile? in
            guard let record = try RelationalConversationUserProfileRecord.fetchOne(db, key: 1) else {
                return nil
            }
            return ConversationUserProfile(
                content: record.content,
                updatedAt: Date(timeIntervalSince1970: record.updatedAt),
                sourceSessionID: record.sourceSessionID.flatMap(UUID.init(uuidString:)),
                needsLLMDedup: record.needsLLMDedup != 0,
                facts: decodeFacts(record.factsJSON),
                schemaVersion: record.schemaVersion
            )
        }) else {
            return (false, nil)
        }

        if profile == nil,
           let legacy = loadLegacyProfileFromBlob() {
            if saveProfileToSQLite(legacy) {
                removeLegacyProfileBlobs()
            }
            return (true, legacy)
        }

        return (true, profile)
    }

    @discardableResult
    private func saveProfileToSQLite(_ profile: ConversationUserProfile) -> Bool {
        let didSave = Persistence.withMemoryDatabaseWrite { db in
            var record = RelationalConversationUserProfileRecord(
                singletonKey: 1,
                content: profile.content,
                updatedAt: profile.updatedAt.timeIntervalSince1970,
                sourceSessionID: profile.sourceSessionID?.uuidString,
                needsLLMDedup: profile.needsLLMDedup ? 1 : 0,
                factsJSON: encodeFacts(profile.facts),
                schemaVersion: profile.schemaVersion
            )
            try record.save(db)
            return true
        } ?? false

        if didSave {
            removeLegacyProfileBlobs()
        }
        return didSave
    }

    @discardableResult
    private func clearProfileFromSQLite() -> Bool {
        Persistence.withMemoryDatabaseWrite { db in
            if let record = try RelationalConversationUserProfileRecord.fetchOne(db, key: 1) {
                try record.delete(db)
            }
            return true
        } ?? false
    }

    private func loadLegacyProfileFromBlob() -> ConversationUserProfile? {
        for key in legacyBlobKeys {
            guard Persistence.auxiliaryBlobExists(forKey: key) else {
                continue
            }
            return Persistence.loadAuxiliaryBlob(ConversationUserProfile.self, forKey: key)
        }
        return nil
    }

    static func loadLegacyProfile(from store: PersistenceAuxiliaryGRDBStore) -> ConversationUserProfile? {
        let keys = ["conversation_user_profile", "conversation_user_profile_v1"]
        for key in keys {
            if let profile = store.loadAuxiliaryBlob(ConversationUserProfile.self, forKey: key) {
                return profile
            }
        }
        return nil
    }

    private func removeLegacyProfileBlobs() {
        for key in legacyBlobKeys {
            _ = Persistence.removeAuxiliaryBlob(forKey: key)
        }
    }

    static func loadProfile(from db: Database) throws -> ConversationUserProfile? {
        guard let record = try RelationalConversationUserProfileRecord.fetchOne(db, key: 1) else {
            return nil
        }
        return ConversationUserProfile(
            content: record.content,
            updatedAt: Date(timeIntervalSince1970: record.updatedAt),
            sourceSessionID: record.sourceSessionID.flatMap(UUID.init(uuidString:)),
            needsLLMDedup: record.needsLLMDedup != 0,
            facts: decodeFacts(record.factsJSON),
            schemaVersion: record.schemaVersion
        )
    }

    private static func encodeFacts(_ facts: [ConversationProfileFact]) -> String {
        guard let data = try? JSONEncoder().encode(facts),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func decodeFacts(_ json: String) -> [ConversationProfileFact] {
        guard let data = json.data(using: .utf8),
              let facts = try? JSONDecoder().decode([ConversationProfileFact].self, from: data) else {
            return []
        }
        return facts
    }

    private func encodeFacts(_ facts: [ConversationProfileFact]) -> String {
        Self.encodeFacts(facts)
    }

    private func decodeFacts(_ json: String) -> [ConversationProfileFact] {
        Self.decodeFacts(json)
    }

    private struct RelationalConversationUserProfileRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "conversation_user_profile"

        enum CodingKeys: String, CodingKey {
            case singletonKey = "singleton_key"
            case content
            case updatedAt = "updated_at"
            case sourceSessionID = "source_session_id"
            case needsLLMDedup = "needs_llm_dedup"
            case factsJSON = "facts_json"
            case schemaVersion = "schema_version"
        }

        var singletonKey: Int
        var content: String
        var updatedAt: Double
        var sourceSessionID: String?
        var needsLLMDedup: Int
        var factsJSON: String
        var schemaVersion: Int
    }
}

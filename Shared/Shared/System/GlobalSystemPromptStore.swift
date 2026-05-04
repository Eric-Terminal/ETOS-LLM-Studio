// ============================================================================
// GlobalSystemPromptStore.swift
// ============================================================================
// 管理全局系统提示词列表与当前选中项
// - 支持从旧版单一 systemPrompt 自动迁移
// - 统一维护列表存储与当前发送用 systemPrompt 的镜像关系
// ============================================================================

import Foundation
import GRDB

public extension Notification.Name {
    static let globalSystemPromptStoreDidChange = Notification.Name("com.ETOS.globalSystemPrompt.storeDidChange")
}

public struct GlobalSystemPromptEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var content: String
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        content: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.updatedAt = updatedAt
    }
}

public struct GlobalSystemPromptSnapshot: Equatable, Sendable {
    public var entries: [GlobalSystemPromptEntry]
    public var selectedEntryID: UUID?
    public var activeSystemPrompt: String

    public init(
        entries: [GlobalSystemPromptEntry],
        selectedEntryID: UUID?,
        activeSystemPrompt: String
    ) {
        self.entries = entries
        self.selectedEntryID = selectedEntryID
        self.activeSystemPrompt = activeSystemPrompt
    }
}

public enum GlobalSystemPromptStore {
    public static let entriesStorageKey = "globalSystemPromptEntriesData"
    public static let selectedEntryIDStorageKey = "selectedGlobalSystemPromptID"
    public static let legacySystemPromptStorageKey = "systemPrompt"

    /// 读取并规范化全局系统提示词状态。
    ///
    /// 规范化规则：
    /// - 优先读取配置数据库中的多版本提示词。
    /// - 当数据库为空且旧版 UserDefaults 数据存在时，自动迁移为数据库记录。
    /// - 当选中项丢失时，自动回退到第一条。
    /// - 始终将当前选中内容镜像回旧版 systemPrompt。
    @discardableResult
    public static func load(userDefaults: UserDefaults = .standard) -> GlobalSystemPromptSnapshot {
        let useDatabase = shouldUseDatabase(userDefaults: userDefaults)
        if useDatabase, let databaseSnapshot = loadFromDatabase() {
            let snapshot = normalizedSnapshot(
                entries: databaseSnapshot.entries,
                selectedEntryID: databaseSnapshot.selectedEntryID,
                legacyPrompt: nil
            )
            if snapshot != databaseSnapshot {
                _ = saveToDatabase(snapshot)
            }
            mirrorCompatibilityFields(snapshot, userDefaults: userDefaults, includeListInUserDefaults: false)
            return snapshot
        }

        let snapshot = loadFromUserDefaults(userDefaults)
        if useDatabase, saveToDatabase(snapshot) {
            mirrorCompatibilityFields(snapshot, userDefaults: userDefaults, includeListInUserDefaults: false)
        } else {
            mirrorCompatibilityFields(snapshot, userDefaults: userDefaults, includeListInUserDefaults: true)
        }
        return snapshot
    }

    /// 保存全局系统提示词列表与当前选中项。
    ///
    /// - Parameters:
    ///   - entries: 待保存列表。
    ///   - selectedEntryID: 期望选中项；若无效将自动回退到第一条。
    ///   - userDefaults: 目标 UserDefaults。
    /// - Returns: 持久化后实际生效的规范化快照。
    @discardableResult
    public static func save(
        entries: [GlobalSystemPromptEntry],
        selectedEntryID: UUID?,
        userDefaults: UserDefaults = .standard
    ) -> GlobalSystemPromptSnapshot {
        let normalizedEntries = normalizeEntries(entries)
        let snapshot = normalizedSnapshot(
            entries: normalizedEntries,
            selectedEntryID: selectedEntryID,
            legacyPrompt: nil
        )
        if shouldUseDatabase(userDefaults: userDefaults), saveToDatabase(snapshot) {
            mirrorCompatibilityFields(snapshot, userDefaults: userDefaults, includeListInUserDefaults: false)
        } else {
            mirrorCompatibilityFields(snapshot, userDefaults: userDefaults, includeListInUserDefaults: true)
        }
        NotificationCenter.default.post(name: .globalSystemPromptStoreDidChange, object: nil)
        return snapshot
    }

    private static func shouldUseDatabase(userDefaults: UserDefaults) -> Bool {
        userDefaults === UserDefaults.standard
    }

    private static func loadFromDatabase() -> GlobalSystemPromptSnapshot? {
        Persistence.withConfigDatabaseRead { db -> GlobalSystemPromptSnapshot? in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, title, content, updated_at
                FROM global_system_prompt_entries
                ORDER BY sort_index ASC, updated_at DESC, id ASC
                """
            )
            let selectionRow = try Row.fetchOne(
                db,
                sql: """
                SELECT selected_entry_id, active_system_prompt
                FROM global_system_prompt_selection
                WHERE singleton_id = 'current'
                """
            )

            guard !rows.isEmpty || selectionRow != nil else { return nil }

            let entries = rows.map { row in
                let id: String = row["id"]
                let title: String = row["title"]
                let content: String = row["content"]
                let updatedAt: Double = row["updated_at"]
                return GlobalSystemPromptEntry(
                    id: UUID(uuidString: id) ?? UUID(),
                    title: title,
                    content: content,
                    updatedAt: Date(timeIntervalSince1970: updatedAt)
                )
            }
            let selectedRawID = selectionRow.flatMap { row -> String? in row["selected_entry_id"] }
            let activePrompt = selectionRow.map { row -> String in row["active_system_prompt"] } ?? ""
            return GlobalSystemPromptSnapshot(
                entries: entries,
                selectedEntryID: selectedRawID.flatMap(UUID.init(uuidString:)),
                activeSystemPrompt: activePrompt
            )
        } ?? nil
    }

    @discardableResult
    private static func saveToDatabase(_ snapshot: GlobalSystemPromptSnapshot) -> Bool {
        Persistence.withConfigDatabaseWrite { db in
            try db.execute(sql: "DELETE FROM global_system_prompt_entries")
            for (index, entry) in snapshot.entries.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO global_system_prompt_entries (
                        id, title, content, updated_at, sort_index
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        entry.id.uuidString,
                        entry.title,
                        entry.content,
                        entry.updatedAt.timeIntervalSince1970,
                        index
                    ]
                )
            }

            try db.execute(
                sql: """
                INSERT INTO global_system_prompt_selection (
                    singleton_id, selected_entry_id, active_system_prompt, updated_at
                ) VALUES ('current', ?, ?, ?)
                ON CONFLICT(singleton_id) DO UPDATE SET
                    selected_entry_id = excluded.selected_entry_id,
                    active_system_prompt = excluded.active_system_prompt,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    snapshot.selectedEntryID?.uuidString,
                    snapshot.activeSystemPrompt,
                    Date().timeIntervalSince1970
                ]
            )
            return true
        } ?? false
    }

    private static func loadFromUserDefaults(_ userDefaults: UserDefaults) -> GlobalSystemPromptSnapshot {
        normalizedSnapshot(
            entries: decodeEntries(from: userDefaults.data(forKey: entriesStorageKey)),
            selectedEntryID: userDefaults.string(forKey: selectedEntryIDStorageKey).flatMap(UUID.init(uuidString:)),
            legacyPrompt: userDefaults.string(forKey: legacySystemPromptStorageKey) ?? ""
        )
    }

    @discardableResult
    private static func mirrorCompatibilityFields(
        _ snapshot: GlobalSystemPromptSnapshot,
        userDefaults: UserDefaults,
        includeListInUserDefaults: Bool
    ) -> Bool {
        var didChange = false

        if includeListInUserDefaults {
            if snapshot.entries.isEmpty {
                didChange = removeObjectIfNeeded(forKey: entriesStorageKey, in: userDefaults) || didChange
                didChange = removeObjectIfNeeded(forKey: selectedEntryIDStorageKey, in: userDefaults) || didChange
            } else {
                if let encoded = try? JSONEncoder().encode(snapshot.entries) {
                    didChange = setDataIfNeeded(encoded, forKey: entriesStorageKey, in: userDefaults) || didChange
                }
                if let selectedEntryID = snapshot.selectedEntryID {
                    didChange = setStringIfNeeded(selectedEntryID.uuidString, forKey: selectedEntryIDStorageKey, in: userDefaults) || didChange
                } else {
                    didChange = removeObjectIfNeeded(forKey: selectedEntryIDStorageKey, in: userDefaults) || didChange
                }
            }
        } else {
            didChange = removeObjectIfNeeded(forKey: entriesStorageKey, in: userDefaults) || didChange
            didChange = removeObjectIfNeeded(forKey: selectedEntryIDStorageKey, in: userDefaults) || didChange
        }

        didChange = setStringIfNeeded(snapshot.activeSystemPrompt, forKey: legacySystemPromptStorageKey, in: userDefaults) || didChange
        return didChange
    }

    private static func setDataIfNeeded(_ value: Data, forKey key: String, in userDefaults: UserDefaults) -> Bool {
        guard userDefaults.data(forKey: key) != value else { return false }
        userDefaults.set(value, forKey: key)
        return true
    }

    private static func setStringIfNeeded(_ value: String, forKey key: String, in userDefaults: UserDefaults) -> Bool {
        guard userDefaults.string(forKey: key) != value else { return false }
        userDefaults.set(value, forKey: key)
        return true
    }

    private static func removeObjectIfNeeded(forKey key: String, in userDefaults: UserDefaults) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return false }
        userDefaults.removeObject(forKey: key)
        return true
    }

    private static func decodeEntries(from data: Data?) -> [GlobalSystemPromptEntry] {
        guard let data,
              let entries = try? JSONDecoder().decode([GlobalSystemPromptEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func normalizeEntries(_ entries: [GlobalSystemPromptEntry]) -> [GlobalSystemPromptEntry] {
        var seenIDs = Set<UUID>()
        var normalized: [GlobalSystemPromptEntry] = []
        normalized.reserveCapacity(entries.count)

        for entry in entries {
            guard seenIDs.insert(entry.id).inserted else { continue }
            normalized.append(entry)
        }

        return normalized
    }

    private static func normalizedSnapshot(
        entries: [GlobalSystemPromptEntry],
        selectedEntryID: UUID?,
        legacyPrompt: String?
    ) -> GlobalSystemPromptSnapshot {
        var normalizedEntries = normalizeEntries(entries)
        var normalizedSelectedID = selectedEntryID

        if normalizedEntries.isEmpty {
            let trimmedLegacy = legacyPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedLegacy.isEmpty {
                let migratedEntry = GlobalSystemPromptEntry(
                    title: defaultTitle(for: trimmedLegacy),
                    content: legacyPrompt ?? "",
                    updatedAt: Date()
                )
                normalizedEntries = [migratedEntry]
                normalizedSelectedID = migratedEntry.id
            } else {
                normalizedSelectedID = nil
            }
        } else if let selectedEntryID,
                  normalizedEntries.contains(where: { $0.id == selectedEntryID }) {
            normalizedSelectedID = selectedEntryID
        } else {
            normalizedSelectedID = normalizedEntries.first?.id
        }

        return GlobalSystemPromptSnapshot(
            entries: normalizedEntries,
            selectedEntryID: normalizedSelectedID,
            activeSystemPrompt: normalizedEntries.first(where: { $0.id == normalizedSelectedID })?.content ?? ""
        )
    }

    private static func defaultTitle(for content: String) -> String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if firstLine.isEmpty {
            return "历史提示词"
        }

        if firstLine.count <= 20 {
            return firstLine
        }

        let index = firstLine.index(firstLine.startIndex, offsetBy: 20)
        return String(firstLine[..<index])
    }
}

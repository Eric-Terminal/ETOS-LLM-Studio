// ============================================================================
// GlobalSystemPromptStore.swift
// ============================================================================
// 管理全局系统提示词列表与当前选中项
// - 支持从旧版单一 systemPrompt 自动迁移
// - 统一维护列表存储与当前发送用 systemPrompt 的镜像关系
// ============================================================================

import Foundation

public struct GlobalSystemPromptEntry: Codable, Equatable, Identifiable {
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

public struct GlobalSystemPromptSnapshot: Equatable {
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
    /// - 当列表为空且旧版 systemPrompt 非空时，自动迁移为一条历史记录。
    /// - 当选中项丢失时，自动回退到第一条。
    /// - 始终将当前选中内容镜像回 systemPrompt。
    @discardableResult
    public static func load(userDefaults: UserDefaults = .standard) -> GlobalSystemPromptSnapshot {
        let entriesData = userDefaults.data(forKey: entriesStorageKey)
        let selectedRawID = userDefaults.string(forKey: selectedEntryIDStorageKey)
        let legacyPrompt = userDefaults.string(forKey: legacySystemPromptStorageKey) ?? ""

        var entries = decodeEntries(from: entriesData)
        var selectedEntryID = selectedRawID.flatMap(UUID.init(uuidString:))
        var didMutate = false

        entries = normalizeEntries(entries)

        if entries.isEmpty {
            let trimmedLegacy = legacyPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLegacy.isEmpty {
                let migratedEntry = GlobalSystemPromptEntry(
                    title: defaultTitle(for: trimmedLegacy),
                    content: legacyPrompt,
                    updatedAt: Date()
                )
                entries = [migratedEntry]
                selectedEntryID = migratedEntry.id
                didMutate = true
            } else if selectedEntryID != nil {
                selectedEntryID = nil
                didMutate = true
            }
        } else if let selectedID = selectedEntryID {
            if entries.contains(where: { $0.id == selectedID }) == false {
                selectedEntryID = entries.first?.id
                didMutate = true
            }
        } else {
            selectedEntryID = entries.first?.id
            didMutate = true
        }

        let activePrompt = entries.first(where: { $0.id == selectedEntryID })?.content ?? ""
        if legacyPrompt != activePrompt {
            didMutate = true
        }

        let snapshot = GlobalSystemPromptSnapshot(
            entries: entries,
            selectedEntryID: selectedEntryID,
            activeSystemPrompt: activePrompt
        )

        if didMutate {
            persist(snapshot, userDefaults: userDefaults)
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
        let normalizedSelectedID: UUID?
        if let selectedEntryID,
           normalizedEntries.contains(where: { $0.id == selectedEntryID }) {
            normalizedSelectedID = selectedEntryID
        } else {
            normalizedSelectedID = normalizedEntries.first?.id
        }

        let activePrompt = normalizedEntries.first(where: { $0.id == normalizedSelectedID })?.content ?? ""
        let snapshot = GlobalSystemPromptSnapshot(
            entries: normalizedEntries,
            selectedEntryID: normalizedSelectedID,
            activeSystemPrompt: activePrompt
        )
        persist(snapshot, userDefaults: userDefaults)
        return snapshot
    }

    private static func persist(_ snapshot: GlobalSystemPromptSnapshot, userDefaults: UserDefaults) {
        if snapshot.entries.isEmpty {
            userDefaults.removeObject(forKey: entriesStorageKey)
            userDefaults.removeObject(forKey: selectedEntryIDStorageKey)
        } else {
            if let encoded = try? JSONEncoder().encode(snapshot.entries) {
                userDefaults.set(encoded, forKey: entriesStorageKey)
            }
            if let selectedEntryID = snapshot.selectedEntryID {
                userDefaults.set(selectedEntryID.uuidString, forKey: selectedEntryIDStorageKey)
            } else {
                userDefaults.removeObject(forKey: selectedEntryIDStorageKey)
            }
        }

        userDefaults.set(snapshot.activeSystemPrompt, forKey: legacySystemPromptStorageKey)
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

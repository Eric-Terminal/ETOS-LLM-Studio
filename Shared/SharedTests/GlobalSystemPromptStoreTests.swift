// ============================================================================
// GlobalSystemPromptStoreTests.swift
// ============================================================================
// GlobalSystemPromptStoreTests 测试文件
// - 覆盖全局系统提示词列表迁移与持久化行为
// - 保障多条提示词管理的核心回归
// ============================================================================

import Testing
import Foundation
import GRDB
@testable import Shared

@Suite("Global System Prompt Store Tests")
struct GlobalSystemPromptStoreTests {

    @Test("legacy systemPrompt migrates into first entry")
    func testLegacyPromptMigration() {
        let suiteName = "com.ETOS.tests.globalPrompt.migrate.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("旧版提示词内容", forKey: GlobalSystemPromptStore.legacySystemPromptStorageKey)

        let snapshot = GlobalSystemPromptStore.load(userDefaults: defaults)
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.activeSystemPrompt == "旧版提示词内容")
        #expect(snapshot.selectedEntryID != nil)
        #expect(defaults.data(forKey: GlobalSystemPromptStore.entriesStorageKey) != nil)
        #expect(defaults.string(forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey) == snapshot.selectedEntryID?.uuidString)
    }

    @Test("saving entries mirrors selected content into systemPrompt")
    func testSaveMirrorsSelectedPrompt() {
        let suiteName = "com.ETOS.tests.globalPrompt.save.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let first = GlobalSystemPromptEntry(title: "日常助手", content: "你是日常助手")
        let second = GlobalSystemPromptEntry(title: "绘画助手", content: "你是绘画助手")

        let snapshot = GlobalSystemPromptStore.save(
            entries: [first, second],
            selectedEntryID: second.id,
            userDefaults: defaults
        )

        #expect(snapshot.selectedEntryID == second.id)
        #expect(snapshot.activeSystemPrompt == "你是绘画助手")
        #expect(defaults.string(forKey: GlobalSystemPromptStore.legacySystemPromptStorageKey) == "你是绘画助手")
    }

    @Test("selected id falls back to first when missing")
    func testSelectionFallbackWhenMissing() {
        let suiteName = "com.ETOS.tests.globalPrompt.fallback.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let oldEntry = GlobalSystemPromptEntry(title: "旧条目", content: "旧内容")
        let keptEntry = GlobalSystemPromptEntry(title: "新条目", content: "新内容")

        _ = GlobalSystemPromptStore.save(
            entries: [oldEntry, keptEntry],
            selectedEntryID: oldEntry.id,
            userDefaults: defaults
        )

        let snapshot = GlobalSystemPromptStore.save(
            entries: [keptEntry],
            selectedEntryID: oldEntry.id,
            userDefaults: defaults
        )

        #expect(snapshot.entries.count == 1)
        #expect(snapshot.selectedEntryID == keptEntry.id)
        #expect(snapshot.activeSystemPrompt == "新内容")
    }

    @Test("duplicate ids are normalized during save")
    func testDuplicateIDNormalization() {
        let suiteName = "com.ETOS.tests.globalPrompt.dedup.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let sharedID = UUID()
        let first = GlobalSystemPromptEntry(id: sharedID, title: "A", content: "内容 A")
        let second = GlobalSystemPromptEntry(id: sharedID, title: "B", content: "内容 B")

        let snapshot = GlobalSystemPromptStore.save(
            entries: [first, second],
            selectedEntryID: sharedID,
            userDefaults: defaults
        )

        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.title == "A")
    }

    @Test("GRDB 模式下多版本提示词迁入配置数据库")
    func testRelationalStoreMigration() {
        let defaults = UserDefaults.standard
        let originalEntriesObject = defaults.object(forKey: GlobalSystemPromptStore.entriesStorageKey)
        let originalSelectedObject = defaults.object(forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey)
        let originalLegacyObject = defaults.object(forKey: GlobalSystemPromptStore.legacySystemPromptStorageKey)
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        let originalSnapshot = GlobalSystemPromptStore.load(userDefaults: defaults)

        defer {
            _ = GlobalSystemPromptStore.save(
                entries: originalSnapshot.entries,
                selectedEntryID: originalSnapshot.selectedEntryID,
                userDefaults: defaults
            )
            restore(originalEntriesObject, forKey: GlobalSystemPromptStore.entriesStorageKey, in: defaults)
            restore(originalSelectedObject, forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey, in: defaults)
            restore(originalLegacyObject, forKey: GlobalSystemPromptStore.legacySystemPromptStorageKey, in: defaults)
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        _ = Persistence.withConfigDatabaseWrite { db in
            try db.execute(sql: "DELETE FROM global_system_prompt_entries")
            try db.execute(sql: "DELETE FROM global_system_prompt_selection")
        }

        let entry = GlobalSystemPromptEntry(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: "数据库提示词",
            content: "请从配置数据库读取",
            updatedAt: Date(timeIntervalSince1970: 1_714_100_000)
        )
        guard let entryData = try? JSONEncoder().encode([entry]) else {
            Issue.record("编码全局提示词测试数据失败")
            return
        }
        defaults.set(entryData, forKey: GlobalSystemPromptStore.entriesStorageKey)
        defaults.set(entry.id.uuidString, forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey)

        let snapshot = GlobalSystemPromptStore.load(userDefaults: defaults)

        #expect(snapshot.entries == [entry])
        #expect(snapshot.selectedEntryID == entry.id)
        #expect(defaults.data(forKey: GlobalSystemPromptStore.entriesStorageKey) == nil)
        #expect(defaults.string(forKey: GlobalSystemPromptStore.selectedEntryIDStorageKey) == nil)
        #expect(defaults.string(forKey: GlobalSystemPromptStore.legacySystemPromptStorageKey) == entry.content)

        let storedCount = Persistence.withConfigDatabaseRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM global_system_prompt_entries")
        } ?? -1
        let storedContent = Persistence.withConfigDatabaseRead { db in
            try String.fetchOne(
                db,
                sql: "SELECT content FROM global_system_prompt_entries WHERE id = ?",
                arguments: [entry.id.uuidString]
            )
        } ?? ""

        #expect(storedCount == 1)
        #expect(storedContent == entry.content)
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

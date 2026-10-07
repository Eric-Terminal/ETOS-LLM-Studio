import Foundation
import Testing
@testable import ETOSCore

struct WorldbookDraftWriteTests {
    @Test("过期编辑和删除确认不会覆盖另一个编辑器，删除后旧草稿不能复活")
    func rejectsStaleDrafts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorldbookStore(storageDirectoryURL: directory)
        let original = Worldbook(name: "世界书", entries: [WorldbookEntry(content: "原条目", keys: [])])
        store.upsertWorldbook(original)
        var first = original
        first.description = "已更新"
        try store.saveDraft(first, replacing: original)
        #expect(throws: WorldbookDraftWriteError.self) { try store.saveDraft(original, replacing: original) }
        #expect(!store.deleteWorldbook(id: original.id, expected: original))
        let latest = try #require(store.loadWorldbooks().first)
        #expect(latest.description == "已更新")
        #expect(store.deleteWorldbook(id: latest.id, expected: latest))
        #expect(throws: WorldbookDraftWriteError.self) { try store.saveDraft(latest, replacing: latest) }
        #expect(store.loadWorldbooks().isEmpty)
    }

    @Test("并发保存同一原版时仅一个草稿成功")
    func serializesVersionCheckWithWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorldbookStore(storageDirectoryURL: directory)
        let original = Worldbook(name: "并发草稿", entries: [])
        store.upsertWorldbook(original)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<2 {
                group.addTask {
                    var draft = original
                    draft.description = "草稿 \(index)"
                    do { try store.saveDraft(draft, replacing: original); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
    }

    @Test("新建草稿校验名称并保留条目兼容元数据，写盘失败不报告成功")
    func validatesAndReportsPersistenceFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorldbookStore(storageDirectoryURL: directory)
        let empty = Worldbook(name: " \n", entries: [])
        #expect(throws: WorldbookDraftWriteError.self) { try store.saveDraft(empty, replacing: nil) }
        let entry = WorldbookEntry(uid: 72, content: "兼容条目", keys: ["甲"], metadata: ["unknownExtension": .string("保留")])
        let draft = Worldbook(name: " 新书 ", entries: [entry], metadata: ["source": .string("导入")])
        try store.saveDraft(draft, replacing: nil)
        let restored = try #require(WorldbookStore(storageDirectoryURL: directory).loadWorldbooks().first)
        #expect(restored.name == "新书")
        #expect(restored.entries == [entry])
        #expect(restored.metadata == draft.metadata)
        #expect(throws: WorldbookDraftWriteError.self) { try store.saveDraft(draft, replacing: nil) }

        let blocked = directory.appendingPathComponent("普通文件")
        try Data().write(to: blocked)
        let invalidStore = WorldbookStore(storageDirectoryURL: blocked)
        #expect(throws: WorldbookDraftWriteError.self) { try invalidStore.saveDraft(draft, replacing: nil) }
        #expect(invalidStore.loadWorldbooks().isEmpty)
        let report = invalidStore.mergeImportedWorldbook(draft, dedupeByContent: false)
        #expect(report.importedBookID == nil)
        #expect(report.importedEntries == 0 && report.failedEntries == 1)
    }

    @Test("排序保留完整书籍，只接受原目录快照和完整的唯一 ID 列表")
    func validatesReordering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorldbookStore(storageDirectoryURL: directory)
        let first = Worldbook(name: "甲", updatedAt: Date(timeIntervalSince1970: 2), entries: [WorldbookEntry(content: "内容", keys: [])])
        let second = Worldbook(name: "乙", updatedAt: Date(timeIntervalSince1970: 1), entries: [])
        store.saveWorldbooks([first, second])
        let original = store.loadWorldbooks()
        #expect(throws: WorldbookDraftWriteError.self) { try store.reorderDraft([first.id, first.id], replacing: original) }
        try store.reorderDraft([second.id, first.id], replacing: original)
        let latest = store.loadWorldbooks()
        #expect(latest.map(\.id) == [second.id, first.id])
        #expect(latest.last?.entries == first.entries)
        #expect(throws: WorldbookDraftWriteError.self) { try store.reorderDraft([first.id, second.id], replacing: original) }
    }
}

import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacWorldbookSnapshotTests {
    @Test("搜索覆盖正文和次级关键词，筛选不移除已打开详情的索引")
    func searchesEntriesWithoutDroppingDetail() {
        let first = Worldbook(name: "港口", entries: [WorldbookEntry(comment: "灯塔", content: "夜间航线", keys: ["港口"], secondaryKeys: ["信标"])])
        let second = Worldbook(name: "森林", entries: [])
        let snapshot = MacWorldbookSnapshot.prepare([first, second], query: "信标")
        #expect(snapshot.rows.map(\.id) == [first.id])
        #expect(snapshot.byID[second.id]?.book == second)
        #expect(snapshot.allBooks == [first, second])
        #expect(MacWorldbookSnapshot.prepare([first, second], query: "航线").rows.map(\.id) == [first.id])
    }

    @Test("条目编辑保留 uid、未知扩展和原有禁用次级规则，规范化关键词不重复")
    func preservesImportedMetadata() throws {
        let entry = WorldbookEntry(uid: 38, content: " 正文 ", keys: ["一"], secondaryKeys: ["二"],
                                   metadata: ["selective": .bool(false), "externalScript": .string("不要丢失")])
        var draft = MacWorldbookEntryDraft(entry: entry)
        draft.keysText = " Alpha，alpha\nBeta, \n"
        let saved = try draft.preparedEntry()
        #expect(saved.id == entry.id && saved.uid == 38)
        #expect(saved.keys == ["Alpha", "Beta"])
        #expect(saved.content == "正文")
        #expect(!saved.secondaryKeysEnabled)
        #expect(saved.metadata["externalScript"] == .string("不要丢失"))
    }

    @Test("空正文和没有关键词的普通条目不能保存，常驻条目可没有关键词")
    func validatesEntryDraft() throws {
        var draft = MacWorldbookEntryDraft(entry: WorldbookEntry(content: " \n", keys: []))
        #expect(throws: MacWorldbookEntryError.self) { try draft.preparedEntry() }
        draft.entry.content = "常驻资料"
        #expect(throws: MacWorldbookEntryError.self) { try draft.preparedEntry() }
        draft.entry.constant = true
        draft.entry.position = .atDepth
        draft.entry.depth = -2
        draft.entry.probability = 150
        draft.entry.scanDepth = 0
        let saved = try draft.preparedEntry()
        #expect(saved.keys.isEmpty)
        #expect(saved.depth == 0 && saved.probability == 100 && saved.scanDepth == 1)
    }
}

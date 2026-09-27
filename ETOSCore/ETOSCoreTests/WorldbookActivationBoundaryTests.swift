import Foundation
import Testing
@testable import ETOSCore

@Suite("世界书关键词触发边界")
struct WorldbookActivationBoundaryTests {
    @Test("角色卡世界书保留自己的扫描深度和递归开关", arguments: [false, true])
    func embeddedBookRespectsScanSettings(recursive: Bool) throws {
        let data = Data("""
        {
          "name": "角色名称", "scanDepth": 99, "description": "角色说明",
          "character_book": {
            "name": "设定书", "description": "世界书说明",
            "scan_depth": 1, "recursive_scanning": \(recursive),
            "entries": [
              {"keys": ["启程"], "content": "路上有树屋、湖泊和古堡。"},
              {"keys": ["树屋"], "content": "树屋条目正文"},
              {"keys": ["湖泊"], "content": "湖泊条目正文"},
              {"keys": ["古堡"], "content": "古堡条目正文"}
            ]
          }
        }
        """.utf8)
        let book = try WorldbookImportService().importWorldbook(from: data, fileName: "card.json")
        #expect(book.name == "设定书")
        #expect(book.description == "世界书说明")
        #expect(book.settings.scanDepth == 1)
        #expect(book.settings.maxRecursionDepth == (recursive ? 2 : 0))
        let result = evaluate([book], messages: [
            ChatMessage(role: .user, content: "树屋、湖泊和古堡"),
            ChatMessage(role: .assistant, content: "好的。"),
            ChatMessage(role: .user, content: "启程")
        ])
        #expect(result.after.count == (recursive ? 4 : 1))
        #expect(result.after.contains { $0.content == "路上有树屋、湖泊和古堡。" })
    }

    @Test("独立世界书可关闭递归，显式层级在导出重导后保留", arguments: [false, true])
    func standaloneRecursionSettingRoundTrips(nestedSettings: Bool) throws {
        let settings: [String: Any] = ["recursive_scanning": false, "scan_depth": 1]
        var payload: [String: Any] = [
            "name": "独立世界书",
            "entries": [["keys": ["启程"], "content": "仅关键词命中时发送"]]
        ]
        if nestedSettings {
            payload["settings"] = settings
        } else {
            payload.merge(settings) { _, value in value }
        }
        let importer = WorldbookImportService()
        var book = try importer.importWorldbook(from: JSONSerialization.data(withJSONObject: payload), fileName: "book.json")
        #expect(book.settings.maxRecursionDepth == 0)
        // 用户导入后可以主动改为递归，重导本机格式时不能被来源文件的旧开关覆盖。
        book.settings.maxRecursionDepth = 1
        let exported = try WorldbookExportService().exportWorldbook(book)
        let restored = try importer.importWorldbook(from: exported, fileName: "book.lorebook.json")
        #expect(restored.settings.maxRecursionDepth == 1)
    }

    @Test("没有关键词命中时不发送整本书，常驻和停用条目仍遵守各自规则")
    func unmatchedKeywordsDoNotActivateEntries() {
        let constant = WorldbookEntry(content: "常驻设定", keys: [], constant: true)
        let book = Worldbook(name: "关键词书", entries: [
            WorldbookEntry(content: "角色设定", keys: ["勇者"]),
            WorldbookEntry(content: "地点设定", keys: ["古堡"]),
            WorldbookEntry(content: "空关键词设定", keys: ["", "  "]),
            WorldbookEntry(content: "停用设定", keys: [], isEnabled: false, constant: true),
            constant
        ])
        let result = evaluate([book], messages: [ChatMessage(role: .user, content: "普通问候")])
        #expect(result.triggeredEntryIDs == [constant.id])
    }

    @Test("关闭递归的世界书不被其他书的正文激活，但仍接受直接关键词")
    func disabledBookDoesNotConsumeRecursion() {
        let source = WorldbookEntry(content: "跨书关键词", keys: ["起点"])
        let direct = WorldbookEntry(content: "直接命中", keys: ["起点"])
        let blocked = WorldbookEntry(content: "不应被跨书注入", keys: ["跨书关键词"])
        let result = evaluate([
            Worldbook(name: "递归书", entries: [source], settings: .init(maxRecursionDepth: 2)),
            Worldbook(name: "关闭递归", entries: [direct, blocked], settings: .init(maxRecursionDepth: 0))
        ], messages: [ChatMessage(role: .user, content: "起点")])
        #expect(Set(result.triggeredEntryIDs) == [source.id, direct.id])
    }

    @Test("关闭递归的世界书正文不向其他书传播关键词")
    func disabledBookDoesNotProduceRecursion() {
        let source = WorldbookEntry(content: "扩散关键词", keys: ["起点"])
        let result = evaluate([
            Worldbook(name: "关闭递归", entries: [source], settings: .init(maxRecursionDepth: 0)),
            Worldbook(name: "递归书", entries: [
                WorldbookEntry(content: "不应被间接注入", keys: ["扩散关键词"])
            ], settings: .init(maxRecursionDepth: 3))
        ], messages: [ChatMessage(role: .user, content: "起点")])
        #expect(result.triggeredEntryIDs == [source.id])
    }

    @Test("多本书分别遵守非零递归上限，不接受或传播超出层级的关键词")
    func booksKeepIndependentDepthLimits() {
        let source = WorldbookEntry(content: "第一层关键词", keys: ["起点"])
        let deepFirst = WorldbookEntry(content: "第二层关键词", keys: ["第一层关键词"])
        let deepSecond = WorldbookEntry(content: "允许的第二层正文", keys: ["第二层关键词"])
        let shallowFirst = WorldbookEntry(content: "浅层书不应再传播的关键词", keys: ["第一层关键词"])
        let result = evaluate([
            Worldbook(name: "深层书", entries: [source, deepFirst, deepSecond,
                WorldbookEntry(content: "错误接收超限传播", keys: ["浅层书不应再传播的关键词"])
            ], settings: .init(maxRecursionDepth: 3)),
            Worldbook(name: "浅层书", entries: [shallowFirst,
                WorldbookEntry(content: "错误参与第二层扫描", keys: ["第二层关键词"])
            ], settings: .init(maxRecursionDepth: 1))
        ], messages: [ChatMessage(role: .user, content: "起点")])
        #expect(Set(result.triggeredEntryIDs) == [source.id, deepFirst.id, deepSecond.id, shallowFirst.id])
    }

    private func evaluate(_ books: [Worldbook], messages: [ChatMessage]) -> WorldbookEvaluationResult {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldbook-boundaries-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let engine = WorldbookEngine(runtimeStore: WorldbookRuntimeStateStore(storageURL: stateURL), randomSource: { 0 })
        return engine.evaluate(.init(sessionID: UUID(), worldbooks: books, messages: messages))
    }
}

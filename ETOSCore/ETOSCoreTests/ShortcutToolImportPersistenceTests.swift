import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct ShortcutToolImportPersistenceTests {
    @Test("导入解析兼容三种清单，未知版本与损坏输入不产生工具")
    func decodesSupportedManifestsWithoutManagerInitialization() throws {
        let manifest = #"{"schemaVersion":1,"tools":[{"name":"full","externalId":"external","metadata":{"custom":7},"runModeHint":"bridge"}]}"#
        let full = try #require(ShortcutToolManager.decodeImportPayloads(from: Data(manifest.utf8)).first)
        #expect(full.externalID == "external" && full.metadata["custom"] == .int(7) && full.runModeHint == .bridge)
        let light = try ShortcutToolManager.decodeImportPayloads(from: Data(#"{"type":"LIGHT","data":["one"]}"#.utf8))
        #expect(light.map(\.name) == ["one"] && light.first?.metadata["importMode"] == .string("light"))
        let deep = try ShortcutToolManager.decodeImportPayloads(from: Data(#"{"type":"deep","data":[{"name":"two","url":" https://www.icloud.com/shortcuts/abc "}]}"#.utf8))
        #expect(deep.first?.metadata["icloudLink"] == .string("https://www.icloud.com/shortcuts/abc"))
        #expect(throws: ShortcutToolError.self) {
            try ShortcutToolManager.decodeImportPayloads(from: Data(#"{"schemaVersion":2,"tools":[]}"#.utf8))
        }
        #expect(throws: ShortcutToolError.self) { try ShortcutToolManager.decodeImportPayloads(from: Data("invalid".utf8)) }
    }

    @Test("深度解析仅接受 iCloud 分享域名，不接受包含相同文本的伪装域名")
    func sharedLinkRequiresExactHost() {
        #expect(ShortcutToolManager.parseShortcutID(fromICloudLink: "https://www.icloud.com/shortcuts/abc") == "abc")
        #expect(ShortcutToolManager.parseShortcutID(fromICloudLink: "https://icloud.com/shortcuts/abc") == "abc")
        #expect(ShortcutToolManager.parseShortcutID(fromICloudLink: "https://noticloud.com/shortcuts/abc") == nil)
        #expect(ShortcutToolManager.parseShortcutID(fromICloudLink: "https://icloud.com.example/shortcuts/abc") == nil)
        #expect(ShortcutToolManager.parseShortcutID(fromICloudLink: "https://www.icloud.com/shortcuts") == nil)
    }

    @Test("导入预览统一名称冲突规则并保留扩展元数据")
    func candidatesKeepPayloadAndCountConflicts() {
        let existing = ShortcutToolDefinition(name: "Existing")
        let metadata: [String: JSONValue] = ["future": .dictionary(["value": .int(7)])]
        let preview = ShortcutToolManager.prepareImportCandidates([
            ShortcutToolImportPayload(name: " existing "),
            ShortcutToolImportPayload(name: " new ", externalID: "external", metadata: metadata, source: "source", runModeHint: .bridge),
            ShortcutToolImportPayload(name: "NEW"), ShortcutToolImportPayload(name: " \n ")
        ], existing: [existing], describe: { _ in "测试描述" })
        #expect(preview.tools.map(\.name) == ["new"])
        #expect(preview.skippedCount == 2 && preview.invalidCount == 1)
        #expect(preview.tools.first?.metadata == metadata)
        #expect(preview.tools.first?.runModeHint == .bridge && preview.tools.first?.isEnabled == true)
        #expect(preview.tools.first?.externalID == "external")
    }

    @Test("确认时跳过预览后新增的重名工具，保留其他工具及元数据")
    func commitUsesCurrentDatabaseInsteadOfPreviewSnapshot() throws {
        let db = try database()
        let first = stable(ShortcutToolDefinition(name: "Original", metadata: ["keep": .int(1)], isEnabled: false))
        let competing = stable(ShortcutToolDefinition(name: "new", metadata: ["other": .bool(true)], userDescription: "外部修改"))
        _ = try db.write { try ShortcutToolStore.insertPrepared(preview([first, competing]), in: $0) }
        let candidate = ShortcutToolDefinition(name: "NEW", source: "过期预览")
        let accepted = stable(ShortcutToolDefinition(name: "Another", metadata: ["nested": .array([.string("one"), .int(2)])]))
        let result = try db.write { try ShortcutToolStore.insertPrepared(preview([candidate, accepted]), in: $0) }
        #expect(result.1.importedCount == 1 && result.1.skippedCount == 1)
        #expect(result.1.conflictNames == ["NEW"])
        #expect(result.0.first { $0.id == first.id } == first)
        #expect(result.0.first { $0.id == competing.id } == competing)
        #expect(result.0.first { $0.id == accepted.id } == accepted)
    }

    @Test("元数据写入失败回滚整批新增，不留下部分工具")
    func importFailureRollsBackBatch() throws {
        let db = try database()
        let existing = stable(ShortcutToolDefinition(name: "existing"))
        _ = try db.write { try ShortcutToolStore.insertPrepared(preview([existing]), in: $0) }
        try db.write { try $0.execute(sql: """
            CREATE TRIGGER reject_metadata BEFORE INSERT ON shortcut_tool_metadata
            BEGIN SELECT RAISE(ABORT, '拒绝测试写入'); END
            """) }
        #expect(throws: DatabaseError.self) {
            try db.write { try ShortcutToolStore.insertPrepared(preview([
                ShortcutToolDefinition(name: "first"), ShortcutToolDefinition(name: "second", metadata: ["value": .int(1)])
            ]), in: $0) }
        }
        #expect(try db.read { try ShortcutToolStore.loadTools(from: $0) } == [existing])
    }

    @Test("生成描述与详情草稿一起保存，过期生成不能覆盖新设置")
    func descriptionUsesSameDraftVersionCheck() throws {
        let db = try database()
        let original = stable(ShortcutToolDefinition(name: "one", generatedDescription: "old"))
        _ = try db.write { try ShortcutToolStore.insertPrepared(preview([original]), in: $0) }
        let saved = try db.write { try #require(ShortcutToolStore.saveSettingsDraft(original: original, isEnabled: true,
            runMode: .bridge, userDescription: "custom", generatedDescription: "new", in: $0)?.first) }
        #expect(saved.generatedDescription == "new" && saved.userDescription == "custom" && saved.runModeHint == .bridge)
        let stale = try db.write { try ShortcutToolStore.saveSettingsDraft(original: original, isEnabled: false,
            runMode: .direct, userDescription: "stale", generatedDescription: "late", in: $0) }
        #expect(stale == nil)
        #expect(try db.read { try ShortcutToolStore.loadTools(from: $0) } == [saved])
    }

    @Test("删除核对原版本并只移除目标及其元数据")
    func deleteRequiresOriginalAndPreservesOtherTools() throws {
        let db = try database()
        let first = stable(ShortcutToolDefinition(name: "one", metadata: ["token": .string("private")]))
        let second = stable(ShortcutToolDefinition(name: "two", metadata: ["keep": .int(2)]))
        _ = try db.write { try ShortcutToolStore.insertPrepared(preview([first, second]), in: $0) }
        var stale = first; stale.userDescription = "different"
        #expect(try db.write { try ShortcutToolStore.deleteOriginal(stale, in: $0) } == nil)
        #expect(try db.write { try ShortcutToolStore.deleteOriginal(first, in: $0) } == [second])
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM shortcut_tool_metadata WHERE tool_id = ?", arguments: [first.id.uuidString]) } == 0)
    }

    @Test("删除失败回滚已经删除的元数据")
    func deleteFailureKeepsMetadata() throws {
        let db = try database()
        let original = stable(ShortcutToolDefinition(name: "one", metadata: ["keep": .int(1)]))
        _ = try db.write { try ShortcutToolStore.insertPrepared(preview([original]), in: $0) }
        try db.write { try $0.execute(sql: "CREATE TRIGGER reject_delete BEFORE DELETE ON shortcut_tools BEGIN SELECT RAISE(ABORT, '拒绝测试删除'); END") }
        #expect(throws: DatabaseError.self) { try db.write { try ShortcutToolStore.deleteOriginal(original, in: $0) } }
        #expect(try db.read { try ShortcutToolStore.loadTools(from: $0) } == [original])
    }

    @Test("官方导出 URL 保留名称，桌面完成回调不自动读取剪贴板")
    func officialURLContainsPlatformAppropriateCallback() throws {
        let url = try #require(ShortcutToolManager.buildOfficialImportRunShortcutURL(shortcutName: "Name & 中文"))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "name" }?.value == "Name & 中文")
        let callbackText = try #require(query.first { $0.name == "x-success" }?.value)
        let callback = try #require(URL(string: callbackText))
        #if os(macOS)
        #expect(ShortcutURLRouter.normalizedCompletionURL(callback)?.path == "/template-status")
        #else
        #expect(callback.path == "/import")
        #endif
    }

    private func preview(_ tools: [ShortcutToolDefinition]) -> ShortcutPreparedImport {
        ShortcutPreparedImport(tools: tools, skippedCount: 0, invalidCount: 0, conflictNames: [])
    }

    private func stable(_ original: ShortcutToolDefinition) -> ShortcutToolDefinition {
        var tool = original
        // 固定可精确往返的时间，断言关注事务内容而非 Date 的纪元转换精度。
        let time = Date(timeIntervalSince1970: 100)
        tool.createdAt = time; tool.updatedAt = time; tool.lastImportedAt = time
        return tool
    }

    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { try $0.execute(sql: """
            CREATE TABLE shortcut_tools (
                id TEXT PRIMARY KEY, name TEXT, external_id TEXT, source TEXT, run_mode_hint TEXT,
                is_enabled INTEGER, user_description TEXT, generated_description TEXT,
                created_at REAL, updated_at REAL, last_imported_at REAL
            );
            CREATE TABLE shortcut_tool_metadata (
                tool_id TEXT, meta_key TEXT, value_type TEXT, string_value TEXT, number_value REAL,
                bool_value INTEGER, json_value_text TEXT
            );
            """) }
        return db
    }
}

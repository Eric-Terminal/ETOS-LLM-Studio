import Foundation
import Testing
@testable import ETOSCore

@Suite("角色扮演草稿保存", .serialized)
struct RoleplayDraftWriteTests {
    @Test("过期角色编辑与删除被拒绝，删除后的旧草稿不能复活")
    func staleCharacterDrafts() throws {
        let store = RoleplayStore.shared
        let draft = RoleplayCharacter(name: "桌面角色草稿", extensions: ["vendor": .string("保留")])
        defer { store.deleteCharacter(id: draft.id) }
        try store.saveCharacterDraft(draft, replacing: nil)
        let original = try #require(store.character(id: draft.id))
        var first = original
        first.description = "另一编辑器已保存"
        try store.saveCharacterDraft(first, replacing: original)
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveCharacterDraft(original, replacing: original) }
        #expect(!store.deleteCharacter(id: draft.id, expected: original))
        let latest = try #require(store.character(id: draft.id))
        #expect(latest.extensions == original.extensions)
        var invalid = latest
        invalid.initialVariables["non_finite"] = .double(.nan)
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveCharacterDraft(invalid, replacing: latest) }
        #expect(store.character(id: draft.id) == latest)
        #expect(store.deleteCharacter(id: draft.id, expected: latest))
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveCharacterDraft(latest, replacing: latest) }
        #expect(store.character(id: draft.id) == nil)
    }

    @Test("身份草稿保留元数据，过期删除不会清除会话身份")
    func personaDraftAndBinding() throws {
        let store = RoleplayStore.shared
        let draft = PersonaProfile(name: "桌面身份草稿", metadata: ["custom": .int(7)])
        let sessionID = UUID()
        defer { store.removeBinding(sessionID: sessionID); store.deletePersona(id: draft.id) }
        try store.savePersonaDraft(draft, replacing: nil)
        let original = try #require(store.persona(id: draft.id))
        store.upsertBinding(SessionRoleplayBinding(sessionID: sessionID, personaID: draft.id))
        var edited = original
        edited.pronouns = "用户"
        try store.savePersonaDraft(edited, replacing: original)
        #expect(!store.deletePersona(id: draft.id, expected: original))
        #expect(store.binding(sessionID: sessionID)?.personaID == draft.id)
        let latest = try #require(store.persona(id: draft.id))
        #expect(latest.metadata == original.metadata)
        #expect(store.deletePersona(id: draft.id, expected: latest))
        #expect(store.binding(sessionID: sessionID)?.personaID == nil)
        #expect(throws: RoleplayDraftWriteError.self) { try store.savePersonaDraft(latest, replacing: latest) }
    }

    @Test("同一角色的并发草稿仅一份成功，空名称和重复新增不能覆盖角色")
    func concurrentDrafts() async throws {
        let store = RoleplayStore.shared
        let draft = RoleplayCharacter(name: " 并发草稿 ")
        defer { store.deleteCharacter(id: draft.id) }
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveCharacterDraft(RoleplayCharacter(name: " \n"), replacing: nil) }
        #expect(throws: RoleplayDraftWriteError.self) { try store.savePersonaDraft(PersonaProfile(name: " \n"), replacing: nil) }
        try store.saveCharacterDraft(draft, replacing: nil)
        let original = try #require(store.character(id: draft.id))
        #expect(original.name == "并发草稿")
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveCharacterDraft(draft, replacing: nil) }
        let count = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<2 {
                group.addTask {
                    var edited = original
                    edited.description = "\(index)"
                    do { try store.saveCharacterDraft(edited, replacing: original); return true }
                    catch { return false }
                }
            }
            var successes = 0
            for await result in group where result { successes += 1 }
            return successes
        }
        #expect(count == 1)
    }

    @Test("过期头像草稿不覆盖当前文件，失败时删除临时头像")
    func staleAvatarPreservesCurrentFile() throws {
        let service = ChatService.shared
        let store = RoleplayStore.shared
        let persona = PersonaProfile(name: "头像保存回归")
        defer { store.deletePersona(id: persona.id) }
        // 本用例核对文件原字节与回滚；图像解码由平台编辑器在输入边界完成。
        let firstData = Data([137, 80, 78, 71, 1])
        try service.savePersonaDraft(persona, replacing: nil, avatarData: firstData)
        let original = try #require(store.persona(id: persona.id))
        let originalName = try #require(original.avatarFileName)
        let directory = Persistence.getImageDirectory()
        let latestData = Data([137, 80, 78, 71, 2])
        try service.savePersonaDraft(original, replacing: original, avatarData: latestData)
        let latest = try #require(store.persona(id: persona.id))
        let latestName = try #require(latest.avatarFileName)
        #expect(latestName != originalName)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(originalName).path))
        #expect(throws: RoleplayDraftWriteError.self) { try service.savePersonaDraft(original, replacing: original, avatarData: firstData) }
        #expect(try Data(contentsOf: directory.appendingPathComponent(latestName)) == latestData)
        let personaFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(persona.id.uuidString) }
        #expect(personaFiles == [latestName])
    }

    @Test("导入卡片头像复用已安装资源，删除会清除头像与内嵌世界书")
    func importedAvatarUsesInstalledAsset() throws {
        let data = Data(#"{"spec":"chara_card_v3","spec_version":"3.0","data":{"name":"导入资源回归","assets":[{"type":"icon","uri":"data:image/png;base64,iVBORw0KGgo=","name":"main","ext":"png"}],"character_book":{"name":"测试世界书","entries":[{"keys":["key"],"content":"内容","enabled":true}]}}}"#.utf8)
        let service = ChatService.shared
        let result = try service.importRoleplayCard(data: data, fileName: "draft-test.json")
        defer { service.deleteRoleplayCharacter(id: result.character.id) }
        let saved = try #require(RoleplayStore.shared.character(id: result.character.id))
        let asset = try #require(saved.assets?.first?.localFileName)
        #expect(saved.avatarFileName == asset)
        let url = Persistence.getImageDirectory().appendingPathComponent(asset)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let worldbookID = try #require(saved.embeddedWorldbookID)
        #expect(WorldbookStore.shared.loadWorldbooks().contains { $0.id == worldbookID })
        try service.deleteRoleplayCharacterDraft(saved)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!WorldbookStore.shared.loadWorldbooks().contains { $0.id == worldbookID })
    }
}

import Foundation
import Testing
@testable import ETOSCore

@Suite("角色宏与变量作用域草稿", .serialized)
struct RoleplayDataDraftTests {
    @Test("读取旧格式草稿不隐式迁移，显式清空后旧值不会重新出现")
    func readingLegacyDraftDoesNotWrite() throws {
        let store = RoleplayStore.shared
        let sessionID = UUID()
        let character = RoleplayCharacter(name: "旧变量格式")
        defer { store.removeBinding(sessionID: sessionID); store.deleteCharacter(id: character.id) }
        try store.saveCharacterDraft(character, replacing: nil)
        store.upsertBinding(.init(sessionID: sessionID, characterIDs: [character.id]))
        let written = store.queue.sync {
            var sessions = store.loadVariablesUnlocked()
            sessions[sessionID] = RoleplayVariableSnapshot(character: ["legacy": .int(1)])
            return store.saveVariablesUnlocked(sessions)
        }
        #expect(written)
        let draft = try store.dataDraft(sessionID: sessionID, target: .variables(.character, messageID: nil, versionIndex: 0))
        #expect(draft.originalValues == ["legacy": .int(1)])
        #expect(store.queue.sync { store.loadSharedVariablesUnlocked().characters[character.id] } == nil)
        try store.saveDataDraft(draft, values: [:])
        #expect(store.variableSnapshot(sessionID: sessionID).character.isEmpty)
        #expect(try store.dataDraft(sessionID: sessionID, target: draft.target).originalValues.isEmpty)
    }

    @Test("不同作用域独立保存，旧草稿不会覆盖同层的新值")
    func scopedWritesAndConflicts() throws {
        let store = RoleplayStore.shared
        let sessionID = UUID()
        let character = RoleplayCharacter(name: "变量草稿角色")
        defer { store.removeBinding(sessionID: sessionID); store.deleteCharacter(id: character.id) }
        try store.saveCharacterDraft(character, replacing: nil)
        store.upsertBinding(.init(sessionID: sessionID, characterIDs: [character.id]))
        let macros = try store.dataDraft(sessionID: sessionID, target: .macros)
        let chat = try store.dataDraft(sessionID: sessionID, target: .variables(.chat, messageID: nil, versionIndex: 0))
        let role = try store.dataDraft(sessionID: sessionID, target: .variables(.character, messageID: nil, versionIndex: 0))
        try store.saveDataDraft(chat, values: ["plot": .int(2)])
        try store.saveDataDraft(role, values: ["score": .int(5)])
        try store.saveDataDraft(macros, values: [" hero ": .string("主角")])
        let updated = store.variableSnapshot(sessionID: sessionID)
        #expect(updated.chat == ["plot": .int(2)])
        #expect(updated.character == ["score": .int(5)])
        #expect(updated.customMacros == ["hero": "主角"])
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveDataDraft(chat, values: [:]) }
        let latest = try store.dataDraft(sessionID: sessionID, target: chat.target)
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveDataDraft(latest, values: ["invalid": .double(.nan)]) }
        #expect(store.variableSnapshot(sessionID: sessionID).chat == latest.originalValues)
        let latestRole = try store.dataDraft(sessionID: sessionID, target: role.target)
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveDataDraft(latestRole, values: ["invalid": .double(.nan)]) }
        #expect(store.variableSnapshot(sessionID: sessionID).character == latestRole.originalValues)
    }

    @Test("改绑后不能把旧角色变量写入新角色，即使原变量相同")
    func bindingIdentityIsPinned() throws {
        let store = RoleplayStore.shared
        let sessionID = UUID()
        let first = RoleplayCharacter(name: "旧角色"), second = RoleplayCharacter(name: "新角色")
        defer { store.removeBinding(sessionID: sessionID); store.deleteCharacter(id: first.id); store.deleteCharacter(id: second.id) }
        try store.saveCharacterDraft(first, replacing: nil)
        try store.saveCharacterDraft(second, replacing: nil)
        store.upsertBinding(.init(sessionID: sessionID, characterIDs: [first.id]))
        let old = try store.dataDraft(sessionID: sessionID, target: .variables(.character, messageID: nil, versionIndex: 0))
        store.upsertBinding(.init(sessionID: sessionID, characterIDs: [second.id]))
        #expect(throws: RoleplayDraftWriteError.self) { try store.saveDataDraft(old, values: ["wrong": .bool(true)]) }
        #expect(store.variableSnapshot(sessionID: sessionID).character.isEmpty)
        #expect(throws: RoleplayDataDraftError.self) { try store.dataDraft(sessionID: sessionID, target: .variables(.persona, messageID: nil, versionIndex: 0)) }
        #expect(throws: RoleplayDataDraftError.self) { try store.dataDraft(sessionID: sessionID, target: .variables(.message, messageID: nil, versionIndex: 0)) }
    }

    @Test("脚本和消息变量保留内部空间，并拒绝直接注入保留字段")
    func internalVariableSpacesArePreserved() throws {
        let store = RoleplayStore.shared
        let sessionID = UUID(), scriptID = UUID(), messageID = UUID()
        defer { store.removeBinding(sessionID: sessionID) }
        var snapshot = store.variableSnapshot(sessionID: sessionID)
        snapshot.replaceCustomMacros(["hero": "用户"])
        snapshot.replaceScriptVariables(["private": .int(1)], scriptID: scriptID)
        snapshot.replacePromptTemplateInitialVariables(["initial": .int(2)])
        snapshot.setValue(.string("缓存 HTML"), scope: .message, path: RoleplayDisplayedMessageBridge.variableKey, messageID: messageID, versionIndex: 1)
        store.saveVariableSnapshot(snapshot, sessionID: sessionID)
        let script = try store.dataDraft(sessionID: sessionID, target: .variables(.script, messageID: nil, versionIndex: 0))
        #expect(script.originalValues.isEmpty)
        let updatedScript = try store.saveDataDraft(script, values: ["visible": .int(3)])
        #expect(throws: RoleplayDataDraftError.self) { try store.saveDataDraft(updatedScript, values: ["__etos_custom_macros": .dictionary([:])]) }
        let message = try store.dataDraft(sessionID: sessionID, target: .variables(.message, messageID: messageID, versionIndex: 1))
        let updatedMessage = try store.saveDataDraft(message, values: ["health": .int(4)])
        #expect(throws: RoleplayDataDraftError.self) {
            try store.saveDataDraft(updatedMessage, values: [RoleplayDisplayedMessageBridge.variableKey: .string("替换缓存")])
        }
        let saved = store.variableSnapshot(sessionID: sessionID)
        #expect(saved.customMacros == ["hero": "用户"])
        #expect(saved.scriptVariables(scriptID: scriptID) == ["private": .int(1)])
        #expect(saved.promptTemplateInitialVariables == ["initial": .int(2)])
        #expect(saved.scopedVariables(.script) == ["visible": .int(3)])
        #expect(saved.messageVariables(messageID: messageID, versionIndex: 1) == ["health": .int(4)])
        #expect(saved.value(scope: .message, path: RoleplayDisplayedMessageBridge.variableKey, messageID: messageID, versionIndex: 1) == .string("缓存 HTML"))
        #expect(saved.messageVariables(messageID: messageID, versionIndex: 0).isEmpty)
    }

    @Test("消息变量固定来源会话，回复版本变化后拒绝保存")
    func messageVersionAndSessionArePinned() throws {
        let store = RoleplayStore.shared
        let service = ChatService(roleplayStore: store)
        let first = service.createSavedSession(name: "变量来源"), second = service.createSavedSession(name: "另一个会话")
        defer { store.removeBinding(sessionID: first.id); store.removeBinding(sessionID: second.id); service.deleteSessions([first, second]) }
        let message = ChatMessage(role: .assistant, content: "第一版")
        service.updateMessages([message], for: first.id)
        service.updateMessages([message], for: second.id)
        let source = try service.roleplayDataDraft(sessionID: first.id, target: .variables(.message, messageID: message.id, versionIndex: 0))
        let saved = try service.saveRoleplayDataDraft(source, values: ["score": .int(1)], matching: message)
        #expect(store.variableSnapshot(sessionID: first.id).messageVariables(messageID: message.id, versionIndex: 0) == ["score": .int(1)])
        #expect(store.variableSnapshot(sessionID: second.id).messageVersions.isEmpty)
        var changed = message
        changed.addVersion("第二版")
        service.updateMessages([changed], for: first.id)
        #expect(throws: RoleplayDraftWriteError.self) { try service.saveRoleplayDataDraft(saved, values: [:], matching: message) }
        #expect(store.variableSnapshot(sessionID: first.id).messageVariables(messageID: message.id, versionIndex: 0) == ["score": .int(1)])
    }

    @Test("宏名称规范化拒绝冲突和非字符串值，向导沿用相同规则")
    func macroNormalizationRejectsDataLoss() throws {
        #expect(try RoleplayDataDraft.normalizeMacros([" hero ": .string("保留空格值 ")]) == ["hero": .string("保留空格值 ")])
        let invalidValues: [[String: JSONValue]] = [["": .string("空名")], ["{{name}}": .string("宏")], ["value": .int(1)], ["hero": .string("甲"), " hero ": .string("乙")], ["Hero": .string("甲"), "hero": .string("乙")]]
        for values in invalidValues {
            #expect(throws: RoleplayDataDraftError.self) { try RoleplayDataDraft.normalizeMacros(values) }
            #expect(throws: GuideError.self) { try GuideRoleplayDataSettingsSupport.normalizeMacros(.dictionary(values)) }
        }
    }
}

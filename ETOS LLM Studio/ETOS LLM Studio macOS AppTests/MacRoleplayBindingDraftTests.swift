import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacRoleplayBindingDraftTests {
    @Test("单角色编辑器保留未修改的多角色和世界书引用，固定来源会话")
    func preservesOtherBindingFields() {
        let first = UUID(), second = UUID(), book = UUID(), persona = UUID(), message = UUID()
        let original = SessionRoleplayBinding(sessionID: UUID(), characterIDs: [first, second], personaID: persona,
                                             additionalWorldbookIDs: [book], selectedGreetingIndex: 3, seededGreetingMessageID: message)
        var draft = MacRoleplayBindingDraft(sessionID: original.sessionID, original: original, preferredPersonaID: UUID())
        draft.helperScriptsEnabled = false
        let saved = draft.preparedBinding()
        #expect(saved.sessionID == original.sessionID)
        #expect(saved.characterIDs == [first, second] && saved.additionalWorldbookIDs == [book])
        #expect(saved.selectedGreetingIndex == 3 && saved.seededGreetingMessageID == message)
        #expect(saved.personaID == persona && !saved.helperScriptsEnabled)
        let replacement = UUID()
        draft.characterID = replacement.uuidString
        #expect(draft.preparedBinding().characterIDs == [replacement])
        draft.characterID = ""
        #expect(draft.preparedBinding().characterIDs.isEmpty)
        #expect(draft.preparedBinding().additionalWorldbookIDs == [book])
        draft.characterID = first.uuidString
        #expect(draft.preparedBinding().characterIDs == original.characterIDs)
    }

    @Test("默认身份只用于未绑定会话，已有的空身份不会被覆盖")
    func preferredPersonaOnlyForNewBinding() {
        let sessionID = UUID(), preferred = UUID()
        let fresh = MacRoleplayBindingDraft(sessionID: sessionID, original: nil, preferredPersonaID: preferred)
        #expect(fresh.preparedBinding().personaID == preferred)
        let existing = MacRoleplayBindingDraft(sessionID: sessionID, original: .init(sessionID: sessionID), preferredPersonaID: preferred)
        #expect(existing.personaID.isEmpty && existing.preparedBinding().personaID == nil)
    }

    @Test("开场白目录保留原索引，缺失引用仍有可选项")
    func greetingIndicesAndMissingReferences() throws {
        let character = RoleplayCharacter(name: "角色", firstMessage: " \n", alternateGreetings: [" 第一条 ", "", "第二条"])
        let missingCharacter = UUID(), missingPersona = UUID()
        let binding = SessionRoleplayBinding(sessionID: UUID(), characterIDs: [missingCharacter], personaID: missingPersona)
        let catalog = MacRoleplayBindingCatalog.prepare(characters: [character], personas: [], original: binding)
        let greetings = try #require(catalog.greetings[character.id.uuidString])
        #expect(greetings.rows.map(\.id) == [1, 3])
        #expect(greetings.guideIDs == ["1", "3"])
        #expect(greetings.byIndex[1]?.text == "第一条" && greetings.byIndex[0] == nil)
        #expect(catalog.characterIDSet.contains(missingCharacter.uuidString))
        #expect(catalog.personaIDSet.contains(missingPersona.uuidString))
        #expect(catalog.characterIDs.first == "" && catalog.personaIDs.first == "")
    }
}

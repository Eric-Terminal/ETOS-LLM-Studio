import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacRoleplaySnapshotTests {
    @Test("角色草稿只改编辑字段，保留资源、正则、脚本与未知扩展")
    func preservesImportedCharacterData() throws {
        let character = RoleplayCharacter(
            name: "角色", alternateGreetings: ["\n开场白\n", ""], regexRules: [RoleplayRegexRule(scriptName: "规则", findRegex: "original")],
            helperScripts: [RoleplayHelperScript(name: "助手", content: "console.log('preserve')")],
            assets: [RoleplayCardAsset(type: "icon", uri: "embeded://icon.png", name: "main", fileExtension: "png")],
            initialVariables: ["old": .int(1)], extensions: ["unknown": .string("保留")], rawCardData: ["raw": .bool(true)]
        )
        var draft = MacRoleplayCharacterDraft(character: character)
        draft.character.name = " 新角色 "
        draft.tags = "甲，乙\n 丙 "
        draft.variablesJSON = #"{"score":8,"enabled":true}"#
        let prepared = try draft.preparedCharacter()
        #expect(prepared.name == "新角色")
        #expect(prepared.tags == ["甲", "乙", "丙"])
        #expect(prepared.initialVariables == ["score": .int(8), "enabled": .bool(true)])
        #expect(prepared.alternateGreetings == character.alternateGreetings)
        #expect(prepared.assets == character.assets)
        #expect(prepared.regexRules == character.regexRules)
        #expect(prepared.helperScripts == character.helperScripts)
        #expect(prepared.extensions == character.extensions && prepared.rawCardData == character.rawCardData)
        #expect(draft.original == character)
    }

    @Test("搜索保留完整详情索引，匹配作者、标签和身份描述")
    func searchAndIndices() {
        let character = RoleplayCharacter(name: "角色", tags: ["标签词"], creator: "作者词")
        let another = RoleplayCharacter(name: "其他")
        let persona = PersonaProfile(name: "身份", description: "资料词")
        let hidden = MacRoleplaySnapshot.prepare(characters: [character, another], personas: [persona], query: "不存在")
        #expect(hidden.characters.isEmpty && hidden.personas.isEmpty)
        #expect(hidden.charactersByID.count == 2 && hidden.personasByID.count == 1)
        #expect(MacRoleplaySnapshot.prepare(characters: [character], personas: [], query: "标签词").characters.count == 1)
        #expect(MacRoleplaySnapshot.prepare(characters: [character], personas: [], query: "作者词").characters.count == 1)
        #expect(MacRoleplaySnapshot.prepare(characters: [], personas: [persona], query: "资料词").personas.count == 1)
    }

    @Test("无效初始变量和空名称不会生成可保存资料")
    func rejectsInvalidDraft() {
        var draft = MacRoleplayCharacterDraft(character: RoleplayCharacter(name: "角色"), isNew: true)
        #expect(draft.original == nil)
        draft.variablesJSON = "[]"
        #expect(throws: MacRoleplayDraftError.self) { try draft.preparedCharacter() }
        draft.variablesJSON = "{}"
        draft.character.name = " \n"
        #expect(throws: RoleplayDraftWriteError.self) { try draft.preparedCharacter() }
    }
}

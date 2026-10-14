import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacRoleplayContentDraftTests {
    @Test("只编辑正则可见字段，保留深度、扩展、列表顺序和其余角色资料")
    func regexPreservesImportedFields() {
        let rule = RoleplayRegexRule(scriptName: "规则", findRegex: "/old/gi", replaceString: "$1", trimStrings: [" ", "\n", "保留 "],
                                     placements: [.reasoning, .aiOutput], scope: .preset, minDepth: 2, maxDepth: 8,
                                     substituteRegex: 17, metadata: ["vendor": .dictionary(["keep": .bool(true)])])
        let other = RoleplayRegexRule(scriptName: "下一条", findRegex: "next")
        let script = RoleplayHelperScript(name: "助手", content: "console.log('kept')")
        let character = RoleplayCharacter(name: "角色", firstMessage: "开场", embeddedWorldbookID: UUID(), regexRules: [rule, other],
                                          helperScripts: [script], extensions: ["vendor": .string("角色扩展")])
        var draft = MacRoleplayRegexDraft(rule: rule, in: character)
        #expect(draft.preparedCharacter() == character)
        draft.rule.findRegex = "/new/m"
        draft.rule.disabled = true
        let saved = draft.preparedCharacter()
        #expect(saved.regexRules.map(\.id) == [rule.id, other.id])
        #expect(saved.regexRules[0].findRegex == "/new/m" && saved.regexRules[0].disabled)
        #expect(saved.regexRules[0].minDepth == 2 && saved.regexRules[0].maxDepth == 8)
        #expect(saved.regexRules[0].substituteRegex == 17 && saved.regexRules[0].metadata == rule.metadata)
        #expect(saved.regexRules[0].trimStrings == rule.trimStrings && saved.regexRules[0].placements == rule.placements)
        #expect(saved.regexRules[1] == other && saved.helperScripts == [script])
        #expect(saved.extensions == character.extensions && saved.embeddedWorldbookID == character.embeddedWorldbookID)
        #expect(draft.originalCharacter == character)
    }

    @Test("新增规则追加到末尾，修剪字符串的空格按字面保留")
    func addedRuleAndLiteralTrimStrings() {
        let original = RoleplayRegexRule(scriptName: "已有")
        let character = RoleplayCharacter(name: "角色", regexRules: [original])
        let added = RoleplayRegexRule(scriptName: "新增")
        var draft = MacRoleplayRegexDraft(rule: added, in: character)
        draft.trimStringsText = " 前缀 \n\n \n后缀\n"
        let saved = draft.preparedCharacter()
        #expect(saved.regexRules.map(\.id) == [original.id, added.id])
        #expect(saved.regexRules[0] == original)
        #expect(saved.regexRules[1].trimStrings == [" 前缀 ", " ", "后缀"])
        let input = MacRoleplayRegexDraft(rule: saved.regexRules[1], in: saved)
        #expect(input.preparedCharacter() == saved)
    }

    @Test("脚本内容编辑保留按钮、扩展和同卡的其他脚本")
    func scriptPreservesButtonsAndMetadata() {
        let button = RoleplayScriptButton(name: "操作", visible: false, metadata: ["key": .string("imported")])
        let script = RoleplayHelperScript(name: "助手", content: "old()", buttons: [button], metadata: ["custom": .int(9)])
        let other = RoleplayHelperScript(name: "另一个", content: "next()")
        let regex = RoleplayRegexRule(scriptName: "正则", findRegex: "keep")
        let character = RoleplayCharacter(name: "角色", regexRules: [regex], helperScripts: [script, other], rawCardData: ["original": .bool(true)])
        var draft = MacRoleplayScriptDraft(script: script, in: character)
        draft.script.content = "updated()"
        draft.script.info = "说明"
        draft.script.enabled = false
        let saved = draft.preparedCharacter()
        #expect(saved.helperScripts.map(\.id) == [script.id, other.id])
        #expect(saved.helperScripts[0].buttons == [button] && saved.helperScripts[0].metadata == script.metadata)
        #expect(saved.helperScripts[0].content == "updated()" && !saved.helperScripts[0].enabled)
        #expect(saved.helperScripts[1] == other && saved.regexRules == [regex])
        #expect(saved.rawCardData == character.rawCardData && draft.originalCharacter == character)
        let added = RoleplayHelperScript(name: "新脚本", content: "newScript()")
        let appended = MacRoleplayScriptDraft(script: added, in: saved).preparedCharacter()
        #expect(appended.helperScripts == saved.helperScripts + [added])
    }

    @Test("角色内容目录保留停用条目，向导目录不泄露脚本正文和元数据")
    func contentSnapshotPrivacyAndOrder() {
        let secret = "SECRET_SHOULD_NOT_BE_IN_GUIDE"
        let first = RoleplayRegexRule(scriptName: "第一条", findRegex: String(repeating: "a", count: 220), disabled: true)
        let second = RoleplayRegexRule(scriptName: "第二条", findRegex: "b")
        let script = RoleplayHelperScript(name: "脚本", content: secret, info: secret, enabled: false, metadata: ["token": .string(secret)])
        let character = RoleplayCharacter(name: "角色", regexRules: [first, second], helperScripts: [script])
        let content = MacRoleplayContentSnapshot(character: character)
        #expect(content.regex.map(\.id) == [first.id, second.id])
        #expect(content.regex[0].preview.count == 180 && content.regex[0].rule.disabled)
        #expect(content.scripts[0].script == script)
        #expect(!content.scriptsGuideValue.prettyPrinted().contains(secret))
        let snapshot = MacRoleplaySnapshot.prepare(characters: [character], personas: [], query: "不匹配")
        #expect(snapshot.characters.isEmpty)
        #expect(snapshot.charactersByID[character.id]?.content.regex.map(\.id) == [first.id, second.id])
    }
}

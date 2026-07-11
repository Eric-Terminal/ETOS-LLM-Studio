// ============================================================================
// RoleplayCompatibilityTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 使用合成夹具验证角色卡、宏、正则、MVU 与 HTML 兼容运行时。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("角色扮演与酒馆兼容")
struct RoleplayCompatibilityTests {
    @Test("导入 Character Card V3 的角色资料、世界书、正则和助手脚本")
    func importV3JSON() throws {
        let json = """
        {
          "spec": "chara_card_v3",
          "spec_version": "3.0",
          "data": {
            "name": "星野",
            "description": "{{char}} 是向导。",
            "personality": "冷静",
            "scenario": "与 {{user}} 在车站相遇。",
            "first_mes": "你好，{{user}}。",
            "alternate_greetings": ["又见面了。"],
            "mes_example": "<START>\n{{user}}：出发吧。",
            "system_prompt": "始终保持角色。",
            "post_history_instructions": "用角色口吻继续。",
            "tags": ["测试"],
            "creator": "ETOS Test",
            "character_version": "1.2",
            "character_book": {
              "name": "星野世界书",
              "entries": [
                { "id": 1, "keys": ["车站"], "content": "车站位于海边。", "enabled": true }
              ]
            },
            "extensions": {
              "regex_scripts": [
                {
                  "id": "00000000-0000-0000-0000-000000000001",
                  "scriptName": "状态栏",
                  "findRegex": "/<status>([\\s\\S]*?)<\\/status>/gi",
                  "replaceString": "```html\\n<div>$1</div>\\n```",
                  "placement": [2],
                  "markdownOnly": true,
                  "substituteRegex": 1
                }
              ],
              "tavern_helper": {
                "scripts": [
                  {
                    "type": "script",
                    "id": "00000000-0000-0000-0000-000000000002",
                    "name": "变量按钮",
                    "enabled": true,
                    "content": "setVariable('好感度', 10);",
                    "button": { "enabled": true, "buttons": [{ "name": "确认", "visible": true }] }
                  }
                ]
              }
            }
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let result = try RoleplayCardImportService().importCard(from: data, fileName: "星野.json")

        #expect(result.character.name == "星野")
        #expect(result.character.sourceSpec == "chara_card_v3")
        #expect(result.character.alternateGreetings == ["又见面了。"])
        #expect(result.character.regexRules.count == 1)
        #expect(result.character.regexRules.first?.substituteRegex == 1)
        #expect(result.character.helperScripts.first?.buttons.first?.name == "确认")
        #expect(result.embeddedWorldbook?.name == "星野世界书")
        #expect(result.embeddedWorldbook?.entries.first?.content == "车站位于海边。")
    }

    @Test("从 PNG chara 文本块导入 V2 角色卡")
    func importV2PNG() throws {
        let json = """
        {
          "spec": "chara_card_v2",
          "spec_version": "2.0",
          "data": {
            "name": "PNG 角色",
            "description": "PNG metadata",
            "first_mes": "Hello"
          }
        }
        """
        let png = makePNGTextCard(keyword: "chara", json: json)
        let result = try RoleplayCardImportService().importCard(from: png, fileName: "card.png")

        #expect(result.character.name == "PNG 角色")
        #expect(result.character.sourceSpecVersion == "2.0")
        #expect(result.avatarPNGData == png)
    }

    @Test("宏解析角色、Persona、消息变量与稳定 pick")
    func resolveMacros() {
        let messageID = UUID()
        var variables = RoleplayVariableSnapshot(global: ["天气": .string("晴")])
        variables.setValue(
            .dictionary(["好感度": .array([.int(7), .string("当前值")])]),
            scope: .message,
            path: "stat_data",
            messageID: messageID,
            versionIndex: 1
        )
        let context = RoleplayMacroContext(
            character: RoleplayCharacter(name: "星野", scenario: "测试"),
            persona: PersonaProfile(name: "旅行者", description: "来自北方"),
            variables: variables,
            messageID: messageID,
            messageVersionIndex: 1,
            lastUserMessage: "走吧",
            chatSeed: "session-a",
            customValues: ["custom": "自定义"]
        )
        let input = "{{user}}/{{char}} {{get_message_variable::stat_data.好感度[0]}} {{get_global_variable::天气}} {{pick::甲::乙}} {{custom}}"
        let first = RoleplayMacroResolver.resolve(input, context: context)
        let second = RoleplayMacroResolver.resolve(input, context: context)

        #expect(first.contains("旅行者/星野 7 晴"))
        #expect(first.hasSuffix("自定义"))
        #expect(first == second)
    }

    @Test("宏支持三花括号、中文名称与递归自定义值")
    func resolveTripleAndCustomMacros() {
        let context = RoleplayMacroContext(
            character: RoleplayCharacter(name: "星野"),
            persona: PersonaProfile(name: "旅行者"),
            customValues: ["地点": "海边", "问候": "{{user}}，去{{地点}}吧"]
        )

        let output = RoleplayMacroResolver.resolve("{{{问候}}} / {{{char}}}", context: context)

        #expect(output == "旅行者，去海边吧 / 星野")
    }

    @Test("宏兼容旧名称、楼层、裁剪、注释与日期格式")
    func resolveLegacyAndUtilityMacros() {
        let context = RoleplayMacroContext(
            character: RoleplayCharacter(name: "星野"),
            persona: PersonaProfile(name: "旅行者"),
            lastUserMessage: "继续",
            messageCount: 4,
            now: Date(timeIntervalSince1970: 0),
            locale: Locale(identifier: "en_US_POSIX")
        )
        let input = "<USER>/<BOT> {{lastMessageId}} {{input}}\n{{trim}}\n{{reverse:{{user}}}} {{isodate}} {{//隐藏}}"
        let output = RoleplayMacroResolver.resolve(input, context: context)

        #expect(output == "旅行者/星野 3 继续者行旅 1970-01-01 ")
    }

    @Test("消息变量按消息版本隔离")
    func isolateMessageVersions() {
        let messageID = UUID()
        var snapshot = RoleplayVariableSnapshot()
        snapshot.setValue(.int(1), scope: .message, path: "value", messageID: messageID, versionIndex: 0)
        snapshot.setValue(.int(2), scope: .message, path: "value", messageID: messageID, versionIndex: 1)

        #expect(snapshot.value(scope: .message, path: "value", messageID: messageID, versionIndex: 0) == .int(1))
        #expect(snapshot.value(scope: .message, path: "value", messageID: messageID, versionIndex: 1) == .int(2))
        snapshot.removeMessageVariables(messageID: messageID)
        #expect(snapshot.messageVariables(messageID: messageID, versionIndex: 0).isEmpty)
        #expect(snapshot.messageVariables(messageID: messageID, versionIndex: 1).isEmpty)
    }

    @Test("分层变量替换会清空旧值并持久承载自定义宏")
    func replaceScopedVariablesAndMacros() {
        var snapshot = RoleplayVariableSnapshot(chat: ["旧值": .int(1), "保留": .bool(true)])
        snapshot.replaceVariables(["新值": .int(2)], scope: .chat)
        snapshot.replaceCustomMacros(["称呼": "旅行者", "空白键": "保留"])

        #expect(snapshot.scopedVariables(.chat) == ["新值": .int(2)])
        #expect(snapshot.customMacros["称呼"] == "旅行者")
        #expect(snapshot.mergedVariables()["__etos_custom_macros"] == nil)
        #expect(snapshot.scopedVariables(.script)["__etos_custom_macros"] == nil)
    }

    @Test("MVU lodash 命令更新 stat_data 并隐藏更新块")
    func applyLodashMVU() {
        let messageID = UUID()
        var snapshot = RoleplayVariableSnapshot()
        snapshot.setValue(
            .dictionary([
                "金币": .array([.int(10), .string("货币")]),
                "地点": .array([.string("车站"), .string("当前位置")])
            ]),
            scope: .message,
            path: "stat_data",
            messageID: messageID,
            versionIndex: 0
        )
        let content = """
        正文
        <UpdateVariable>
        <Analysis>更新状态</Analysis>
        _.add('金币[0]', 5);//奖励
        _.set('地点[0]', '车站', '海边');//移动
        </UpdateVariable>
        """
        let result = RoleplayMVUEngine.applyUpdates(
            in: content,
            snapshot: snapshot,
            messageID: messageID,
            versionIndex: 0
        )

        #expect(result.appliedCommandCount == 2)
        #expect(result.visibleContent == "正文")
        #expect(result.updatedSnapshot.value(
            scope: .message,
            path: "stat_data.金币[0]",
            messageID: messageID,
            versionIndex: 0
        )?.numericValue == 15)
        #expect(result.updatedSnapshot.value(
            scope: .message,
            path: "stat_data.地点[0]",
            messageID: messageID,
            versionIndex: 0
        ) == .string("海边"))
    }

    @Test("MVU JSON Patch 支持 replace、delta、insert 和 remove")
    func applyJSONPatchMVU() {
        let messageID = UUID()
        var snapshot = RoleplayVariableSnapshot()
        snapshot.setValue(
            .dictionary(["数值": .int(4), "列表": .array([.string("a")])]),
            scope: .message,
            path: "stat_data",
            messageID: messageID,
            versionIndex: 0
        )
        let content = """
        <UpdateVariable><JSONPatch>
        [
          {"op":"delta","path":"/数值","value":3},
          {"op":"insert","path":"/列表","value":"b"},
          {"op":"replace","path":"/名称","value":"新状态"}
        ]
        </JSONPatch></UpdateVariable>
        """
        let result = RoleplayMVUEngine.applyUpdates(
            in: content,
            snapshot: snapshot,
            messageID: messageID,
            versionIndex: 0
        )

        #expect(result.appliedCommandCount == 3)
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.数值", messageID: messageID) == .double(7))
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.列表[1]", messageID: messageID) == .string("b"))
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.名称", messageID: messageID) == .string("新状态"))
    }

    @Test("角色正则支持 JavaScript 字面量、命名捕获、trim 和宏")
    func transformRoleplayRegex() {
        let context = RoleplayMacroContext(
            character: RoleplayCharacter(name: "星野"),
            persona: PersonaProfile(name: "旅行者")
        )
        let rule = RoleplayRegexRule(
            findRegex: #"/<status name="(?<name>[^"]+)">([\s\S]*?)<\/status>/gi"#,
            replaceString: "```html\n<div>{{user}}:$<name>:$2</div>\n```",
            trimStrings: ["隐藏"],
            placements: [.aiOutput],
            markdownOnly: true
        )
        let output = RoleplayRegexTransformer.apply(
            "<status name=\"面板\">公开隐藏</status>",
            rules: [rule],
            context: .init(placement: .aiOutput, isMarkdown: true, macroContext: context)
        )

        #expect(output.contains("<div>旅行者:面板:公开</div>"))
    }

    @Test("HTML 提取保留普通正文并注入酒馆助手兼容桥")
    func extractAndWrapHTML() {
        let content = """
        叙事正文

        ```html
        <div><button onclick="sendMessage('继续')">继续</button></div>
        ```
        """
        let extraction = RoleplayHTMLExtractor.extract(from: content)
        let document = RoleplayHTMLDocumentFactory.makeDocument(
            source: extraction.documents.first?.source ?? "",
            variables: ["金币": .int(5)],
            userName: "旅行者",
            characterName: "星野",
            userAvatarPath: "user.png",
            characterAvatarPath: "char.png",
            worldbooks: [
                Worldbook(
                    name: "测试世界书",
                    entries: [WorldbookEntry(content: "海边车站", keys: ["车站"])]
                )
            ]
        )

        #expect(extraction.remainingText == "叙事正文")
        #expect(extraction.documents.count == 1)
        #expect(document.contains("window.TavernHelper"))
        #expect(document.contains("etosRoleplay"))
        #expect(document.contains("sendMessage"))
        #expect(document.contains("ResizeObserver"))
        #expect(document.contains("scopeVariables"))
        #expect(document.contains("deleteVariable"))
        #expect(document.contains("setChatMessages"))
        #expect(document.contains("createWorldbookEntries"))
        #expect(document.contains("测试世界书"))
        #expect(document.contains("playAudio"))
    }

    private func makePNGTextCard(keyword: String, json: String) -> Data {
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let encoded = Data(json.utf8).base64EncodedString()
        var text = Data(keyword.utf8)
        text.append(0)
        text.append(Data(encoded.utf8))
        appendChunk(type: "tEXt", payload: text, to: &png)
        appendChunk(type: "IEND", payload: Data(), to: &png)
        return png
    }

    private func appendChunk(type: String, payload: Data, to data: inout Data) {
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(Data(type.utf8))
        data.append(payload)
        appendUInt32(0, to: &data)
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }
}

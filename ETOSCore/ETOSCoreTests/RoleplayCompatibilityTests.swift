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
import ZIPFoundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

@Suite("角色扮演与酒馆兼容")
struct RoleplayCompatibilityTests {

    @Test("世界书 outlet 宏只在引用位置展开")
    func resolvesWorldbookOutletMacrosAtReferenceSite() {
        let resolved = RoleplayMacroResolver.resolveWorldbookOutlets(
            "前文 {{outlet::角色状态}} 后文 {{outlet::不存在}}",
            outlets: ["角色状态": "生命值：80"]
        )

        #expect(resolved == "前文 生命值：80 后文 ")
    }

    #if canImport(JavaScriptCore)
    @Test("提示词模板执行 EJS 并预激活世界书条目")
    func rendersPromptTemplateAndPreactivatesWorldbookEntry() async {
        let preprocessor = WorldbookEntry(
            comment: "[Preprocessing] 状态路由",
            content: "@@preprocessing\n<% if (getvar('phase', { defaults: '' }) === 'on') { setLocalVar('initialized', true); activewi(null, '目标条目', true); } %>",
            keys: [],
            constant: true
        )
        let target = WorldbookEntry(
            comment: "目标条目",
            content: "动态内容",
            keys: [],
            isEnabled: false
        )
        let variables = RoleplayVariableSnapshot(chat: ["phase": .string("on")])
        var context = RoleplayMacroContext(variables: variables)
        let prepared = await RoleplayPromptTemplateRenderer.preprocessWorldbooks(
            [Worldbook(name: "模板书", entries: [preprocessor, target])],
            messages: [],
            macroContext: &context
        )

        #expect(prepared[0].entries[1].isEnabled)
        #expect(prepared[0].entries[1].constant)
        #expect(context.variables.chat["initialized"] == .bool(true))

        let rendered = await RoleplayPromptTemplateRenderer.renderMessages(
            [ChatMessage(role: .system, content: "<% if (getvar('phase') === 'on') { %>已开启<% } %>")],
            worldbooks: prepared,
            chatHistory: [],
            macroContext: &context
        )
        #expect(rendered[0].content == "已开启")
    }
    #endif

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

    @Test("从 Character Card V3 PNG 导入扩展资源块")
    func importV3PNGAssets() throws {
        let json = """
        {
          "spec": "chara_card_v3",
          "spec_version": "3.0",
          "data": {
            "name": "PNG 资源角色",
            "assets": [
              { "type": "background", "uri": "__asset:assets/background.txt", "name": "main", "ext": "txt" }
            ]
          }
        }
        """
        let payload = Data("resource-data".utf8)
        let png = makePNGTextCard(
            keyword: "ccv3",
            json: json,
            assets: ["assets/background.txt": payload]
        )

        let result = try RoleplayCardImportService().importCard(from: png, fileName: "asset.png")

        #expect(result.character.assets?.first?.uri == "__asset:assets/background.txt")
        #expect(result.assets.first?.data == payload)
    }

    @Test("导入 Character Card V3 CHARX 及 embeded 资源")
    func importV3CHARXAssets() throws {
        let card = """
        {
          "spec": "chara_card_v3",
          "spec_version": "3.0",
          "data": {
            "name": "资源角色",
            "description": "测试",
            "assets": [
              { "type": "icon", "uri": "embeded://assets/icon/images/main.png", "name": "main", "ext": "png" },
              { "type": "background", "uri": "data:text/plain;base64,YmFja2dyb3VuZA==", "name": "main", "ext": "txt" }
            ]
          }
        }
        """
        let archive = try Archive(data: Data(), accessMode: .create)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cardURL = directory.appendingPathComponent("card.json")
        let iconURL = directory.appendingPathComponent("main.png")
        try Data(card.utf8).write(to: cardURL)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: iconURL)
        try archive.addEntry(with: "card.json", fileURL: cardURL, compressionMethod: .none)
        try archive.addEntry(with: "assets/icon/images/main.png", fileURL: iconURL, compressionMethod: .none)
        let data = try #require(archive.data)

        let result = try RoleplayCardImportService().importCard(from: data, fileName: "asset.charx")

        #expect(result.character.assets?.count == 2)
        #expect(result.assets.first?.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(result.assets.last?.data == Data("background".utf8))
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

    @Test("角色与 Persona 提示词和请求正则按会话上下文组装")
    func assembleRoleplayPromptAndRequestMessages() {
        let character = RoleplayCharacter(
            name: "星野",
            description: "为 {{user}} 引路",
            personality: "冷静",
            scenario: "海边",
            systemPrompt: "保持 {{char}} 身份",
            postHistoryInstructions: "继续称呼 {{user}}",
            regexRules: [
                RoleplayRegexRule(
                    findRegex: "秘密",
                    replaceString: "公开",
                    placements: [.userInput],
                    promptOnly: true
                )
            ]
        )
        let persona = PersonaProfile(name: "旅行者", description: "来自北方")
        let macroContext = RoleplayMacroContext(character: character, persona: persona)
        let resolved = ResolvedRoleplaySession(
            binding: SessionRoleplayBinding(sessionID: UUID(), characterIDs: [character.id], personaID: persona.id),
            characters: [character],
            persona: persona,
            variables: .init(),
            macroContext: macroContext
        )

        let prompt = RoleplayRuntime.roleplaySystemPrompt(resolved)
        let postHistory = RoleplayRuntime.postHistoryPrompt(resolved)
        let messages = RoleplayRuntime.transformedRequestMessages(
            [ChatMessage(role: .user, content: "{{user}} 的秘密")],
            resolved: resolved
        )

        #expect(prompt.contains("为 旅行者 引路"))
        #expect(prompt.contains("保持 星野 身份"))
        #expect(prompt.contains("来自北方"))
        #expect(postHistory == "继续称呼 旅行者")
        #expect(messages.first?.content == "旅行者 的公开")
    }

    @Test("消息变量按消息版本隔离")
    func isolateMessageVersions() {
        let messageID = UUID()
        var snapshot = RoleplayVariableSnapshot()
        snapshot.setValue(.int(1), scope: .message, path: "value", messageID: messageID, versionIndex: 0)
        snapshot.setValue(.int(2), scope: .message, path: "value", messageID: messageID, versionIndex: 1)
        snapshot.setValue(
            .string("<b>内部显示</b>"),
            scope: .message,
            path: RoleplayDisplayedMessageBridge.variableKey,
            messageID: messageID,
            versionIndex: 1
        )
        snapshot.replaceMessageVariables(["value": .int(3)], messageID: messageID, versionIndex: 1)

        #expect(snapshot.value(scope: .message, path: "value", messageID: messageID, versionIndex: 0) == .int(1))
        #expect(snapshot.value(scope: .message, path: "value", messageID: messageID, versionIndex: 1) == .int(3))
        #expect(snapshot.messageVariables(messageID: messageID, versionIndex: 1)[RoleplayDisplayedMessageBridge.variableKey] == nil)
        #expect(snapshot.value(
            scope: .message,
            path: RoleplayDisplayedMessageBridge.variableKey,
            messageID: messageID,
            versionIndex: 1
        ) == .string("<b>内部显示</b>"))
        snapshot.removeMessageVariables(messageID: messageID)
        #expect(snapshot.messageVariables(messageID: messageID, versionIndex: 0).isEmpty)
        #expect(snapshot.messageVariables(messageID: messageID, versionIndex: 1).isEmpty)
    }

    @Test("脚本变量按脚本 ID 隔离且不进入合并提示词")
    func isolateScriptVariables() {
        let firstID = UUID()
        let secondID = UUID()
        var snapshot = RoleplayVariableSnapshot(script: ["shared": .int(1)])
        snapshot.replaceScriptVariables(["value": .string("first")], scriptID: firstID)
        snapshot.replaceScriptVariables(["value": .string("second")], scriptID: secondID)

        #expect(snapshot.scriptVariables(scriptID: firstID)["value"] == .string("first"))
        #expect(snapshot.scriptVariables(scriptID: secondID)["value"] == .string("second"))
        #expect(snapshot.mergedVariables()["shared"] == .int(1))
        #expect(snapshot.mergedVariables()["__etos_script_scopes"] == nil)
    }

    @Test("generateRaw 按自定义顺序、历史覆盖和深度注入组装提示词")
    func assembleCustomGenerationPrompts() {
        let config: [String: JSONValue] = [
            "user_input": .string("用户输入"),
            "ordered_prompts": .array([
                .string("char_description"),
                .dictionary(["role": .string("assistant"), "content": .string("自定义助手提示")]),
                .string("chat_history"),
                .string("user_input")
            ]),
            "overrides": .dictionary([
                "chat_history": .dictionary([
                    "prompts": .array([
                        .dictionary(["role": .string("user"), "content": .string("覆盖历史")])
                    ])
                ])
            ]),
            "injects": .array([
                .dictionary([
                    "role": .string("system"),
                    "content": .string("深度注入"),
                    "position": .string("in_chat"),
                    "depth": .int(1)
                ])
            ])
        ]

        let messages = RoleplayGenerationPromptAssembler.assemble(
            dictionary: config,
            raw: true,
            systemPrompts: ["char_description": "角色描述"],
            chatHistory: [ChatMessage(role: .user, content: "原历史")],
            fallbackSystemPrompt: "不应注入"
        )

        #expect(messages.map(\.role) == [.system, .assistant, .user, .system, .user])
        #expect(messages.map(\.content) == ["角色描述", "自定义助手提示", "覆盖历史", "深度注入", "用户输入"])
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

    @Test("MVU 从世界书 YAML 初始化标准数据并解析宏")
    func initializeMVUFromWorldbook() {
        let primaryID = UUID()
        let worldbook = Worldbook(
            id: primaryID,
            name: "白石世界书",
            entries: [
                WorldbookEntry(
                    uid: 7,
                    comment: "[initvar]变量初始化勿开",
                    content: """
                    世界:
                      当前地点: {{user}}家客厅
                      日期: 2026年1月8日
                    白石:
                      好感度: 85
                      标签: [青梅竹马, 吸血鬼]
                    """,
                    keys: [],
                    isEnabled: false,
                    constant: true
                )
            ]
        )
        let result = RoleplayMVUInitializer.initialize(
            greeting: "你好。",
            worldbooks: [worldbook],
            primaryWorldbookID: primaryID,
            existingVariables: [:],
            macroContext: RoleplayMacroContext(
                character: RoleplayCharacter(name: "白石"),
                persona: PersonaProfile(name: "旅行者")
            )
        )

        #expect(result.failureReasons.isEmpty)
        #expect(result.loadedSourceCount == 1)
        guard case .dictionary(let world) = result.data.statData["世界"],
              case .dictionary(let character) = result.data.statData["白石"] else {
            Issue.record("initvar 没有生成预期对象。")
            return
        }
        #expect(world["当前地点"] == .string("旅行者家客厅"))
        #expect(character["好感度"] == .int(85))
        #expect(result.data.initializedLorebooks["白石世界书"] == [.int(7)])
        #expect(result.data.variables["display_data"] == result.data.variables["stat_data"])
        #expect(result.data.variables["schema"] != nil)
    }

    @Test("MVU 将旧版根变量迁移到 stat_data")
    func migrateLegacyRootMVUVariables() {
        let data = RoleplayMVUData(migratingLegacyVariables: [
            "日期": .string("2026年1月8日"),
            "角色": .dictionary(["好感度": .int(12)]),
            "__etos_displayed_html": .string("<b>状态</b>")
        ])

        #expect(data.statData["日期"] == .string("2026年1月8日"))
        #expect(data.statData["角色"] == .dictionary(["好感度": .int(12)]))
        #expect(data.extra["__etos_displayed_html"] == .string("<b>状态</b>"))
    }

    @Test("MVU 使用 Zod 导出的 JSON Schema 调和类型、范围和枚举")
    func reconcileMVUJSONSchema() {
        let schema: JSONValue = .dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "stat_data": .dictionary([
                    "type": .string("object"),
                    "properties": .dictionary([
                        "好感度": .dictionary([
                            "type": .string("number"),
                            "minimum": .int(0),
                            "maximum": .int(100)
                        ]),
                        "状态": .dictionary([
                            "type": .string("string"),
                            "enum": .array([.string("正常"), .string("异常")]),
                            "default": .string("正常")
                        ])
                    ])
                ])
            ])
        ])
        let reconciled = RoleplayMVUSchemaValidator.reconcile(
            ["好感度": .int(130), "状态": .string("非法")],
            schema: schema,
            fallback: ["好感度": .int(10), "状态": .string("正常")]
        )

        #expect(reconciled["好感度"] == .int(100))
        #expect(reconciled["状态"] == .string("正常"))
    }

    @Test("开场白 initvar 覆盖主世界书并保留附加世界书变量")
    func initializeMVUFromGreetingOverride() {
        let primaryID = UUID()
        let additionalID = UUID()
        let primary = Worldbook(
            id: primaryID,
            name: "主世界书",
            entries: [WorldbookEntry(comment: "[initvar]主变量", content: "角色:\n  好感度: 1", keys: [])]
        )
        let additional = Worldbook(
            id: additionalID,
            name: "附加世界书",
            entries: [WorldbookEntry(comment: "[initvar]附加变量", content: "天气: 晴\n角色:\n  标记: true", keys: [])]
        )
        let result = RoleplayMVUInitializer.initialize(
            greeting: """
            <UpdateVariable><initvar>
            角色:
              好感度: 30
            </initvar></UpdateVariable>
            """,
            worldbooks: [primary, additional],
            primaryWorldbookID: primaryID,
            existingVariables: [:],
            macroContext: .init()
        )

        guard case .dictionary(let character) = result.data.statData["角色"] else {
            Issue.record("开场白 initvar 没有生成角色对象。")
            return
        }
        #expect(character["好感度"] == .int(30))
        #expect(character["标记"] == .bool(true))
        #expect(result.data.statData["天气"] == .string("晴"))
        #expect(result.data.initializedLorebooks["主世界书"] == [])
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

    @Test("MVU JSON Patch 支持数组尾部、移动、VWD 与派生数据")
    func applyNativeMVUSemantics() {
        let messageID = UUID()
        var snapshot = RoleplayVariableSnapshot()
        snapshot.replaceMessageVariables(
            RoleplayMVUData(
                statData: [
                    "记忆": .array([.string("初始")]),
                    "好感度": .array([.int(10), .string("当前好感")]),
                    "旧位置": .string("车站")
                ]
            ).variables,
            messageID: messageID,
            versionIndex: 0
        )
        let result = RoleplayMVUEngine.applyUpdates(
            in: """
            正文
            <UpdateVariable><JSONPatch>
            [
              {"op":"insert","path":"/记忆/-","value":"新记忆"},
              {"op":"delta","path":"/好感度","value":5},
              {"op":"move","from":"/旧位置","path":"/当前位置"}
            ]
            </JSONPatch></UpdateVariable>
            """,
            snapshot: snapshot,
            messageID: messageID,
            versionIndex: 0
        )

        #expect(result.visibleContent == "正文")
        #expect(result.appliedCommandCount == 3)
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.记忆[1]", messageID: messageID) == .string("新记忆"))
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.好感度[0]", messageID: messageID) == .int(15))
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.好感度[1]", messageID: messageID) == .string("当前好感"))
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.旧位置", messageID: messageID) == nil)
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.当前位置", messageID: messageID) == .string("车站"))
        #expect(result.updatedSnapshot.value(scope: .message, path: "delta_data.好感度", messageID: messageID) != nil)
    }

    @Test("MVU lodash 支持条件 set、move 与 delete")
    func applyExtendedLodashMVU() {
        let messageID = UUID()
        var snapshot = RoleplayVariableSnapshot()
        snapshot.setValue(
            .dictionary([
                "地点": .string("车站"),
                "原路径": .string("待移动"),
                "目标路径": .string("旧值"),
                "临时": .bool(true)
            ]),
            scope: .message,
            path: "stat_data",
            messageID: messageID
        )
        let result = RoleplayMVUEngine.applyUpdates(
            in: """
            <UpdateVariable>
            _.set('地点', '错误旧值', '不会生效');
            _.set('地点', '车站', '海边');
            _.move('原路径', '目标路径');
            _.delete('临时');
            </UpdateVariable>
            """,
            snapshot: snapshot,
            messageID: messageID,
            versionIndex: 0
        )

        #expect(result.appliedCommandCount == 3)
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.地点", messageID: messageID) == .string("海边"))
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.原路径", messageID: messageID) == nil)
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.目标路径", messageID: messageID) == .string("待移动"))
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.临时", messageID: messageID) == nil)
    }

    @Test("MVU 可解析 UpdateVariable 标签外的直接命令")
    func applyUntaggedMVUCommand() {
        let messageID = UUID()
        var snapshot = RoleplayVariableSnapshot()
        snapshot.replaceMessageVariables(
            RoleplayMVUData(statData: ["数值": .int(1)]).variables,
            messageID: messageID,
            versionIndex: 0
        )
        let content = "正文\n_.set('数值', 2); // 直接更新"
        let result = RoleplayMVUEngine.applyUpdates(
            in: content,
            snapshot: snapshot,
            messageID: messageID,
            versionIndex: 0
        )

        #expect(result.visibleContent == content)
        #expect(result.appliedCommandCount == 1)
        #expect(result.updatedSnapshot.value(scope: .message, path: "stat_data.数值", messageID: messageID) == .int(2))
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
        #expect(document.contains("getButtonEvent"))
    }

    @Test("酒馆助手脚本使用 ES Module 并由原生 MVU 接管 MagVarUpdate")
    func makeHelperScriptModuleDocument() {
        let source = RoleplayHelperScriptDocument.source("""
        import 'https://testingcf.jsdelivr.net/gh/MagicalAstrogy/MagVarUpdate@beta/artifact/bundle.js';
        export const Schema = z.object({ value: z.number() });
        """)

        #expect(source.contains("source = source.replace"))
        #expect(source.contains("await import(moduleURL)"))
        #expect(source.contains("MagicalAstrogy\\/MagVarUpdate"))
        #expect(source.contains("window.z = await import"))
    }

#if canImport(JavaScriptCore)
    @Test("HTML 兼容桥可执行变量、事件、MVU、lorebook 与宏语义")
    func executeHTMLCompatibilityRuntime() throws {
        let document = RoleplayHTMLDocumentFactory.makeDocument(
            source: "<html><head></head><body></body></html>",
            variables: ["score": .int(1)],
            userName: "旅行者",
            characterName: "星野",
            userAvatarPath: "",
            characterAvatarPath: "",
            chatMessages: [ChatMessage(role: .assistant, content: "状态")],
            worldbooks: [Worldbook(name: "测试世界书", entries: [WorldbookEntry(content: "内容", keys: ["键"])])],
            primaryWorldbookName: "测试世界书",
            scriptID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        let startMarker = "<script>(function () {"
        let start = try #require(document.range(of: startMarker)?.lowerBound)
        let scriptStart = document.index(start, offsetBy: "<script>".count)
        let scriptEnd = try #require(document.range(of: "</script>", range: scriptStart..<document.endIndex)?.lowerBound)
        let script = String(document[scriptStart..<scriptEnd])

        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript 异常：\(exception?.toString() ?? "未知错误")")
        }
        context.evaluateScript("""
        var window = this;
        var posted = [];
        window.webkit = { messageHandlers: { etosRoleplay: { postMessage: value => posted.push(value) } } };
        window.addEventListener = function() {};
        window.dispatchEvent = function() {};
        var File = function() {};
        var mutationCallbacks = [];
        var document = {
          querySelector: () => null,
          createElement: () => ({ className: '', innerHTML: '', setAttribute: () => {}, appendChild: () => {} }),
          body: {},
          documentElement: {}
        };
        var CustomEvent = function() {};
        var MutationObserver = function(callback) { mutationCallbacks.push(callback); this.observe = function() {}; };
        var ResizeObserver = function() { this.observe = function() {}; };
        var Audio = function() {};
        """)
        context.evaluateScript(script)

        let variableResult = context.evaluateScript("""
        JSON.stringify(updateVariablesWith(value => { value.score += 4; return value; }, { type: 'chat' }))
        """)?.toString()
        #expect(variableResult == #"{"score":5}"#)
        #expect(context.evaluateScript("iframe_events.GENERATION_ENDED")?.toString() == "js_generation_ended")
        #expect(context.evaluateScript("tavern_events.MESSAGE_UPDATED")?.toString() == "message_updated")
        #expect(context.evaluateScript("typeof waitGlobalInitialized")?.toString() == "function")
        #expect(context.evaluateScript("typeof Mvu.getMvuData")?.toString() == "function")
        #expect(context.evaluateScript("typeof Mvu.replaceMvuData")?.toString() == "function")
        #expect(context.evaluateScript("typeof Mvu.parseMessage")?.toString() == "function")
        #expect(context.evaluateScript("typeof Mvu.getCurrentMvuData")?.toString() == "function")
        #expect(context.evaluateScript("typeof Mvu.replaceCurrentMvuData")?.toString() == "function")
        #expect(context.evaluateScript("typeof Mvu.reloadInitVar")?.toString() == "function")
        #expect(context.evaluateScript("typeof Mvu.getRecordFromMvuData")?.toString() == "function")
        #expect(context.evaluateScript("Mvu.events.VARIABLE_INITIALIZED")?.toString() == "mag_variable_initialized")
        #expect(context.evaluateScript("Mvu.events.SINGLE_VARIABLE_UPDATED")?.toString() == "mag_variable_updated")
        context.evaluateScript("""
        window.z = { toJSONSchema: () => ({ type: 'object', properties: { stat_data: { type: 'object' } } }) };
        registerVariableSchema({}, { type: 'message' });
        """)
        #expect(context.evaluateScript(
            "posted.some(item => item.action === 'replace_message_variables' && item.value.schema.properties.stat_data.type === 'object')"
        )?.toBool() == true)
        #expect(context.evaluateScript("typeof getLorebookEntries")?.toString() == "function")
        #expect(context.evaluateScript("typeof formatAsDisplayedMessage")?.toString() == "function")
        #expect(context.evaluateScript("getScriptId()")?.toString() == "11111111-1111-1111-1111-111111111111")
        #expect(context.evaluateScript("getCharWorldbookNames('current').primary")?.toString() == "测试世界书")

        context.evaluateScript("""
        var asyncVariableResult = '';
        updateVariablesWith(async value => { await Promise.resolve(); value.score += 2; return value; }, { type: 'chat' })
          .then(value => { asyncVariableResult = JSON.stringify(value); });
        """)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        #expect(context.evaluateScript("asyncVariableResult")?.toString() == #"{"score":7}"#)

        context.evaluateScript("""
        var eventOrder = [];
        var eventResult = '';
        var normalListener = () => eventOrder.push('normal');
        eventOn('ordered', normalListener);
        eventOn('ordered', normalListener);
        eventMakeFirst('ordered', () => eventOrder.push('first'));
        eventMakeLast('ordered', () => eventOrder.push('last'));
        eventEmitAndWait('ordered').then(() => { eventResult = eventOrder.join(','); });
        """)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        #expect(context.evaluateScript("eventResult")?.toString() == "first,normal,last")

        context.evaluateScript("""
        var parsedMVUValue = -1;
        eventOn(Mvu.events.COMMAND_PARSED, (_variables, commands) => { commands[0].args[1] = 9; });
        Mvu.parseMessage("_.set('value', 3); // 测试; 注释", { stat_data: { value: 1 }, initialized_lorebooks: {} })
          .then(value => { parsedMVUValue = value.stat_data.value; });
        """)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        #expect(context.evaluateScript("parsedMVUValue")?.toInt32() == 9)

        context.evaluateScript("""
        var parsedMVUArrayLength = -1;
        Mvu.parseMessage(
          '<JSONPatch>[{"op":"insert","path":"/items/-","value":"b"}]</JSONPatch>',
          { stat_data: { items: ['a'] }, initialized_lorebooks: {} }
        ).then(value => { parsedMVUArrayLength = value.stat_data.items.length; });
        """)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        #expect(context.evaluateScript("parsedMVUArrayLength")?.toInt32() == 2)

        context.evaluateScript("""
        var generationResult = '';
        generateRaw({ user_input: '输入', ordered_prompts: ['user_input'] })
          .then(value => { generationResult = value; });
        """)
        let generationRequestID = context.evaluateScript(
            "posted.filter(item => item.action === 'generate_text').at(-1).request_id"
        )?.toString()
        context.evaluateScript("__etosResolveRequest('\(generationRequestID ?? "")', '生成文本', null)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        #expect(context.evaluateScript("generationResult")?.toString() == "生成文本")

        context.evaluateScript("""
        var displayed = retrieveDisplayedMessage(0);
        displayed.innerHTML = '<b>跨消息更新</b>';
        mutationCallbacks.at(-1)();
        """)
        #expect(context.evaluateScript(
            "posted.some(item => item.action === 'set_displayed_message' && item.html === '<b>跨消息更新</b>')"
        )?.toBool() == true)

        let macro = context.evaluateScript("""
        registerMacroLike(/{{value}}/g, () => '42'); substitudeMacros('{{user}}={{value}}')
        """)?.toString()
        #expect(macro == "旅行者=42")
        #expect(context.evaluateScript("substitudeMacros('{{{user}}}/{{{char}}}')")?.toString() == "旅行者/星野")
        #expect(context.evaluateScript("posted.some(item => item.action === 'replace_variables')")?.toBool() == true)
    }

    @Test("执行导入角色卡的助手脚本并验证异步返回与变量副作用")
    func executeImportedHelperScript() throws {
        let helperSource = """
        window.cardResult = '';
        window.cardPromise = (async () => {
          await waitGlobalInitialized('Mvu');
          await updateVariablesWith(async value => {
            await Promise.resolve();
            value.stat_data.count += 2;
            return value;
          }, { type: 'chat' });
          let data = Mvu.getMvuData({ type: 'chat' });
          data = await Mvu.parseMessage("_.add('count', 3); // 角色脚本更新", data);
          await Mvu.replaceMvuData(data, { type: 'chat' });
          registerMacroLike(/{{card_value}}/g, () => String(Mvu.getMvuData({ type: 'chat' }).stat_data.count));
          const generated = await generateRaw({
            user_input: substitudeMacros('{{card_value}}'),
            ordered_prompts: ['user_input']
          });
          window.cardResult = `${generated}:${Mvu.getMvuData({ type: 'chat' }).stat_data.count}`;
        })();
        """
        let payload: [String: Any] = [
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": [
                "name": "可执行脚本角色",
                "extensions": [
                    "tavern_helper": [
                        "scripts": [[
                            "type": "script",
                            "id": "22222222-2222-2222-2222-222222222222",
                            "name": "语义测试",
                            "enabled": true,
                            "content": helperSource
                        ]]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let imported = try RoleplayCardImportService().importCard(from: data, fileName: "executable.json")
        let script = try #require(imported.character.helperScripts.first)
        let document = RoleplayHTMLDocumentFactory.makeDocument(
            source: "<html><head></head><body></body></html>",
            variables: ["stat_data": .dictionary(["count": .int(1)])],
            userName: "用户",
            characterName: imported.character.name,
            userAvatarPath: "",
            characterAvatarPath: "",
            chatMessages: [ChatMessage(role: .assistant, content: "开场")],
            scriptID: script.id,
            scriptName: script.name
        )
        let start = try #require(document.range(of: "<script>(function () {")?.lowerBound)
        let scriptStart = document.index(start, offsetBy: "<script>".count)
        let scriptEnd = try #require(document.range(of: "</script>", range: scriptStart..<document.endIndex)?.lowerBound)
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("角色脚本 JavaScript 异常：\(exception?.toString() ?? "未知错误")")
        }
        context.evaluateScript("""
        var window = this;
        var posted = [];
        var File = function() {};
        window.webkit = { messageHandlers: { etosRoleplay: { postMessage: value => posted.push(value) } } };
        window.addEventListener = function() {};
        window.dispatchEvent = function() {};
        var document = { querySelector: () => null, createElement: () => ({ innerHTML: '' }), body: {}, documentElement: {} };
        var CustomEvent = function() {};
        var MutationObserver = function() { this.observe = function() {}; };
        var ResizeObserver = function() { this.observe = function() {}; };
        var Audio = function() {};
        """)
        context.evaluateScript(String(document[scriptStart..<scriptEnd]))
        let encodedSource = try JSONEncoder().encode(script.content)
        let sourceLiteral = try #require(String(data: encodedSource, encoding: .utf8))
        context.evaluateScript("eval(\(sourceLiteral))")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        let requestID = context.evaluateScript(
            "posted.filter(item => item.action === 'generate_text').at(-1).request_id"
        )?.toString()
        context.evaluateScript("__etosResolveRequest('\(requestID ?? "")', '角色脚本生成', null)")
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        #expect(context.evaluateScript("cardResult")?.toString() == "角色脚本生成:6")
        #expect(context.evaluateScript(
            "posted.filter(item => item.action === 'replace_variables').at(-1).value.stat_data.count"
        )?.toInt32() == 6)
    }
#endif

    private func makePNGTextCard(
        keyword: String,
        json: String,
        assets: [String: Data] = [:]
    ) -> Data {
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let encoded = Data(json.utf8).base64EncodedString()
        var text = Data(keyword.utf8)
        text.append(0)
        text.append(Data(encoded.utf8))
        appendChunk(type: "tEXt", payload: text, to: &png)
        for (path, data) in assets.sorted(by: { $0.key < $1.key }) {
            var asset = Data("chara-ext-asset_:\(path)".utf8)
            asset.append(0)
            asset.append(Data(data.base64EncodedString().utf8))
            appendChunk(type: "tEXt", payload: asset, to: &png)
        }
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

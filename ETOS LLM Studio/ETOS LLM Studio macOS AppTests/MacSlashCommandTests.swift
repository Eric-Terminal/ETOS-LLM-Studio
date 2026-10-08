import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacSlashCommandTests {
    @Test("十九条内建命令全部映射到唯一的桌面操作或已存在页面")
    func everyBuiltInHasARealRoute() {
        let routes = ChatSlashCommand.allCases.map(MacSlashCommandRoute.init)
        #expect(routes.count == 19 && Set(routes).count == 19)
        #expect(MacSlashCommandRoute(.tools) == .page(.toolCenter))
        #expect(MacSlashCommandRoute(.features) == .page(.extendedFeatures))
        #expect(MacSlashCommandRoute(.sessions) == .sessions)
        #expect(MacSlashCommandRoute(.model) == .model)
    }

    @Test("关闭功能时完整命令也保留普通消息语义，路径、参数和前置空白不被截获")
    func ordinaryMessagesRemainLiteral() {
        #expect(input("/stop", enabled: false).recognized == nil)
        #expect(input("/stop", enabled: false).rows.isEmpty)
        for text in ["/Users/Eric/file.txt", "/unknown", "/new later", " /new"] {
            #expect(input(text).recognized == nil)
            #expect(input(text).text == text)
        }
    }

    @Test("别名只用于完整识别，建议只匹配规范名称并保留内建顺序")
    func canonicalSuggestionsAndAliases() {
        #expect(input("/HISTORY\n").recognized == .builtIn(.sessions))
        #expect(input("/history").rows.isEmpty)
        #expect(input("/").rows.map(\.suggestion) == ChatSlashCommand.allCases.map(ChatSlashCommandSuggestion.builtIn))
        let matched = input("/s")
        for (index, row) in matched.rows.enumerated() { #expect(matched.indicesByID[row.id] == index) }
    }

    @Test("自定义提示词以斜杠开头时只填草稿，随后提交保持文字，不递归执行命令")
    func customSlashPromptIsNotExecutedRecursively() {
        let custom = CustomChatSlashCommand(trigger: "my_stop", prompt: "/stop")
        let selected = input("/my_stop", commands: [custom])
        #expect(selected.recognized == .custom(custom))
        let filled = input(custom.prompt, commands: [custom], literalPrefill: custom.prompt)
        #expect(filled.recognized == nil && filled.rows.isEmpty)
        #expect(filled.text == "/stop")
    }

    @Test("目录预先准备描述和索引，正文预览有界但保存内容完整")
    func catalogKeepsFullPromptAndPreparedPreview() {
        let command = CustomChatSlashCommand(trigger: "long", prompt: String(repeating: "文", count: 400))
        let state = MacSlashCommandCatalog(CustomChatSlashCommandSnapshot(commands: [command], rawValue: "原始配置"))
        #expect(state.custom.first?.description.count == 160)
        #expect(state.commandsByID[command.id]?.prompt.count == 400)
        #expect(state.builtIn.count == 19)
        #expect(state.guideCommands == GuideSlashCommandSettingsSupport.value([command]))
    }

    @Test("向导整表可排序并保留未修改项时间和正文空白")
    func guideReorderingPreservesLiteralContentAndIdentity() throws {
        let a = CustomChatSlashCommand(trigger: "alpha", prompt: "    代码\n", updatedAt: Date(timeIntervalSince1970: 12))
        let b = CustomChatSlashCommand(trigger: "beta", prompt: "乙", updatedAt: Date(timeIntervalSince1970: 13))
        let original = CustomChatSlashCommandSnapshot(commands: [a, b], rawValue: "旧值")
        let result = try MacSlashCommandCatalog.guideReplacement(GuideSlashCommandSettingsSupport.value([b, a]), original: original)
        #expect(result == [b, a])
        #expect(try MacSlashCommandCatalog.guideReplacement(.array([]), original: original).isEmpty)
    }

    @Test("向导拒绝重复标识、保留别名与额外字段，新增命令可省略标识")
    func guideValidatesInputAtTheBoundary() throws {
        let original = CustomChatSlashCommandSnapshot(commands: [], rawValue: nil)
        let command = CustomChatSlashCommand(trigger: "alpha", prompt: "正文")
        let duplicate = GuideSlashCommandSettingsSupport.value([command, CustomChatSlashCommand(id: command.id, trigger: "beta", prompt: "乙")])
        #expect(throws: CustomChatSlashCommandError.self) { try MacSlashCommandCatalog.guideReplacement(duplicate, original: original) }
        let reserved: JSONValue = .array([.dictionary(["trigger": .string("history"), "prompt": .string("正文")])])
        #expect(throws: CustomChatSlashCommandError.self) { try MacSlashCommandCatalog.guideReplacement(reserved, original: original) }
        let extra: JSONValue = .array([.dictionary(["trigger": .string("alpha"), "prompt": .string("正文"), "execute": .bool(true)])])
        #expect(throws: GuideError.self) { try MacSlashCommandCatalog.guideReplacement(extra, original: original) }
        let new: JSONValue = .array([.dictionary(["trigger": .string(" /ALPHA "), "prompt": .string("\n正文\n")])])
        let result = try MacSlashCommandCatalog.guideReplacement(new, original: original)
        #expect(result.first?.trigger == "alpha" && result.first?.prompt == "\n正文\n")
    }

    @Test("填入提示词只跨越对应的草稿更新，后续手动编辑恢复命令识别")
    @MainActor
    func composerPreservesPrefillUntilTheNextEdit() async {
        let model = MacSlashCommandComposerModel()
        let catalog = MacSlashCommandCatalog(CustomChatSlashCommandSnapshot(commands: [], rawValue: nil))
        let sessionID = UUID()
        model.markCustomPrefill("/stop")
        model.refresh(text: "/stop", sessionID: sessionID, enabled: true, catalog: catalog, inputChanged: true)
        let literal = await model.resolve(text: "/stop", sessionID: sessionID, enabled: true, catalog: catalog)
        #expect(literal?.recognized == nil)
        model.refresh(text: "/new", sessionID: sessionID, enabled: true, catalog: catalog, inputChanged: true)
        let edited = await model.resolve(text: "/new", sessionID: sessionID, enabled: true, catalog: catalog)
        #expect(edited?.recognized == .builtIn(.new))
        model.invalidate()
        #expect(model.input == nil && !model.moveSelection(1))
        #expect(model.selectedSuggestion() == nil)
    }

    @Test("双语向导明确草稿保存、原生命令与后台校验的边界")
    func guideDocumentsNativeExecutionBoundary() {
        let chinese = GuideSlashCommandsKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideSlashCommandsKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("共 19 项") && chinese.contains("向导不能执行命令"))
        #expect(english.contains("never recursively executed") && english.contains("cannot execute commands"))
        #expect(GuideDocumentCatalog.documents.filter { $0.id == "slash-commands" }.count == 1)
    }

    @Test("普通消息不依赖命令目录，取消提交会释放解析状态，斜杠输入仍等待目录")
    @MainActor
    func ordinarySubmissionDoesNotDependOnCommandCatalog() async {
        let model = MacSlashCommandComposerModel(), sessionID = UUID()
        let ordinary = await model.resolve(text: "普通消息", sessionID: sessionID, enabled: true, catalog: nil)
        #expect(ordinary?.text == "普通消息" && ordinary?.recognized == nil)
        let cancelled = Task { await model.resolve(text: "取消提交", sessionID: sessionID, enabled: true, catalog: nil) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(!model.isResolving)
        let unresolved = await model.resolve(text: "/custom", sessionID: sessionID, enabled: true, catalog: nil)
        #expect(unresolved == nil)
    }

    private func input(_ text: String, enabled: Bool = true, commands: [CustomChatSlashCommand] = [], literalPrefill: String? = nil) -> MacSlashCommandInput {
        MacSlashCommandInput(text: text, sessionID: UUID(), enabled: enabled, commands: commands, literalPrefill: literalPrefill)
    }
}

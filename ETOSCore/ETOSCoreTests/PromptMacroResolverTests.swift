import Foundation
import Testing
@testable import ETOSCore

struct PromptMacroResolverTests {
    @Test("普通提示词兼容单括号、双括号、大小写和空白")
    func supportsRikkaAndKelivoSyntax() {
        let template = "你好 👋 {model_id} / {{ MODEL_NAME }} / { battery_level }%"
        let rendered = PromptMacroResolver.render(template, values: [
            "model_id": "model-api-id", "model_name": "测试模型", "battery_level": "83"
        ])
        #expect(rendered == "你好 👋 model-api-id / 测试模型 / 83%")
        #expect(PromptMacroResolver.referencedNames(in: [template]) == ["model_id", "model_name", "battery_level"])
    }

    @Test("未知宏、角色脚本语法与不完整括号保持原样")
    func preservesUnrecognizedSyntax() {
        let template = #"{{unknown}} {{getvar::score}} {{model_id} {model_id}} {{{{model_id}}}} {{{model_id}} {{model_id}}} {"model_id": "x"} <% value %>"#
        #expect(PromptMacroResolver.render(template, values: ["model_id": "changed"]) == template)
        #expect(PromptMacroResolver.referencedNames(in: [template]).isEmpty)
    }

    @Test("三括号输出双括号字面量，保留大小写空白且不请求环境读数")
    func tripleBracesProduceLiteralMacros() {
        let literal = "👋 {{{battery_level}}} / {{{ MODEL_NAME }}} / {{{unknown}}}"
        #expect(PromptMacroResolver.render(literal, values: ["battery_level": "90", "model_name": "模型"])
            == "👋 {{battery_level}} / {{ MODEL_NAME }} / {{unknown}}")
        #expect(PromptMacroResolver.referencedNames(in: [literal]).isEmpty)

        let mixed = "{{{battery_level}}}={{battery_level}}/{battery_level}"
        #expect(PromptMacroResolver.render(mixed, values: ["battery_level": "90"]) == "{{battery_level}}=90/90")
        #expect(PromptMacroResolver.referencedNames(in: [mixed]) == ["battery_level"])
    }

    @Test("历史用户消息每轮重新取值，原文、助手回复和工具结果保持不变")
    func userMessageMacrosRemainDynamicAcrossRequests() {
        let user = ChatMessage(role: .user, content: "电量 {{battery_level}}%，解释 {{{battery_level}}}")
        let assistant = ChatMessage(role: .assistant, content: "{{battery_level}} / {{{battery_level}}}")
        let tool = ChatMessage(role: .tool, content: "{{battery_level}} / {{{battery_level}}}")
        let messages = [user, assistant, tool]
        let templates = PromptMacroTemplates(enhanced: "{{battery_level}}")

        for level in ["90", "83"] {
            let request = PromptMacroRequest(templates: templates, messages: messages, values: ["battery_level": level])
            let rendered = request.restoringLiterals(in: request.messages)
            #expect(rendered[0].id == user.id)
            #expect(rendered[0].content == "电量 \(level)%，解释 {{battery_level}}")
            #expect(request.templates.enhanced == level)
            #expect(rendered[1] == assistant)
            #expect(rendered[2] == tool)
        }
        #expect(messages[0] == user)
        #expect(user.content == "电量 {{battery_level}}%，解释 {{{battery_level}}}")
        #expect(templates.enhanced == "{{battery_level}}")
    }

    @Test("四类提示词与用户消息中的字面宏不会被后续角色宏重复展开")
    func literalMacrosSurviveSubsequentTemplateProcessing() {
        let literal = "{{{user}}} / {{{battery_level}}}"
        let request = PromptMacroRequest(
            templates: PromptMacroTemplates(global: literal, conversation: literal, topic: literal, enhanced: literal),
            messages: [ChatMessage(role: .user, content: literal)],
            values: [:]
        )
        let context = RoleplayMacroContext(customValues: ["battery_level": "90"])
        let prepared = request.templates.texts.map { ChatMessage(role: .system, content: $0) } + request.messages
        let processed = prepared.map { message in
            var result = message
            result.content = RoleplayMacroResolver.resolve(message.content, context: context)
            result.content = RoleplayMacroResolver.resolve(result.content, context: context)
            return result
        }
        let restored = request.restoringLiterals(in: processed)
        #expect(restored.count == 5)
        #expect(restored.allSatisfy { $0.content == "{{user}} / {{battery_level}}" })
    }

    @Test("字面宏保护标记跨请求稳定，并避开用户已有文本")
    func literalProtectionIsStableAndAvoidsCollisions() {
        let existingText = "\u{E000}ETOS.literal:battery_level\u{E001}"
        let user = ChatMessage(role: .user, content: "\(existingText) {{{battery_level}}} {{pick::甲::乙}}")
        let first = PromptMacroRequest(templates: .init(), messages: [user], values: [:])
        let second = PromptMacroRequest(templates: .init(), messages: [user], values: [:])
        #expect(first.messages == second.messages)
        #expect(first.restoringLiterals(in: first.messages)[0].content
            == "\(existingText) {{battery_level}} {{pick::甲::乙}}")
        let context = RoleplayMacroContext(chatSeed: "固定会话")
        #expect(RoleplayMacroResolver.resolve(first.messages[0].content, context: context)
            == RoleplayMacroResolver.resolve(second.messages[0].content, context: context))
    }

    @Test("变量值中的宏文本不会被递归展开")
    func doesNotInterpretReplacementValues() {
        let rendered = PromptMacroResolver.render("{{nickname}} / {{model_name}}", values: [
            "nickname": "{{model_name}}", "model_name": "{battery_level}", "battery_level": "83"
        ])
        #expect(rendered == "{{model_name}} / {battery_level}")
    }

    @Test("缺少上下文值时保留宏，未设置的提示词不会变成空字符串")
    func preservesMissingValuesAndOptionalPrompts() {
        let templates = PromptMacroTemplates(global: nil, conversation: "", topic: "{{nickname}}", enhanced: "{model_id}")
        let rendered = templates.rendered(values: ["model_id": "model"])
        #expect(rendered == PromptMacroTemplates(global: nil, conversation: "", topic: "{{nickname}}", enhanced: "model"))
        #expect(templates.enhanced == "{model_id}")
    }

    @Test("本地时间、UTC 和半小时时区偏移来自同一个请求时刻")
    func formatsConsistentTimeSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_767_225_600)
        let values = PromptMacroResolver.timeValues(
            now: now,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: try #require(TimeZone(secondsFromGMT: 19_800))
        )
        #expect(values["cur_date"] == "2026-01-01")
        #expect(values["cur_time"] == "05:30:00")
        #expect(values["cur_datetime"] == "2026-01-01 05:30:00")
        #expect(values["utc_datetime"] == "2026-01-01T00:00:00Z")
        #expect(values["weekday"] == "Thursday")
        #expect(values["timestamp"] == "1767225600")
        #expect(values["timezone_offset"] == "+05:30")
    }

    @Test("日期跨日与夏令时偏移按请求时刻计算")
    func respectsDayBoundaryAndDaylightSavingTime() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let winter = Date(timeIntervalSince1970: 1_767_225_600)
        let summer = winter.addingTimeInterval(181 * 86_400)
        let winterValues = PromptMacroResolver.timeValues(now: winter, locale: .init(identifier: "th_TH"), timeZone: zone)
        let summerValues = PromptMacroResolver.timeValues(now: summer, locale: .init(identifier: "en_US"), timeZone: zone)
        #expect(winterValues["cur_date"] == "2025-12-31")
        #expect(winterValues["cur_time"] == "19:00:00")
        #expect(winterValues["timezone_offset"] == "-05:00")
        #expect(summerValues["timezone_offset"] == "-04:00")
    }

    @Test("电量转换为不带百分号的整数，充满与正在充电分别表示")
    func formatsBatteryReadings() {
        let charging = PromptMacroEnvironment.batteryValues(level: 0.835, state: "charging")
        #expect(charging["battery_level"] == "84")
        #expect(charging["is_charging"] == "true")
        let full = PromptMacroEnvironment.batteryValues(level: 1, state: "full")
        #expect(full["battery_level"] == "100")
        #expect(full["battery_state"] == "full")
        #expect(full["is_charging"] == "false")
        #expect(PromptMacroEnvironment.batteryValues(level: 0, state: "unplugged")["battery_level"] == "0")
    }

    @Test("不可用电池读数不会伪装为零电量或未充电")
    func preservesUnavailableBatteryState() {
        for level in [Float(-1), .nan, .infinity] {
            let values = PromptMacroEnvironment.batteryValues(level: level, state: "unknown")
            #expect(values["battery_level"] == "unknown")
            #expect(values["battery_state"] == "unknown")
            #expect(values["is_charging"] == "unknown")
        }
    }
}

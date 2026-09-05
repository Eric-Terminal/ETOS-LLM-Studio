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
        let template = #"{{unknown}} {{getvar::score}} {{model_id} {model_id}} {{{model_id}}} {"model_id": "x"} <% value %>"#
        #expect(PromptMacroResolver.render(template, values: ["model_id": "changed"]) == template)
        #expect(PromptMacroResolver.referencedNames(in: [template]).isEmpty)
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

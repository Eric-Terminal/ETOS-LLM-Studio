// ============================================================================
// ChatAppearanceProfilesTests.swift
// ============================================================================
// 聊天颜色配置测试
// - 覆盖旧配置迁移、默认 Profile 复制、时间窗命中与重叠校验
// - 保障颜色配置不会混入 AppConfig 设置快照
// ============================================================================

import Foundation
import Testing
import SwiftUI
@testable import ETOSCore

@Suite("聊天颜色配置测试")
struct ChatAppearanceProfilesTests {

    @Test("legacy 颜色键会迁移到 default 配置")
    func legacyKeysMigrateToDefaultProfile() {
        let suite = "com.ETOS.tests.chatAppearance.migrate.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "enableCustomUserBubbleColor")
        defaults.set("AA112233", forKey: "customUserBubbleColorHex")
        defaults.set(true, forKey: "enableCustomAssistantBubbleColor")
        defaults.set("BB445566", forKey: "customAssistantBubbleColorHex")
        defaults.set(true, forKey: "enableCustomLightTextColor")
        defaults.set("CC778899", forKey: "customLightTextColorHex")
        defaults.set(true, forKey: "enableCustomDarkTextColor")
        defaults.set("DDAABBCC", forKey: "customDarkTextColorHex")

        let configuration = ChatAppearanceProfileStore.loadConfiguration(userDefaults: defaults)
        let defaultProfile = configuration.defaultProfile

        #expect(configuration.profiles.count == 1)
        #expect(defaultProfile.userBubble.isEnabled == true)
        #expect(defaultProfile.userBubble.hex == "AA112233")
        #expect(defaultProfile.assistantBubble.isEnabled == true)
        #expect(defaultProfile.assistantBubble.hex == "BB445566")
        #expect(defaultProfile.userLightText.hex == "CC778899")
        #expect(defaultProfile.assistantLightText.hex == "CC778899")
        #expect(defaultProfile.userDarkText.hex == "DDAABBCC")
        #expect(defaultProfile.assistantDarkText.hex == "DDAABBCC")
        #expect(defaults.data(forKey: ChatAppearanceProfileStore.configurationStorageKey) != nil)
    }

    @Test("新增配置会复制 default")
    @MainActor
    func newProfileCopiesDefault() throws {
        let suite = "com.ETOS.tests.chatAppearance.copy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let defaultProfile = ChatAppearanceProfile(
            id: ChatAppearanceProfile.defaultProfileID,
            name: "default",
            userBubble: .init(isEnabled: true, hex: "11223344"),
            assistantBubble: .init(isEnabled: false, hex: "55667788"),
            lightText: .init(isEnabled: true, hex: "99AABBCC"),
            darkText: .init(isEnabled: false, hex: "DDEEFF00"),
            assistantLightTextStyles: ChatAppearanceTextStyleColors(
                defaultHex: "99AABBCC",
                customRules: [
                    ChatAppearanceTextColorRule(
                        kind: .exactText,
                        exactText: "GPG",
                        colorHex: "FF0000FF"
                    )
                ]
            )
        )
        let configuration = ChatAppearanceProfileConfiguration(profiles: [defaultProfile], scheduleRules: [])
        _ = try ChatAppearanceProfileStore.saveConfiguration(configuration, userDefaults: defaults)
        let manager = ChatAppearanceProfileManager(
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            automaticallySchedulesRefresh: false
        )

        let added = try manager.addProfile()
        let defaultLoaded = manager.configuration.defaultProfile

        #expect(added.id != ChatAppearanceProfile.defaultProfileID)
        #expect(added.userBubble == defaultLoaded.userBubble)
        #expect(added.userLightText == defaultLoaded.userLightText)
        #expect(added.assistantLightText == defaultLoaded.assistantLightText)
        #expect(added.userLightTextStyles == defaultLoaded.userLightTextStyles)
        #expect(added.assistantLightTextStyles.customRules.count == 1)
        #expect(added.assistantDarkTextStyles == defaultLoaded.assistantDarkTextStyles)
        #expect(added.name == "Profile 1")
    }

    @Test("恢复颜色会同时清空自定义文字规则")
    @MainActor
    func resetColorsClearsCustomTextRules() throws {
        let suite = "com.ETOS.tests.chatAppearance.resetRules.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let rule = ChatAppearanceTextColorRule(
            kind: .exactText,
            exactText: "GPG",
            colorHex: "FF0000FF"
        )
        let profile = ChatAppearanceProfile(
            id: ChatAppearanceProfile.defaultProfileID,
            name: "default",
            assistantLightTextStyles: ChatAppearanceTextStyleColors(
                defaultHex: "1C1C1EFF",
                customRules: [rule]
            )
        )
        _ = try ChatAppearanceProfileStore.saveConfiguration(
            ChatAppearanceProfileConfiguration(profiles: [profile]),
            userDefaults: defaults
        )
        let manager = ChatAppearanceProfileManager(
            userDefaults: defaults,
            automaticallySchedulesRefresh: false
        )

        try manager.resetColors(profileID: ChatAppearanceProfile.defaultProfileID)

        #expect(manager.configuration.defaultProfile.assistantLightTextStyles.customRules.isEmpty)
    }

    @Test("用户和助手文字颜色会分别持久化")
    func roleTextColorsPersistSeparately() throws {
        let profile = ChatAppearanceProfile(
            id: ChatAppearanceProfile.defaultProfileID,
            name: "default",
            userLightText: .init(isEnabled: true, hex: "111111FF"),
            userDarkText: .init(isEnabled: true, hex: "222222FF"),
            assistantLightText: .init(isEnabled: true, hex: "333333FF"),
            assistantDarkText: .init(isEnabled: true, hex: "444444FF")
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ChatAppearanceProfile.self, from: data)

        #expect(decoded.userLightText.hex == "111111FF")
        #expect(decoded.userDarkText.hex == "222222FF")
        #expect(decoded.assistantLightText.hex == "333333FF")
        #expect(decoded.assistantDarkText.hex == "444444FF")
    }

    @Test("文字样式颜色会持久化并为旧配置继承正文色")
    func textStyleColorsPersistAndMigrate() throws {
        let profile = ChatAppearanceProfile(
            id: ChatAppearanceProfile.defaultProfileID,
            name: "default",
            userLightText: .init(isEnabled: true, hex: "112233FF"),
            assistantDarkText: .init(isEnabled: true, hex: "AABBCCFF"),
            userLightTextStyles: ChatAppearanceTextStyleColors(
                defaultHex: "112233FF",
                strong: .init(isEnabled: true, hex: "FF0000FF"),
                code: .init(isEnabled: true, hex: "00FF00FF")
            )
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ChatAppearanceProfile.self, from: data)

        #expect(decoded.userLightTextStyles.strong.hex == "FF0000FF")
        #expect(decoded.userLightTextStyles.code.isEnabled == true)
        #expect(decoded.userLightTextStyles.usesAutomaticCodeSyntaxHighlighting == false)

        let legacyJSON = """
        {
          "id": "default",
          "name": "default",
          "userLightText": { "isEnabled": true, "hex": "123456FF" },
          "assistantDarkText": { "isEnabled": true, "hex": "ABCDEF88" }
        }
        """
        let legacyDecoded = try JSONDecoder().decode(
            ChatAppearanceProfile.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(legacyDecoded.userLightTextStyles.strong.isEnabled == false)
        #expect(legacyDecoded.userLightTextStyles.strong.hex == "123456FF")
        #expect(legacyDecoded.assistantDarkTextStyles.code.hex == "ABCDEF88")
        #expect(legacyDecoded.assistantDarkTextStyles.usesAutomaticCodeSyntaxHighlighting == true)
    }

    @Test("自定义文字颜色规则会随 Profile 持久化")
    func customTextColorRulesPersistWithProfile() throws {
        let rule = ChatAppearanceTextColorRule(
            id: "gpg-rule",
            kind: .exactText,
            exactText: "GPG",
            colorHex: "FF0000FF"
        )
        let profile = ChatAppearanceProfile(
            id: ChatAppearanceProfile.defaultProfileID,
            name: "default",
            assistantLightTextStyles: ChatAppearanceTextStyleColors(
                defaultHex: "1C1C1EFF",
                customRules: [rule]
            )
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ChatAppearanceProfile.self, from: data)

        #expect(decoded.assistantLightTextStyles.customRules == [rule])
        #expect(decoded.userLightTextStyles.customRules.isEmpty)
    }

    @Test("旧文字样式配置缺少规则字段时回退为空数组")
    func legacyTextStylesDecodeWithoutCustomRules() throws {
        let legacyJSON = """
        {
          "emphasis": { "isEnabled": false, "hex": "111111FF" },
          "strong": { "isEnabled": true, "hex": "222222FF" },
          "code": { "isEnabled": false, "hex": "333333FF" }
        }
        """

        let decoded = try JSONDecoder().decode(
            ChatAppearanceTextStyleColors.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.customRules.isEmpty)
        #expect(decoded.strong.hex == "222222FF")
    }

    @Test("精确文字规则会匹配全部非重叠文本")
    func exactTextRuleMatchesAllOccurrences() {
        let rule = ChatAppearanceTextColorRule(
            id: "exact",
            kind: .exactText,
            exactText: "GPG",
            colorHex: "FF0000FF"
        )

        let spans = ChatAppearanceTextColorMatcher.spans(in: "GPG 与 GPG", rules: [rule])

        #expect(spans.map(\.range) == [0..<3, 6..<9])
    }

    @Test("正则规则会着色完整匹配范围")
    func regularExpressionRuleMatchesFullRanges() {
        let rule = ChatAppearanceTextColorRule(
            id: "regex",
            kind: .regularExpression,
            exactText: "\\bG[A-Z]{2}\\b",
            colorHex: "FF0000FF"
        )

        let spans = ChatAppearanceTextColorMatcher.spans(
            in: "GPG GPS Gpg",
            rules: [rule]
        )

        #expect(spans.map(\.range) == [0..<3, 4..<7])
        #expect(spans.allSatisfy { $0.ruleID == "regex" })
    }

    @Test("正则规则可以分别配置颜色")
    func regularExpressionRulesKeepIndependentColors() {
        let uppercaseRule = ChatAppearanceTextColorRule(
            id: "uppercase",
            kind: .regularExpression,
            exactText: "[A-Z]+",
            colorHex: "FF0000FF"
        )
        let numberRule = ChatAppearanceTextColorRule(
            id: "number",
            kind: .regularExpression,
            exactText: "[0-9]+",
            colorHex: "0000FFFF"
        )

        let spans = ChatAppearanceTextColorMatcher.spans(
            in: "ABC 123",
            rules: [uppercaseRule, numberRule]
        )

        #expect(spans.map(\.colorHex) == ["FF0000FF", "0000FFFF"])
    }

    @Test("正则规则类型会随 Profile 持久化")
    func regularExpressionRulePersistsWithProfile() throws {
        let rule = ChatAppearanceTextColorRule(
            id: "regex",
            kind: .regularExpression,
            exactText: "G(P|S)G",
            colorHex: "FF00FFFF"
        )
        let profile = ChatAppearanceProfile(
            id: ChatAppearanceProfile.defaultProfileID,
            name: "default",
            assistantDarkTextStyles: ChatAppearanceTextStyleColors(
                defaultHex: "FFFFFFFF",
                customRules: [rule]
            )
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ChatAppearanceProfile.self, from: data)

        #expect(decoded.assistantDarkTextStyles.customRules == [rule])
        #expect(decoded.assistantDarkTextStyles.customRules.first?.kind == .regularExpression)
    }

    @Test("无效正则和零长度匹配不会产生颜色范围")
    func invalidAndEmptyRegularExpressionMatchesAreIgnored() async {
        let invalidRule = ChatAppearanceTextColorRule(
            kind: .regularExpression,
            exactText: "[",
            colorHex: "FF0000FF"
        )
        let zeroLengthRule = ChatAppearanceTextColorRule(
            kind: .regularExpression,
            exactText: "^",
            colorHex: "00FF00FF"
        )

        #expect(await ChatAppearanceTextColorMatcher.isValidRegularExpression("[") == false)
        #expect(ChatAppearanceTextColorMatcher.spans(in: "GPG", rules: [invalidRule, zeroLengthRule]).isEmpty)
    }

    @Test("成对标记规则支持方向标记和是否包含标记")
    func delimitedRuleSupportsDirectionalMarkers() {
        let includedRule = ChatAppearanceTextColorRule(
            id: "included",
            kind: .delimitedText,
            startDelimiter: "“",
            endDelimiter: "”",
            includesDelimiters: true,
            colorHex: "FF0000FF"
        )
        var contentOnlyRule = includedRule
        contentOnlyRule.id = "content-only"
        contentOnlyRule.includesDelimiters = false

        let included = ChatAppearanceTextColorMatcher.spans(in: "说“你好”吧", rules: [includedRule])
        let contentOnly = ChatAppearanceTextColorMatcher.spans(in: "说“你好”吧", rules: [contentOnlyRule])

        #expect(included.map(\.range) == [1..<5])
        #expect(contentOnly.map(\.range) == [2..<4])
    }

    @Test("相同起止标记会逐对匹配")
    func matchingDelimiterPairsAreSupported() {
        let rule = ChatAppearanceTextColorRule(
            kind: .delimitedText,
            startDelimiter: "\"",
            endDelimiter: "\"",
            includesDelimiters: false,
            colorHex: "FF0000FF"
        )

        let spans = ChatAppearanceTextColorMatcher.spans(
            in: "\"第一段\" 和 \"第二段\"",
            rules: [rule]
        )

        #expect(spans.map(\.range) == [1..<4, 9..<12])
    }

    @Test("未闭合标记不会产生颜色范围")
    func unclosedDelimiterDoesNotMatch() {
        let rule = ChatAppearanceTextColorRule(
            kind: .delimitedText,
            startDelimiter: "[",
            endDelimiter: "]",
            colorHex: "FF0000FF"
        )

        #expect(ChatAppearanceTextColorMatcher.spans(in: "前缀[未闭合", rules: [rule]).isEmpty)
    }

    @Test("靠前规则优先且受保护范围不会着色")
    func earlierRulesWinAndExcludedRangesStayUncolored() {
        let first = ChatAppearanceTextColorRule(
            id: "first",
            kind: .exactText,
            exactText: "GPG",
            colorHex: "FF0000FF"
        )
        let second = ChatAppearanceTextColorRule(
            id: "second",
            kind: .delimitedText,
            startDelimiter: "[",
            endDelimiter: "]",
            includesDelimiters: true,
            colorHex: "00FF00FF"
        )

        let spans = ChatAppearanceTextColorMatcher.spans(
            in: "[GPG] GPG",
            rules: [first, second],
            excludedRanges: [6..<9]
        )

        #expect(spans.map(\.ruleID) == ["second", "first", "second"])
        #expect(spans.map(\.range) == [0..<1, 1..<4, 4..<5])
    }

    @Test("后台渲染会覆盖粗体颜色并避开行内代码")
    func attributedRendererOverridesStrongButPreservesCode() async throws {
        let rule = ChatAppearanceTextColorRule(
            kind: .exactText,
            exactText: "GPG",
            colorHex: "FF0000FF"
        )
        let request = ChatAppearanceTextRuleRenderRequest(
            source: "**GPG** `GPG`",
            usesMarkdown: true,
            styleColors: ChatAppearanceTextStyleColors(
                defaultHex: "000000FF",
                strong: .init(isEnabled: true, hex: "00FF00FF"),
                customRules: [rule]
            )
        )

        let rendered = try #require(
            await ChatAppearanceTextRuleRenderer.shared.prepare(request: request)
        )
        let coloredRuns = rendered.runs.compactMap { run -> (String, String)? in
            guard let color = run.foregroundColor,
                  let hex = ChatAppearanceColorCodec.hexRGBA(from: color) else {
                return nil
            }
            return (String(rendered[run.range].characters), hex)
        }

        #expect(coloredRuns.contains { $0.0 == "GPG" && $0.1 == "FF0000FF" })
        #expect(coloredRuns.filter { $0.0 == "GPG" }.count == 1)
    }

    @Test("默认配置名称可以修改并持久化")
    @MainActor
    func defaultProfileNameCanBeRenamed() throws {
        let suite = "com.ETOS.tests.chatAppearance.renameDefault.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = ChatAppearanceProfileManager(
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            automaticallySchedulesRefresh: false
        )
        var defaultProfile = manager.configuration.defaultProfile
        defaultProfile.name = "晚间默认"

        try manager.updateProfile(defaultProfile)

        let reloaded = ChatAppearanceProfileStore.loadConfiguration(userDefaults: defaults)
        #expect(manager.configuration.defaultProfile.name == "晚间默认")
        #expect(reloaded.defaultProfile.name == "晚间默认")
    }

    @Test("时间窗会命中当前 Profile 并支持跨午夜")
    func scheduleRulesMatchAndCrossMidnight() {
        let nightProfile = ChatAppearanceProfile(id: "night", name: "Night")
        let dayProfile = ChatAppearanceProfile(id: "day", name: "Day")
        let configuration = ChatAppearanceProfileConfiguration(
            profiles: [ChatAppearanceProfile.defaultProfile, dayProfile, nightProfile],
            scheduleRules: [
                ChatAppearanceScheduleRule(profileID: "day", startMinuteOfDay: 8 * 60, endMinuteOfDay: 20 * 60),
                ChatAppearanceScheduleRule(profileID: "night", startMinuteOfDay: 20 * 60, endMinuteOfDay: 8 * 60)
            ]
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let dayTime = makeUTCDate(year: 2023, month: 11, day: 15, hour: 10, minute: 0)
        let nightTime = makeUTCDate(year: 2023, month: 11, day: 15, hour: 23, minute: 0)
        let earlyMorning = makeUTCDate(year: 2023, month: 11, day: 15, hour: 5, minute: 0)

        #expect(configuration.activeProfile(at: dayTime, calendar: calendar).id == "day")
        #expect(configuration.activeProfile(at: nightTime, calendar: calendar).id == "night")
        #expect(configuration.activeProfile(at: earlyMorning, calendar: calendar).id == "night")
    }

    @Test("无匹配时间段时回退 default")
    func noMatchFallsBackToDefaultProfile() {
        let dayProfile = ChatAppearanceProfile(id: "day", name: "Day")
        let configuration = ChatAppearanceProfileConfiguration(
            profiles: [ChatAppearanceProfile.defaultProfile, dayProfile],
            scheduleRules: [
                ChatAppearanceScheduleRule(profileID: "day", startMinuteOfDay: 8 * 60, endMinuteOfDay: 20 * 60)
            ]
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let fallbackTime = makeUTCDate(year: 2023, month: 11, day: 15, hour: 23, minute: 0)

        #expect(configuration.activeProfile(at: fallbackTime, calendar: calendar).id == ChatAppearanceProfile.defaultProfileID)
    }

    @Test("重叠时间段会被拒绝")
    func overlappingRulesAreRejected() {
        let configuration = ChatAppearanceProfileConfiguration(
            profiles: [ChatAppearanceProfile.defaultProfile, ChatAppearanceProfile(id: "alt", name: "Alt")],
            scheduleRules: [
                ChatAppearanceScheduleRule(profileID: "alt", startMinuteOfDay: 8 * 60, endMinuteOfDay: 12 * 60),
                ChatAppearanceScheduleRule(profileID: "alt", startMinuteOfDay: 11 * 60, endMinuteOfDay: 14 * 60)
            ]
        )

        do {
            try configuration.validateScheduleRules()
            Issue.record("预期应抛出重叠时间段错误。")
        } catch let error as ChatAppearanceProfileError {
            switch error {
            case .overlappingScheduleRules:
                break
            default:
                Issue.record("错误类型不符合预期：\(error.localizedDescription)")
            }
        } catch {
            Issue.record("抛出了非预期错误：\(error.localizedDescription)")
        }
    }

    @Test("新增时间段会避开已占用区间")
    func firstAvailableScheduleWindowSkipsOccupiedWindow() {
        let configuration = ChatAppearanceProfileConfiguration(
            profiles: [ChatAppearanceProfile.defaultProfile],
            scheduleRules: [
                ChatAppearanceScheduleRule(
                    profileID: ChatAppearanceProfile.defaultProfileID,
                    startMinuteOfDay: 9 * 60,
                    endMinuteOfDay: 18 * 60
                )
            ]
        )

        let window = configuration.firstAvailableScheduleWindow(preferredStartMinute: 9 * 60, durationMinutes: 60)

        #expect(window?.startMinuteOfDay == 18 * 60)
        #expect(window?.endMinuteOfDay == 19 * 60)
    }

    @Test("AppConfig 同步包不会携带颜色配置")
    func appStorageSnapshotDoesNotContainColorConfiguration() throws {
        let suite = "com.ETOS.tests.chatAppearance.sync.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试专用 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let configuration = ChatAppearanceProfileConfiguration(
            profiles: [
                ChatAppearanceProfile.defaultProfile,
                ChatAppearanceProfile(
                    id: "warm",
                    name: "Warm",
                    userBubble: .init(isEnabled: true, hex: "AA0000FF")
                )
            ],
            scheduleRules: [
                ChatAppearanceScheduleRule(profileID: "warm", startMinuteOfDay: 9 * 60, endMinuteOfDay: 18 * 60)
            ]
        )
        _ = try ChatAppearanceProfileStore.saveConfiguration(configuration, userDefaults: defaults)

        let package = SyncEngine.buildPackage(options: [.appStorage], userDefaults: defaults)
        guard let snapshotData = package.appStorageSnapshot,
              let plist = try? PropertyListSerialization.propertyList(from: snapshotData, options: [], format: nil),
              let snapshot = plist as? [String: Any] else {
            Issue.record("同步包快照解码失败")
            return
        }

        #expect(snapshot[ChatAppearanceProfileStore.configurationStorageKey] == nil)
    }

    private func makeUTCDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date ?? Date()
    }
}

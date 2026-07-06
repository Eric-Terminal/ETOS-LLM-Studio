// ============================================================================
// ChatAppearanceProfilesTests.swift
// ============================================================================
// 聊天颜色配置测试
// - 覆盖旧配置迁移、默认 Profile 复制、时间窗命中与重叠校验
// - 保障颜色配置不会混入 AppConfig 设置快照
// ============================================================================

import Foundation
import Testing
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
            darkText: .init(isEnabled: false, hex: "DDEEFF00")
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
        #expect(added.name == "Profile 1")
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

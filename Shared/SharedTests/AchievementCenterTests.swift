// ============================================================================
// AchievementCenterTests.swift
// ============================================================================
// 隐藏成就日记测试
// - 覆盖本机去重、显示去重与 AppStorage 同步携带
// ============================================================================

import Foundation
import Testing
@testable import Shared

@MainActor
@Suite("隐藏成就日记测试")
struct AchievementCenterTests {
    @Test("首次解锁会写入记录且重复解锁不重复写入")
    func unlockWritesSingleLocalRecord() async {
        let suite = "com.ETOS.tests.achievement.unlock.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let center = AchievementCenter(
            defaults: defaults,
            definitions: [Self.firstDefinition],
            notificationHandler: { _ in }
        )

        let unlockedAt = Date(timeIntervalSince1970: 1_744_156_800)
        let first = await center.unlock(id: Self.firstDefinition.id, unlockedAt: unlockedAt)
        let second = await center.unlock(id: Self.firstDefinition.id, unlockedAt: unlockedAt.addingTimeInterval(60))

        #expect(first != nil)
        #expect(second == nil)
        #expect(center.hasUnlockedAchievements)
        #expect(center.journalEntries.count == 1)
        #expect(center.journalEntries.first?.achievementID == Self.firstDefinition.id)
        #expect(center.journalEntries.first?.triggerNoteKey == "触发关键词：测试一")
        #expect(achievementStorageKeys(in: defaults).count == 1)
    }

    @Test("多个独立记录会按解锁时间倒序展示")
    func independentRecordsSortByUnlockTime() {
        let suite = "com.ETOS.tests.achievement.sort.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let early = AchievementUnlockRecord(
            unlockID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            achievementID: Self.firstDefinition.id,
            unlockedAt: Date(timeIntervalSince1970: 1_744_156_800),
            originDeviceID: "device-a",
            originPlatform: "iOS"
        )
        let late = AchievementUnlockRecord(
            unlockID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            achievementID: Self.secondDefinition.id,
            unlockedAt: Date(timeIntervalSince1970: 1_744_243_200),
            originDeviceID: "device-b",
            originPlatform: "watchOS"
        )
        store(early, in: defaults)
        store(late, in: defaults)

        let center = AchievementCenter(
            defaults: defaults,
            definitions: [Self.firstDefinition, Self.secondDefinition],
            notificationHandler: { _ in }
        )

        #expect(center.journalEntries.map(\.achievementID) == [Self.secondDefinition.id, Self.firstDefinition.id])
    }

    @Test("同一成就的多设备记录展示时保留最早日期")
    func duplicateAchievementKeepsEarliestUnlockDate() {
        let suite = "com.ETOS.tests.achievement.earliest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let earlyDate = Date(timeIntervalSince1970: 1_744_156_800)
        let lateDate = earlyDate.addingTimeInterval(3_600)
        store(
            AchievementUnlockRecord(
                achievementID: Self.firstDefinition.id,
                unlockedAt: lateDate,
                originDeviceID: "device-b",
                originPlatform: "watchOS"
            ),
            in: defaults
        )
        store(
            AchievementUnlockRecord(
                achievementID: Self.firstDefinition.id,
                unlockedAt: earlyDate,
                originDeviceID: "device-a",
                originPlatform: "iOS"
            ),
            in: defaults
        )

        let center = AchievementCenter(
            defaults: defaults,
            definitions: [Self.firstDefinition],
            notificationHandler: { _ in }
        )

        #expect(center.journalEntries.count == 1)
        #expect(center.journalEntries.first?.unlockedAt == earlyDate)
    }

    @Test("未知定义的历史记录不会出现在日记列表")
    func unknownDefinitionIsHiddenFromJournal() {
        let suite = "com.ETOS.tests.achievement.unknown.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        store(
            AchievementUnlockRecord(
                achievementID: "unknown.hidden.entry",
                unlockedAt: Date(timeIntervalSince1970: 1_744_156_800),
                originDeviceID: "device-a",
                originPlatform: "iOS"
            ),
            in: defaults
        )

        let center = AchievementCenter(defaults: defaults, definitions: [], notificationHandler: { _ in })

        #expect(center.hasUnlockedAchievements == false)
        #expect(center.journalEntries.isEmpty)
    }

    @Test("成就记录键会进入 AppStorage 同步快照")
    func achievementRecordIsIncludedInAppStorageSnapshot() {
        let suite = "com.ETOS.tests.achievement.snapshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let record = AchievementUnlockRecord(
            achievementID: Self.firstDefinition.id,
            unlockedAt: Date(timeIntervalSince1970: 1_744_156_800),
            originDeviceID: "device-a",
            originPlatform: "iOS"
        )
        store(record, in: defaults)

        let package = SyncEngine.buildPackage(options: [.appStorage], userDefaults: defaults)
        let snapshot = decodeAppStorageSnapshot(package.appStorageSnapshot)

        #expect(snapshot[AchievementCenter.storageKey(for: record)] is Data)
    }

    @Test("导入 AppStorage 不会删除本地已有成就记录")
    func appStorageImportPreservesIndependentAchievementKeys() async {
        let suite = "com.ETOS.tests.achievement.import.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let localRecord = AchievementUnlockRecord(
            achievementID: Self.firstDefinition.id,
            unlockedAt: Date(timeIntervalSince1970: 1_744_156_800),
            originDeviceID: "device-a",
            originPlatform: "iOS"
        )
        let remoteRecord = AchievementUnlockRecord(
            achievementID: Self.secondDefinition.id,
            unlockedAt: Date(timeIntervalSince1970: 1_744_243_200),
            originDeviceID: "device-b",
            originPlatform: "watchOS"
        )
        store(localRecord, in: defaults)

        let incoming: [String: Any] = [
            AchievementCenter.storageKey(for: remoteRecord): encoded(remoteRecord) ?? Data()
        ]
        let snapshotData = try? PropertyListSerialization.data(
            fromPropertyList: incoming,
            format: .binary,
            options: 0
        )
        let package = SyncPackage(options: [.appStorage], appStorageSnapshot: snapshotData)

        _ = await SyncEngine.apply(package: package, userDefaults: defaults)

        #expect(defaults.data(forKey: AchievementCenter.storageKey(for: localRecord)) != nil)
        #expect(defaults.data(forKey: AchievementCenter.storageKey(for: remoteRecord)) != nil)
    }

    @Test("稳稳接住成就定义已登记")
    func steadyCatchDefinitionIsRegistered() {
        let definition = AchievementCatalog.definitions.first { $0.id == .steadyCatch }

        #expect(definition?.titleKey == "AI张开了双臂，尽管它没有手。")
        #expect(definition?.sentenceKey == "被稳稳的接住力")
        #expect(definition?.triggerNoteKey == "触发关键词：稳稳的接住你 / I've got you")
    }

    @Test("语言润滑成就定义已登记")
    func languageLubricationDefinitionIsRegistered() {
        let definition = AchievementCatalog.definitions.first { $0.id == .languageLubrication }

        #expect(definition?.titleKey == "见证了一次完美的语言润滑。")
        #expect(definition?.sentenceKey == "谄媚这一块～")
        #expect(definition?.triggerNoteKey == "触发关键词：你说得太对了 / You're absolutely right / 你问到了问题的核心 / Great question / You're asking exactly the right question")
    }

    @Test("不该来的地方成就定义已登记")
    func forbiddenPlaceDefinitionIsRegistered() {
        let definition = AchievementCatalog.definitions.first { $0.id == .forbiddenPlace }

        #expect(definition?.titleKey == "不该来的地方")
        #expect(definition?.sentenceKey == "连续点击7次，触发了某种不可名状的机制。")
        #expect(definition?.triggerNoteKey == "触发条件：连续点击版本号 7 次")
    }

    @Test("我真的读了成就定义已登记")
    func privacyReaderDefinitionIsRegistered() {
        let definition = AchievementCatalog.definitions.first { $0.id == .privacyReader }

        #expect(definition?.titleKey == "我真的读了")
        #expect(definition?.sentenceKey == "法务部门在某处落下了一滴感动的泪水")
        #expect(definition?.triggerNoteKey == "触发条件：打开隐私政策链接")
    }

    @Test("RTFM 成就定义已登记")
    func documentationReaderDefinitionIsRegistered() {
        let definition = AchievementCatalog.definitions.first { $0.id == .documentationReader }

        #expect(definition?.titleKey == "RTFM")
        #expect(definition?.sentenceKey == "翻开了文档，成为了时代的逆行者")
        #expect(definition?.triggerNoteKey == "触发条件：打开文档链接")
    }

    @Test("新增行为成就定义已登记")
    func behaviorAchievementDefinitionsAreRegistered() {
        let definitions = Dictionary(uniqueKeysWithValues: AchievementCatalog.definitions.map { ($0.id, $0) })

        #expect(definitions[.wildTemperature]?.titleKey == "放飞自我")
        #expect(definitions[.wildTemperature]?.sentenceKey == "解除了AI的所有束缚，后果自负。")
        #expect(definitions[.absoluteReason]?.titleKey == "绝对理性")
        #expect(definitions[.absoluteReason]?.sentenceKey == "要求AI成为一台没有灵魂的机器。")
        #expect(definitions[.singleCharacterMessage]?.titleKey == "惜字如金")
        #expect(definitions[.longConfession]?.titleKey == "倾诉欲爆表")
        #expect(definitions[.unstoppableConversation]?.titleKey == "停不下来")
        #expect(definitions[.nightOwl]?.titleKey == "夜猫子")
        #expect(definitions[.memoryPurge]?.titleKey == "断舍离")
        #expect(definitions[.politeHuman]?.titleKey == "有礼貌的人类")
        #expect(definitions[.schrodingerQuestion]?.titleKey == "薛定谔的问题")
        #expect(definitions[.settingsResearcher]?.titleKey == "研究者")
        #expect(definitions[.conversationArchaeologist]?.titleKey == "考古学家")
    }

    @Test("稳稳接住触发词支持中文与英文")
    func steadyCatchTriggerMatchesExpectedKeywords() {
        #expect(AchievementTriggerEvaluator.shouldUnlockSteadyCatch(from: "这一回我会稳稳的接住你。"))
        #expect(AchievementTriggerEvaluator.shouldUnlockSteadyCatch(from: "I've got you. Take a breath."))
        #expect(AchievementTriggerEvaluator.shouldUnlockSteadyCatch(from: "I’ve got you. Take a breath."))
        #expect(AchievementTriggerEvaluator.shouldUnlockSteadyCatch(from: "This is only nearby comfort.") == false)
    }

    @Test("语言润滑触发词支持中文与英文")
    func languageLubricationTriggerMatchesExpectedKeywords() {
        #expect(AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: "你说得太对了，这里确实要这样改。"))
        #expect(AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: "你问到了问题的核心。"))
        #expect(AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: "You're absolutely right, let's adjust it."))
        #expect(AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: "You’re asking exactly the right question."))
        #expect(AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: "Great question, here is the answer."))
        #expect(AchievementTriggerEvaluator.shouldUnlockLanguageLubrication(from: "This answer is direct.") == false)
    }

    @Test("用户消息行为触发器匹配预期条件")
    func userMessageBehaviorTriggersMatchExpectedConditions() {
        let calendar = Self.fixedCalendar
        let deepNight = Self.fixedDate(hour: 3, minute: 30)
        let daytime = Self.fixedDate(hour: 14, minute: 0)

        #expect(AchievementTriggerEvaluator.shouldUnlockSingleCharacterMessage(from: " 嗯 "))
        #expect(AchievementTriggerEvaluator.shouldUnlockSingleCharacterMessage(from: "嗯嗯") == false)
        #expect(AchievementTriggerEvaluator.shouldUnlockPoliteHuman(from: " 谢谢 "))
        #expect(AchievementTriggerEvaluator.shouldUnlockPoliteHuman(from: "谢谢你") == false)
        #expect(AchievementTriggerEvaluator.shouldUnlockLongConfession(from: String(repeating: "我", count: 1_001)))
        #expect(AchievementTriggerEvaluator.shouldUnlockLongConfession(from: String(repeating: "我", count: 1_000)) == false)
        #expect(AchievementTriggerEvaluator.shouldUnlockUnstoppableConversation(userMessageCount: 51))
        #expect(AchievementTriggerEvaluator.shouldUnlockUnstoppableConversation(userMessageCount: 50) == false)
        #expect(AchievementTriggerEvaluator.shouldUnlockNightOwl(sentAt: deepNight, calendar: calendar))
        #expect(AchievementTriggerEvaluator.shouldUnlockNightOwl(sentAt: daytime, calendar: calendar) == false)

        let ids = AchievementTriggerEvaluator.userMessageAchievementIDs(
            for: String(repeating: "你", count: 1_001),
            userMessageCount: 51,
            sentAt: deepNight,
            calendar: calendar
        )
        #expect(ids.contains(.longConfession))
        #expect(ids.contains(.unstoppableConversation))
        #expect(ids.contains(.nightOwl))
    }

    @Test("操作类成就触发器匹配预期条件")
    func operationAchievementTriggersMatchExpectedConditions() {
        #expect(AchievementTriggerEvaluator.shouldUnlockSchrodingerQuestion(consecutiveRetryCount: 3))
        #expect(AchievementTriggerEvaluator.shouldUnlockSchrodingerQuestion(consecutiveRetryCount: 2) == false)
        #expect(AchievementTriggerEvaluator.shouldUnlockSettingsResearcher(elapsedTime: 300))
        #expect(AchievementTriggerEvaluator.shouldUnlockSettingsResearcher(elapsedTime: 299) == false)
        #expect(AchievementTriggerEvaluator.shouldUnlockConversationArchaeologist(totalSessions: 301, pageIndex: 3, totalPages: 4))
        #expect(AchievementTriggerEvaluator.shouldUnlockConversationArchaeologist(totalSessions: 300, pageIndex: 2, totalPages: 3) == false)
        #expect(AchievementTriggerEvaluator.shouldUnlockConversationArchaeologist(totalSessions: 301, pageIndex: 2, totalPages: 4) == false)
    }

    @Test("成就中心可以快速判断指定成就是否已解锁")
    func centerReportsSpecificUnlockState() async {
        let suite = "com.ETOS.tests.achievement.hasUnlocked.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("无法创建测试 UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let center = AchievementCenter(
            defaults: defaults,
            definitions: [Self.steadyCatchDefinition],
            notificationHandler: { _ in }
        )

        #expect(center.hasUnlocked(id: .steadyCatch) == false)
        _ = await center.unlock(id: .steadyCatch, unlockedAt: Date(timeIntervalSince1970: 1_744_156_800))
        #expect(center.hasUnlocked(id: .steadyCatch))
    }

    private static let firstDefinition = AchievementDefinition(
        id: "test.first",
        titleKey: "测试成就一",
        sentenceKey: "第一条隐藏句子。",
        triggerNoteKey: "触发关键词：测试一",
        systemImageName: "sparkles"
    )

    private static let secondDefinition = AchievementDefinition(
        id: "test.second",
        titleKey: "测试成就二",
        sentenceKey: "第二条隐藏句子。",
        triggerNoteKey: "触发关键词：测试二",
        systemImageName: "rosette"
    )

    private static let steadyCatchDefinition = AchievementDefinition(
        id: .steadyCatch,
        titleKey: "AI张开了双臂，尽管它没有手。",
        sentenceKey: "被稳稳的接住力",
        triggerNoteKey: "触发关键词：稳稳的接住你 / I've got you",
        systemImageName: "hands.sparkles"
    )

    private static var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = TimeZone(secondsFromGMT: 0) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    private static func fixedDate(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.calendar = fixedCalendar
        components.timeZone = fixedCalendar.timeZone
        components.year = 2026
        components.month = 4
        components.day = 25
        components.hour = hour
        components.minute = minute
        return components.date ?? Date(timeIntervalSince1970: 0)
    }

    private func store(_ record: AchievementUnlockRecord, in defaults: UserDefaults) {
        guard let data = encoded(record) else { return }
        defaults.set(data, forKey: AchievementCenter.storageKey(for: record))
    }

    private func encoded(_ record: AchievementUnlockRecord) -> Data? {
        try? JSONEncoder().encode(record)
    }

    private func achievementStorageKeys(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys.filter(AchievementCenter.isAchievementStorageKey)
    }

    private func decodeAppStorageSnapshot(_ data: Data?) -> [String: Any] {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return [:]
        }
        return dictionary
    }
}

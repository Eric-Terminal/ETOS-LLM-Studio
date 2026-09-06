// ============================================================================
// DailyPulseDeliveryAndNotificationTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 每日脉冲的提醒、后台预准备、交付与本地通知路由测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore
#if canImport(UserNotifications)
import UserNotifications
#endif

@Suite("每日脉冲交付与通知测试")
struct DailyPulseDeliveryAndNotificationTests {

    @Test("送达时间会输出两位时分并生成合法组件")
    func reminderTimeHelpersNormalizeValues() {
        #expect(DailyPulseDeliveryCoordinator.reminderTimeText(hour: 8, minute: 5) == "08:05")

        let components = DailyPulseDeliveryCoordinator.reminderDateComponents(hour: 28, minute: -3)
        #expect(components.hour == 23)
        #expect(components.minute == 0)
    }

    @Test("旧版提醒时间会迁移为三张卡片并支持归一化更新")
    @MainActor
    func legacyReminderMigratesToDeliveryTime() {
        let suiteName = "DailyPulseDeliveryCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "dailyPulse.delivery.reminderEnabled")
        defaults.set(8, forKey: "dailyPulse.delivery.reminderHour")
        defaults.set(30, forKey: "dailyPulse.delivery.reminderMinute")

        let coordinator = DailyPulseDeliveryCoordinator(defaults: defaults)
        #expect(coordinator.deliveryTimes.count == 3)
        #expect(coordinator.deliveryTimes.allSatisfy { $0.timeText == "08:30" })

        let id = coordinator.deliveryTimes[0].id
        #expect(coordinator.updateDeliveryTime(id: id, hour: 99, minute: -20))
        #expect(coordinator.deliveryTimes.first?.timeText == "23:00")
        #expect(coordinator.updateDeliveryTime(id: id, hour: 2, minute: 15))
        #expect(coordinator.deliveryTimes.first?.timeText == "02:15")
    }

    @Test("文本提醒时间支持常见 24 小时制输入格式")
    func reminderTimeComponentsParseCommonInputs() {
        let colonInput = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: "08:30")
        #expect(colonInput?.hour == 8)
        #expect(colonInput?.minute == 30)

        let fullWidthColonInput = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: "8：05")
        #expect(fullWidthColonInput?.hour == 8)
        #expect(fullWidthColonInput?.minute == 5)

        let compactInput = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: "1830")
        #expect(compactInput?.hour == 18)
        #expect(compactInput?.minute == 30)

        #expect(DailyPulseDeliveryCoordinator.reminderTimeComponents(from: "24:00") == nil)
        #expect(DailyPulseDeliveryCoordinator.reminderTimeComponents(from: "8:99") == nil)
        #expect(DailyPulseDeliveryCoordinator.reminderTimeComponents(from: "83000") == nil)
    }

    @Test("卡片通知会直接显示该卡片的标题和摘要")
    func cardNotificationShowsCardContent() {
        let card = DailyPulseCard(
            title: "需要关注的进展",
            whyRecommended: "与你最近的工作相关",
            summary: "这里直接显示卡片回复，不需要先打开应用。",
            detailsMarkdown: "详情",
            suggestedPrompt: "继续"
        )

        let notificationText = DailyPulseDeliveryCoordinator.cardNotificationText(for: card)

        #expect(notificationText.title == card.title)
        #expect(notificationText.body == card.summary)
    }

    @Test("卡片默认有三张并允许多张卡片使用相同时间")
    @MainActor
    func cardsCanBeAddedAndShareDeliveryTime() {
        let suiteName = "DailyPulseDeliveryTimesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coordinator = DailyPulseDeliveryCoordinator(defaults: defaults)
        #expect(coordinator.deliveryTimes.count == 3)
        let firstID = coordinator.deliveryTimes[0].id

        coordinator.setCardCount(10)
        #expect(coordinator.deliveryTimes.count == 10)
        let added = coordinator.deliveryTimes[1]
        #expect(coordinator.deliveryTimes.allSatisfy { $0.timeText == "08:30" })
        #expect(coordinator.updateDeliveryTime(
            id: added.id,
            hour: coordinator.deliveryTimes[0].hour,
            minute: coordinator.deliveryTimes[0].minute
        ))
        #expect(coordinator.removeCard(id: added.id))
        #expect(coordinator.deliveryTimes.count == 9)
        coordinator.setCardCount(1)
        #expect(!coordinator.removeCard(id: firstID))
    }

    @Test("旧版每卡一个时间的配置会原样保留")
    @MainActor
    func legacyPerCardTimesRemainIndependentCards() {
        let suiteName = "DailyPulseAutomaticTimesMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            """
            [
              {"id":"11111111-1111-1111-1111-111111111111","hour":8,"minute":30},
              {"id":"22222222-2222-2222-2222-222222222222","hour":12,"minute":30},
              {"id":"33333333-3333-3333-3333-333333333333","hour":16,"minute":30}
            ]
            """,
            forKey: "dailyPulse.delivery.times"
        )

        let coordinator = DailyPulseDeliveryCoordinator(defaults: defaults)

        #expect(coordinator.deliveryTimes.map(\.timeText) == ["08:30", "12:30", "16:30"])
    }

    @Test("上一版每个时间的卡片数量会展开为独立卡片时间")
    @MainActor
    func legacyBatchCardCountsExpandToCardTimes() {
        let suiteName = "DailyPulseBatchCardCountMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            """
            [
              {"id":"11111111-1111-1111-1111-111111111111","hour":8,"minute":30,"cardCount":3},
              {"id":"22222222-2222-2222-2222-222222222222","hour":18,"minute":0,"cardCount":2}
            ]
            """,
            forKey: "dailyPulse.delivery.times"
        )

        let coordinator = DailyPulseDeliveryCoordinator(defaults: defaults)

        #expect(coordinator.deliveryTimes.map(\.timeText) == ["08:30", "08:30", "08:30", "18:00", "18:00"])
        let reloadedCoordinator = DailyPulseDeliveryCoordinator(defaults: defaults)
        #expect(reloadedCoordinator.deliveryTimes.count == 5)
    }

    @Test("旧版无批次记录会按当前送达时间重新分配全部卡片")
    func legacyRunUsesCurrentDeliveryTimes() {
        let cards = (1...6).map { index in
            DailyPulseCard(
                title: "卡片 \(index)",
                whyRecommended: "原因 \(index)",
                summary: "摘要 \(index)",
                detailsMarkdown: "详情 \(index)",
                suggestedPrompt: "继续 \(index)"
            )
        }
        let run = DailyPulseRun(
            dayKey: "2026-08-07",
            generatedAt: Date(timeIntervalSince1970: 1_775_000_000),
            headline: "今日脉冲",
            cards: cards,
            sourceDigest: "legacy"
        )
        let deliveryTimes = (0..<6).map { index in
            index < 3
                ? DailyPulseDeliveryTime(hour: 8, minute: 30)
                : DailyPulseDeliveryTime(hour: 18, minute: 0)
        }

        let batches = DailyPulseDeliveryCoordinator.effectiveDeliveryBatches(
            for: run,
            deliveryTimes: deliveryTimes
        )

        #expect(batches.map(\.deliveryTimeID) == deliveryTimes.map(\.id))
        #expect(batches.allSatisfy { $0.cardIDs.count == 1 })
        #expect(batches.flatMap(\.cardIDs) == cards.map(\.id))
        #expect(DailyPulseDeliveryCoordinator.deliveryConfigurationRequiresRecovery(
            for: run,
            deliveryTimes: deliveryTimes
        ))
    }

    @Test("失配的旧送达时间标识会按当前顺序恢复且不丢卡")
    func staleDeliveryTimeIdentifiersRecoverByPosition() {
        let cards = (1...3).map { index in
            DailyPulseCard(
                title: "卡片 \(index)",
                whyRecommended: "原因 \(index)",
                summary: "摘要 \(index)",
                detailsMarkdown: "详情 \(index)",
                suggestedPrompt: "继续 \(index)"
            )
        }
        let storedBatches = [
            DailyPulseDeliveryBatch(
                deliveryTimeID: UUID(),
                scheduledAt: Date(timeIntervalSince1970: 1_775_010_000),
                headline: "上午",
                cardIDs: [cards[0].id]
            ),
            DailyPulseDeliveryBatch(
                deliveryTimeID: UUID(),
                scheduledAt: Date(timeIntervalSince1970: 1_775_020_000),
                headline: "下午",
                cardIDs: [cards[1].id, cards[2].id]
            )
        ]
        let run = DailyPulseRun(
            dayKey: "2026-08-07",
            generatedAt: Date(timeIntervalSince1970: 1_775_000_000),
            headline: "今日脉冲",
            cards: cards,
            sourceDigest: "stale",
            deliveryBatches: storedBatches
        )
        let deliveryTimes = [
            DailyPulseDeliveryTime(hour: 9, minute: 0),
            DailyPulseDeliveryTime(hour: 17, minute: 30)
        ]

        let batches = DailyPulseDeliveryCoordinator.effectiveDeliveryBatches(
            for: run,
            deliveryTimes: deliveryTimes
        )

        #expect(batches.map(\.deliveryTimeID) == deliveryTimes.map(\.id))
        #expect(batches.flatMap(\.cardIDs) == cards.map(\.id))
        #expect(DailyPulseDeliveryCoordinator.deliveryConfigurationRequiresRecovery(
            for: run,
            deliveryTimes: deliveryTimes
        ))
    }

    @Test("卡片送达日期会绑定目标日期和具体时间")
    func deliveryDateBindsDayAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone

        let deliveryDate = DailyPulseDeliveryCoordinator.deliveryDate(
            dayKey: "2026-03-23",
            time: DailyPulseDeliveryTime(hour: 13, minute: 45),
            calendar: calendar
        )

        #expect(formatter.string(from: deliveryDate!) == "2026-03-23T13:45:00Z")
        #expect(DailyPulseDeliveryCoordinator.hasFutureDeliveryTime(
            dayKey: "2026-03-23",
            deliveryTimes: [DailyPulseDeliveryTime(hour: 13, minute: 45)],
            referenceDate: formatter.date(from: "2026-03-23T13:00:00Z")!,
            calendar: calendar
        ))
    }

    @Test("明日内容缺失时后台预准备会尽快申请机会")
    func nextBackgroundPreparationDateRunsSoonWhenTomorrowIsMissing() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let referenceDate = formatter.date(from: "2026-03-22T01:00:00Z")!
        let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: 0,
            minute: 0,
            forceNextDay: false,
            leadTimeMinutes: 0,
            calendar: calendar
        )

        #expect(formatter.string(from: scheduledDate!) == "2026-03-22T01:01:00Z")
    }

    @Test("过了日界线后后台预准备不等待固定晚间时间")
    func nextBackgroundPreparationDateFallsBackToSoon() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let referenceDate = formatter.date(from: "2026-03-22T08:25:00Z")!
        let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: 0,
            minute: 0,
            forceNextDay: false,
            leadTimeMinutes: 0,
            calendar: calendar
        )

        #expect(formatter.string(from: scheduledDate!) == "2026-03-22T08:26:00Z")
    }

    @Test("今天已经有卡片时，后台预准备会直接改排明天")
    func nextBackgroundPreparationDateSkipsToNextDayWhenTodayAlreadyPrepared() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let referenceDate = formatter.date(from: "2026-03-22T07:00:00Z")!
        let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: 0,
            minute: 0,
            forceNextDay: true,
            leadTimeMinutes: 0,
            calendar: calendar
        )

        #expect(formatter.string(from: scheduledDate!) == "2026-03-23T00:00:00Z")
    }

    @Test("到达首个时间点后才允许定时送达尝试")
    func morningDeliveryRequiresReminderTimeReached() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let beforeReminder = formatter.date(from: "2026-03-22T07:59:00Z")!
        let afterReminder = formatter.date(from: "2026-03-22T08:01:00Z")!

        #expect(!DailyPulseDeliveryCoordinator.hasReachedReminderTime(
            referenceDate: beforeReminder,
            hour: 8,
            minute: 0,
            calendar: calendar
        ))
        #expect(DailyPulseDeliveryCoordinator.hasReachedReminderTime(
            referenceDate: afterReminder,
            hour: 8,
            minute: 0,
            calendar: calendar
        ))
    }

    @Test("定时送达只会在首个时间点后且当天尚未尝试时触发")
    func scheduledDeliveryRunsOncePerDayAfterReminderTime() {
        let referenceDate = ISO8601DateFormatter().date(from: "2026-03-22T09:30:00Z")!

        #expect(DailyPulseManager.shouldProcessScheduledDelivery(
            reminderEnabled: true,
            deliveryTimes: [
                DailyPulseDeliveryTime(hour: 18, minute: 0),
                DailyPulseDeliveryTime(hour: 8, minute: 0)
            ],
            referenceDate: referenceDate,
            lastDeliveryAttemptDayKey: nil
        ))

        #expect(!DailyPulseManager.shouldProcessScheduledDelivery(
            reminderEnabled: true,
            deliveryTimes: [DailyPulseDeliveryTime(hour: 8, minute: 0)],
            referenceDate: referenceDate,
            lastDeliveryAttemptDayKey: "2026-03-22"
        ))
    }

    @Test("首个时间点后若今天已有卡片，定时送达会复用现有卡片")
    func scheduledDeliveryCanReuseExistingTodayRun() {
        let referenceDate = ISO8601DateFormatter().date(from: "2026-03-22T09:30:00Z")!

        #expect(DailyPulseManager.shouldUseExistingRunForScheduledDelivery(
            todayRunDayKey: "2026-03-22",
            referenceDate: referenceDate
        ))

        #expect(!DailyPulseManager.shouldUseExistingRunForScheduledDelivery(
            todayRunDayKey: "2026-03-21",
            referenceDate: referenceDate
        ))

        #expect(!DailyPulseManager.shouldUseExistingRunForScheduledDelivery(
            todayRunDayKey: nil,
            referenceDate: referenceDate
        ))
    }

    @Test("过期的每日脉冲只保留今天这一期")
    func visibleRunsOnlyKeepToday() {
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!
        let yesterdayRun = DailyPulseRun(
            dayKey: "2026-03-21",
            generatedAt: formatter.date(from: "2026-03-21T08:00:00Z")!,
            headline: "昨天的卡片",
            cards: [DailyPulseCard(title: "旧卡片", whyRecommended: "旧", summary: "旧", detailsMarkdown: "旧", suggestedPrompt: "旧")],
            sourceDigest: "old"
        )
        let todayRun = DailyPulseRun(
            dayKey: "2026-03-22",
            generatedAt: formatter.date(from: "2026-03-22T08:00:00Z")!,
            headline: "今天的卡片",
            cards: [DailyPulseCard(title: "今天卡片", whyRecommended: "今", summary: "今", detailsMarkdown: "今", suggestedPrompt: "今")],
            sourceDigest: "today"
        )

        let visible = DailyPulseManager.visibleRuns(from: [yesterdayRun, todayRun], referenceDate: referenceDate)

        #expect(visible.count == 1)
        #expect(visible.first?.dayKey == "2026-03-22")
    }

    @Test("持久化运行记录会同时保留今天与明天")
    func retainedRunsKeepTodayAndTomorrow() {
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!
        let yesterdayRun = makeRun(dayKey: "2026-03-21", generatedAt: formatter.date(from: "2026-03-21T08:00:00Z")!)
        let todayRun = makeRun(dayKey: "2026-03-22", generatedAt: formatter.date(from: "2026-03-22T08:00:00Z")!)
        let tomorrowRun = makeRun(dayKey: "2026-03-23", generatedAt: formatter.date(from: "2026-03-22T20:00:00Z")!)

        let retained = DailyPulseManager.retainedRuns(
            from: [yesterdayRun, todayRun, tomorrowRun],
            referenceDate: referenceDate
        )

        #expect(Set(retained.map(\.dayKey)) == ["2026-03-22", "2026-03-23"])
    }

    @Test("相同时间的卡片会合并为一次生成分组")
    func sameTimeCardsShareGenerationGroup() {
        let groups = DailyPulseDeliveryCoordinator.groupedCardDeliveryTimes([
            DailyPulseDeliveryTime(hour: 8, minute: 30),
            DailyPulseDeliveryTime(hour: 18, minute: 0),
            DailyPulseDeliveryTime(hour: 8, minute: 30)
        ])

        #expect(groups.map { $0.count } == [2, 1])
        #expect(groups.map { $0.first?.timeText } == ["08:30", "18:00"])
    }

    @Test("准备状态会按当天开启和收口")
    @MainActor
    func preparationStateLifecycle() {
        let manager = DailyPulseManager(
            chatService: ChatService(),
            memoryManager: MemoryManager()
        )
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!

        manager.beginPreparation(dayKey: "2026-03-22", referenceDate: referenceDate)
        #expect(manager.preparingDayKey == "2026-03-22")
        #expect(DailyPulseManager.isPreparingPulse(
            preparingDayKey: manager.preparingDayKey,
            todayRunDayKey: manager.todayRun?.dayKey,
            referenceDate: referenceDate
        ))
        #expect(manager.lastPreparationStartedAt == referenceDate)

        manager.finishPreparation()
        #expect(manager.preparingDayKey == nil)
        #expect(!DailyPulseManager.isPreparingPulse(
            preparingDayKey: manager.preparingDayKey,
            todayRunDayKey: manager.todayRun?.dayKey,
            referenceDate: referenceDate
        ))
    }

    private func makeRun(dayKey: String, generatedAt: Date) -> DailyPulseRun {
        DailyPulseRun(
            dayKey: dayKey,
            generatedAt: generatedAt,
            headline: dayKey,
            cards: [
                DailyPulseCard(
                    title: dayKey,
                    whyRecommended: dayKey,
                    summary: dayKey,
                    detailsMarkdown: dayKey,
                    suggestedPrompt: dayKey
                )
            ],
            sourceDigest: dayKey
        )
    }

    @Test("今天正在准备时不应误判为普通空白")
    @MainActor
    func preparingTodayPulseUsesPreparingState() {
        let manager = DailyPulseManager(
            chatService: ChatService(),
            memoryManager: MemoryManager()
        )
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!

        manager.beginPreparation(dayKey: "2026-03-22", referenceDate: referenceDate)
        #expect(manager.todayRun == nil)
        #expect(DailyPulseManager.isPreparingPulse(
            preparingDayKey: manager.preparingDayKey,
            todayRunDayKey: manager.todayRun?.dayKey,
            referenceDate: referenceDate
        ))
        #expect(!manager.hasUnviewedTodayRun)
    }

#if canImport(UserNotifications)
    @Test("未宿主单元测试不会访问系统通知中心")
    @MainActor
    func unhostedUnitTestsDoNotAccessSystemNotificationCenter() async {
        let center = AppLocalNotificationCenter.shared
        #expect(await center.requestAuthorizationIfNeeded() == false)
        #expect(await center.refreshAuthorizationStatus() == .denied)
    }

    @Test("Daily Pulse 通知路由能识别目标 userInfo")
    func dailyPulseNotificationRouteDetection() {
        let userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(
            kind: "reminder",
            dayKey: "2026-03-23"
        )

        #expect(AppLocalNotificationCenter.notificationTargetsDailyPulse(userInfo: userInfo))
        #expect(!AppLocalNotificationCenter.notificationTargetsDailyPulse(userInfo: ["route": "other"]))
    }

    @MainActor
    @Test("卡片通知点击后会保留精确的运行与卡片目标")
    func dailyPulseCardNotificationTapStoresSelection() {
        let center = AppLocalNotificationCenter.shared
        _ = center.consumePendingRoute()
        _ = center.consumePendingDailyPulseSelection()
        let runID = UUID()
        let cardID = UUID()

        center.handleNotificationResponseUserInfo(
            AppLocalNotificationCenter.dailyPulseUserInfo(
                kind: "card",
                dayKey: "2026-03-23",
                runID: runID,
                cardID: cardID
            ),
            actionIdentifier: UNNotificationDefaultActionIdentifier
        )

        #expect(center.consumePendingRoute() == .dailyPulse)
        #expect(center.consumePendingDailyPulseSelection() == .init(runID: runID, cardID: cardID))
    }

    @Test("反馈通知路由能识别目标 userInfo")
    func feedbackNotificationRouteDetection() {
        let userInfo: [AnyHashable: Any] = [
            "route": "feedback",
            "issue_number": 12345
        ]

        #expect(AppLocalNotificationCenter.notificationTargetsFeedback(userInfo: userInfo))
        #expect(!AppLocalNotificationCenter.notificationTargetsFeedback(userInfo: ["route": "dailyPulse"]))
    }

    @Test("聊天会话通知路由能识别目标 userInfo")
    func chatSessionNotificationRouteDetection() {
        let userInfo: [AnyHashable: Any] = [
            "route": "chatSession",
            "session_id": UUID().uuidString
        ]

        #expect(AppLocalNotificationCenter.notificationTargetsChatSession(userInfo: userInfo))
        #expect(!AppLocalNotificationCenter.notificationTargetsChatSession(userInfo: ["route": "feedback"]))
    }

    @Test("上下文压缩通知路由会携带目标会话")
    func contextCompressionNotificationRouteDetection() {
        let expectedSessionID = UUID()
        let userInfo = AppLocalNotificationCenter.contextCompressionUserInfo(
            sessionID: expectedSessionID
        )

        #expect(AppLocalNotificationCenter.notificationTargetsContextCompression(userInfo: userInfo))
        #expect(userInfo["session_id"] as? String == expectedSessionID.uuidString)
        #expect(!AppLocalNotificationCenter.notificationTargetsContextCompression(userInfo: ["route": "chatSession"]))
    }

    @MainActor
    @Test("聊天会话通知点击后会写入待处理会话路由数据")
    func chatSessionNotificationTapStoresPendingRoute() {
        let center = AppLocalNotificationCenter.shared
        _ = center.consumePendingRoute()
        _ = center.consumePendingChatSessionID()

        let expectedSessionID = UUID()
        let userInfo: [AnyHashable: Any] = [
            "route": "chatSession",
            "session_id": expectedSessionID.uuidString
        ]

        center.handleNotificationResponseUserInfo(
            userInfo,
            actionIdentifier: "unit-test"
        )

        #expect(center.consumePendingRoute() == .chatSession)
        #expect(center.consumePendingChatSessionID() == expectedSessionID)
    }

    @MainActor
    @Test("上下文压缩通知点击后会写入待压缩会话")
    func contextCompressionNotificationTapStoresPendingRoute() {
        let center = AppLocalNotificationCenter.shared
        _ = center.consumePendingRoute()
        _ = center.consumePendingContextCompressionSessionID()

        let expectedSessionID = UUID()
        center.handleNotificationResponseUserInfo(
            AppLocalNotificationCenter.contextCompressionUserInfo(sessionID: expectedSessionID),
            actionIdentifier: "unit-test"
        )

        #expect(center.consumePendingRoute() == .contextCompression)
        #expect(center.consumePendingContextCompressionSessionID() == expectedSessionID)
    }
#endif
}

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

    @Test("晨间提醒时间会输出两位时分并生成合法组件")
    func reminderTimeHelpersNormalizeValues() {
        #expect(DailyPulseDeliveryCoordinator.reminderTimeText(hour: 8, minute: 5) == "08:05")

        let components = DailyPulseDeliveryCoordinator.reminderDateComponents(hour: 28, minute: -3)
        #expect(components.hour == 23)
        #expect(components.minute == 0)
    }

    @Test("修改提醒时分时会先归一化并避免发布属性递归崩溃")
    @MainActor
    func reminderPropertiesNormalizeWithoutRecursiveSet() {
        let suiteName = "DailyPulseDeliveryCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "dailyPulse.delivery.reminderEnabled")
        defaults.set(8, forKey: "dailyPulse.delivery.reminderHour")
        defaults.set(30, forKey: "dailyPulse.delivery.reminderMinute")

        let coordinator = DailyPulseDeliveryCoordinator(defaults: defaults)
        coordinator.reminderHour = 9
        coordinator.reminderMinute = 15
        #expect(coordinator.reminderHour == 9)
        #expect(coordinator.reminderMinute == 15)

        coordinator.reminderHour = 99
        coordinator.reminderMinute = -20
        #expect(coordinator.reminderHour == 23)
        #expect(coordinator.reminderMinute == 0)
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

    @Test("后台预准备时间会优先落在提醒前的准备窗口")
    func nextBackgroundPreparationDatePrefersLeadWindow() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let referenceDate = formatter.date(from: "2026-03-22T01:00:00Z")!
        let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: 8,
            minute: 30,
            forceNextDay: false,
            leadTimeMinutes: 15,
            calendar: calendar
        )

        #expect(formatter.string(from: scheduledDate!) == "2026-03-22T08:15:00Z")
    }

    @Test("进入准备窗口后，后台预准备会尽快补一个未来时间")
    func nextBackgroundPreparationDateFallsBackToSoon() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.timeZone = timeZone
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        let referenceDate = formatter.date(from: "2026-03-22T08:25:00Z")!
        let scheduledDate = DailyPulseDeliveryCoordinator.nextBackgroundPreparationDate(
            referenceDate: referenceDate,
            hour: 8,
            minute: 30,
            forceNextDay: false,
            leadTimeMinutes: 15,
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
            hour: 8,
            minute: 30,
            forceNextDay: true,
            leadTimeMinutes: 15,
            calendar: calendar
        )

        #expect(formatter.string(from: scheduledDate!) == "2026-03-23T08:15:00Z")
    }

    @Test("到达提醒时间后才允许晨间送达尝试")
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

    @Test("晨间送达只会在提醒时间后且当天尚未尝试时触发")
    func scheduledDeliveryRunsOncePerDayAfterReminderTime() {
        let referenceDate = ISO8601DateFormatter().date(from: "2026-03-22T09:30:00Z")!

        #expect(DailyPulseManager.shouldProcessScheduledDelivery(
            reminderEnabled: true,
            reminderHour: 8,
            reminderMinute: 0,
            referenceDate: referenceDate,
            lastDeliveryAttemptDayKey: nil
        ))

        #expect(!DailyPulseManager.shouldProcessScheduledDelivery(
            reminderEnabled: true,
            reminderHour: 8,
            reminderMinute: 0,
            referenceDate: referenceDate,
            lastDeliveryAttemptDayKey: "2026-03-22"
        ))
    }

    @Test("提醒时间后若今天已有卡片，晨间送达会复用现有卡片补发就绪通知")
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

    @Test("准备状态会按当天开启和收口")
    @MainActor
    func preparationStateLifecycle() {
        let manager = DailyPulseManager(
            chatService: ChatService(),
            memoryManager: MemoryManager()
        )
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!

        manager.beginPreparation(referenceDate: referenceDate)
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

    @Test("今天正在准备时不应误判为普通空白")
    @MainActor
    func preparingTodayPulseUsesPreparingState() {
        let manager = DailyPulseManager(
            chatService: ChatService(),
            memoryManager: MemoryManager()
        )
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-03-22T09:30:00Z")!

        manager.beginPreparation(referenceDate: referenceDate)
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

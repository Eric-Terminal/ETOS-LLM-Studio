// ============================================================================
// DailyPulseDeliveryCoordinator.swift
// ============================================================================
// ETOS LLM Studio 每日脉冲主动送达协调器
//
// 功能特性:
// - 管理晨间提醒开关与提醒时间
// - 负责调度或移除每日重复的本地提醒
// - 为 UI 提供提醒时间说明与通知权限状态摘要
// ============================================================================

import Foundation
import Combine

#if canImport(UserNotifications)
import UserNotifications
#endif

@MainActor
public final class DailyPulseDeliveryCoordinator: ObservableObject {
    public static let shared = DailyPulseDeliveryCoordinator()

    @Published public var reminderEnabled: Bool {
        didSet {
            defaults.set(reminderEnabled, forKey: Self.reminderEnabledDefaultsKey)
            Task {
                await refreshReminderSchedule()
            }
        }
    }
    @Published public var reminderHour: Int {
        didSet {
            reminderHour = Self.normalizedHour(reminderHour)
            defaults.set(reminderHour, forKey: Self.reminderHourDefaultsKey)
            Task {
                await refreshReminderSchedule()
            }
        }
    }
    @Published public var reminderMinute: Int {
        didSet {
            reminderMinute = Self.normalizedMinute(reminderMinute)
            defaults.set(reminderMinute, forKey: Self.reminderMinuteDefaultsKey)
            Task {
                await refreshReminderSchedule()
            }
        }
    }

    private let defaults: UserDefaults

    private static let reminderIdentifier = "dailyPulse.reminder.daily"
    private static let readyIdentifierPrefix = "dailyPulse.ready."
    private static let reminderEnabledDefaultsKey = "dailyPulse.delivery.reminderEnabled"
    private static let reminderHourDefaultsKey = "dailyPulse.delivery.reminderHour"
    private static let reminderMinuteDefaultsKey = "dailyPulse.delivery.reminderMinute"
    private static let lastReadyDayKeyDefaultsKey = "dailyPulse.delivery.lastReadyDayKey"

    @Published public private(set) var lastReadyDayKey: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Self.reminderEnabledDefaultsKey) == nil {
            defaults.set(false, forKey: Self.reminderEnabledDefaultsKey)
        }
        if defaults.object(forKey: Self.reminderHourDefaultsKey) == nil {
            defaults.set(8, forKey: Self.reminderHourDefaultsKey)
        }
        if defaults.object(forKey: Self.reminderMinuteDefaultsKey) == nil {
            defaults.set(30, forKey: Self.reminderMinuteDefaultsKey)
        }
        self.reminderEnabled = defaults.object(forKey: Self.reminderEnabledDefaultsKey) as? Bool ?? false
        self.reminderHour = Self.normalizedHour(defaults.object(forKey: Self.reminderHourDefaultsKey) as? Int ?? 8)
        self.reminderMinute = Self.normalizedMinute(defaults.object(forKey: Self.reminderMinuteDefaultsKey) as? Int ?? 30)
        self.lastReadyDayKey = defaults.string(forKey: Self.lastReadyDayKeyDefaultsKey)
    }

    public func activate() {
        AppLocalNotificationCenter.shared.configureIfNeeded()
        Task {
            await refreshReminderSchedule()
        }
    }

    public var reminderTimeText: String {
        Self.reminderTimeText(hour: reminderHour, minute: reminderMinute)
    }

    public var reminderStatusText: String {
#if canImport(UserNotifications)
        switch AppLocalNotificationCenter.shared.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return reminderEnabled
                ? "将于每天 \(reminderTimeText) 提醒你查看每日脉冲；到点后，应用在前台恢复时会自动尝试准备今天这一期，准备好后还会补发一条就绪通知。"
                : "提醒已关闭；你仍可在应用内手动查看今日卡片。"
        case .denied:
            return "系统通知权限当前未开启，晨间提醒暂时不会送达。"
        case .notDetermined:
            return reminderEnabled ? "首次开启后会请求通知权限，用于晨间提醒与晨间送达尝试。" : "开启后会在设定时间提醒你查看今日脉冲。"
        @unknown default:
            return "通知权限状态暂时未知。"
        }
#else
        return "当前平台暂不支持本地通知提醒。"
#endif
    }

    public func refreshReminderSchedule() async {
#if canImport(UserNotifications)
        AppLocalNotificationCenter.shared.configureIfNeeded()
        if !reminderEnabled {
            AppLocalNotificationCenter.shared.removePendingRequests(withIdentifiers: [Self.reminderIdentifier])
            AppLocalNotificationCenter.shared.removeDeliveredRequests(withIdentifiers: [Self.reminderIdentifier])
            _ = await AppLocalNotificationCenter.shared.refreshAuthorizationStatus()
            return
        }

        let granted = await AppLocalNotificationCenter.shared.requestAuthorizationIfNeeded(options: [.alert, .sound, .badge])
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "每日脉冲"
        content.body = "到了查看今天每日脉冲的时间。打开 ETOS LLM Studio，看看新的主动情报卡片。"
        content.sound = .default
        content.threadIdentifier = "dailyPulse.delivery"
        content.categoryIdentifier = AppLocalNotificationCenter.dailyPulseCategoryIdentifier(kind: "reminder")
        content.userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(kind: "reminder")

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Self.reminderDateComponents(hour: reminderHour, minute: reminderMinute),
            repeats: true
        )
        let request = UNNotificationRequest(
            identifier: Self.reminderIdentifier,
            content: content,
            trigger: trigger
        )

        AppLocalNotificationCenter.shared.removePendingRequests(withIdentifiers: [Self.reminderIdentifier])
        _ = await AppLocalNotificationCenter.shared.addNotificationRequest(request)
        _ = await AppLocalNotificationCenter.shared.refreshAuthorizationStatus()
#endif
    }

    public func notifyReadyIfNeeded(for run: DailyPulseRun) async {
#if canImport(UserNotifications)
        guard reminderEnabled else { return }
        guard lastReadyDayKey != run.dayKey else { return }
        let status = await AppLocalNotificationCenter.shared.refreshAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "每日脉冲已准备好"
        let primaryCard = run.visibleCards.first ?? run.cards.first
        let primaryCardSuffix = primaryCard.map { "主卡「\($0.title)」。" } ?? ""
        content.body = "今天的每日脉冲已经整理完成，已为你准备 \(run.visibleCards.count) 张主动情报卡片。\(primaryCardSuffix)"
        content.sound = .default
        content.threadIdentifier = "dailyPulse.delivery"
        content.categoryIdentifier = AppLocalNotificationCenter.dailyPulseCategoryIdentifier(kind: "ready")
        content.userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(
            kind: "ready",
            dayKey: run.dayKey,
            runID: run.id,
            cardID: primaryCard?.id
        )

        let identifier = Self.readyIdentifierPrefix + run.dayKey
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let didSchedule = await AppLocalNotificationCenter.shared.addNotificationRequest(request)
        if didSchedule {
            lastReadyDayKey = run.dayKey
            defaults.set(run.dayKey, forKey: Self.lastReadyDayKeyDefaultsKey)
        }
#endif
    }

    internal nonisolated static func reminderDateComponents(hour: Int, minute: Int) -> DateComponents {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.hour = normalizedHour(hour)
        components.minute = normalizedMinute(minute)
        return components
    }

    internal nonisolated static func reminderTimeText(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", normalizedHour(hour), normalizedMinute(minute))
    }

    internal nonisolated static func hasReachedReminderTime(
        referenceDate: Date,
        hour: Int,
        minute: Int,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        let normalizedHour = normalizedHour(hour)
        let normalizedMinute = normalizedMinute(minute)

        guard let reminderDate = calendar.date(
            bySettingHour: normalizedHour,
            minute: normalizedMinute,
            second: 0,
            of: referenceDate
        ) else {
            return false
        }
        return referenceDate >= reminderDate
    }

    internal nonisolated static func normalizedHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    internal nonisolated static func normalizedMinute(_ minute: Int) -> Int {
        min(max(minute, 0), 59)
    }
}

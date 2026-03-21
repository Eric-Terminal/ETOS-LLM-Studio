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
    private static let reminderEnabledDefaultsKey = "dailyPulse.delivery.reminderEnabled"
    private static let reminderHourDefaultsKey = "dailyPulse.delivery.reminderHour"
    private static let reminderMinuteDefaultsKey = "dailyPulse.delivery.reminderMinute"

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
            return reminderEnabled ? "将于每天 \(reminderTimeText) 提醒你查看每日脉冲。" : "提醒已关闭；你仍可在应用内手动查看今日卡片。"
        case .denied:
            return "系统通知权限当前未开启，晨间提醒暂时不会送达。"
        case .notDetermined:
            return reminderEnabled ? "首次开启后会请求通知权限，用于晨间提醒。" : "开启后会在设定时间提醒你查看今日脉冲。"
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

    internal static func reminderDateComponents(hour: Int, minute: Int) -> DateComponents {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.hour = normalizedHour(hour)
        components.minute = normalizedMinute(minute)
        return components
    }

    internal static func reminderTimeText(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", normalizedHour(hour), normalizedMinute(minute))
    }

    internal static func normalizedHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    internal static func normalizedMinute(_ minute: Int) -> Int {
        min(max(minute, 0), 59)
    }
}

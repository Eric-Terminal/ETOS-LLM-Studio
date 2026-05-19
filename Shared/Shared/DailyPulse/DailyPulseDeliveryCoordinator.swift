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
            Self.save(reminderEnabled, forKey: Self.reminderEnabledDefaultsKey, defaults: defaults)
            guard !isApplyingStoredSettings else { return }
            Task {
                await refreshReminderSchedule()
            }
        }
    }
    @Published public var reminderHour: Int {
        didSet {
            let normalizedHour = Self.normalizedHour(reminderHour)
            guard normalizedHour == reminderHour else {
                reminderHour = normalizedHour
                return
            }
            Self.save(reminderHour, forKey: Self.reminderHourDefaultsKey, defaults: defaults)
            guard !isApplyingStoredSettings else { return }
            Task {
                await refreshReminderSchedule()
            }
        }
    }
    @Published public var reminderMinute: Int {
        didSet {
            let normalizedMinute = Self.normalizedMinute(reminderMinute)
            guard normalizedMinute == reminderMinute else {
                reminderMinute = normalizedMinute
                return
            }
            Self.save(reminderMinute, forKey: Self.reminderMinuteDefaultsKey, defaults: defaults)
            guard !isApplyingStoredSettings else { return }
            Task {
                await refreshReminderSchedule()
            }
        }
    }

    private let defaults: UserDefaults
    private var isApplyingStoredSettings = false

    private static let reminderIdentifier = "dailyPulse.reminder.daily"
    private static let readyIdentifierPrefix = "dailyPulse.ready."
    private static let reminderEnabledDefaultsKey = "dailyPulse.delivery.reminderEnabled"
    private static let reminderHourDefaultsKey = "dailyPulse.delivery.reminderHour"
    private static let reminderMinuteDefaultsKey = "dailyPulse.delivery.reminderMinute"
    private static let lastReadyDayKeyDefaultsKey = "dailyPulse.delivery.lastReadyDayKey"

    @Published public private(set) var lastReadyDayKey: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reminderEnabled = Self.boolValue(forKey: Self.reminderEnabledDefaultsKey, defaults: defaults, defaultValue: false)
        self.reminderHour = Self.normalizedHour(Self.integerValue(forKey: Self.reminderHourDefaultsKey, defaults: defaults, defaultValue: 8))
        self.reminderMinute = Self.normalizedMinute(Self.integerValue(forKey: Self.reminderMinuteDefaultsKey, defaults: defaults, defaultValue: 30))
        let storedLastReadyDayKey = Self.textValue(forKey: Self.lastReadyDayKeyDefaultsKey, defaults: defaults, defaultValue: "")
        self.lastReadyDayKey = storedLastReadyDayKey.isEmpty ? nil : storedLastReadyDayKey
    }

    public func activate() {
        AppLocalNotificationCenter.shared.configureIfNeeded()
        Task {
            await refreshReminderSchedule()
        }
    }

    public func reloadFromStorage() {
        isApplyingStoredSettings = true
        reminderEnabled = Self.boolValue(forKey: Self.reminderEnabledDefaultsKey, defaults: defaults, defaultValue: false)
        reminderHour = Self.normalizedHour(Self.integerValue(forKey: Self.reminderHourDefaultsKey, defaults: defaults, defaultValue: 8))
        reminderMinute = Self.normalizedMinute(Self.integerValue(forKey: Self.reminderMinuteDefaultsKey, defaults: defaults, defaultValue: 30))
        let storedLastReadyDayKey = Self.textValue(forKey: Self.lastReadyDayKeyDefaultsKey, defaults: defaults, defaultValue: "")
        lastReadyDayKey = storedLastReadyDayKey.isEmpty ? nil : storedLastReadyDayKey
        isApplyingStoredSettings = false
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
#if os(iOS)
            return reminderEnabled
                ? String(format: NSLocalizedString("将于每天 %@ 提醒你查看每日脉冲；iPhone 会尽量在后台提前准备今天这一期，如果到了提醒时间后才完成，还会补发一条就绪通知。", comment: "Daily pulse iOS reminder enabled status"), reminderTimeText)
                : NSLocalizedString("提醒已关闭；你仍可在应用内手动查看今日卡片。", comment: "Daily pulse reminder disabled status")
#else
            return reminderEnabled
                ? String(format: NSLocalizedString("将于每天 %@ 提醒你查看每日脉冲；手表端仍会在前台恢复时自动尝试准备今天这一期。", comment: "Daily pulse watchOS reminder enabled status"), reminderTimeText)
                : NSLocalizedString("提醒已关闭；你仍可在应用内手动查看今日卡片。", comment: "Daily pulse reminder disabled status")
#endif
        case .denied:
#if os(iOS)
            return NSLocalizedString("系统通知权限当前未开启，提醒与就绪通知不会送达；但 iPhone 仍会尽量在后台提前准备今天这一期。", comment: "Daily pulse iOS notification denied status")
#else
            return NSLocalizedString("系统通知权限当前未开启，晨间提醒暂时不会送达。", comment: "Daily pulse watchOS notification denied status")
#endif
        case .notDetermined:
            return reminderEnabled
                ? NSLocalizedString("首次开启后会请求通知权限，用于晨间提醒与晨间送达尝试。", comment: "Daily pulse notification permission not determined enabled status")
                : NSLocalizedString("开启后会在设定时间提醒你查看今日脉冲。", comment: "Daily pulse notification permission not determined disabled status")
        @unknown default:
            return NSLocalizedString("通知权限状态暂时未知。", comment: "Daily pulse notification unknown status")
        }
#else
        return NSLocalizedString("当前平台暂不支持本地通知提醒。", comment: "Daily pulse local notification unsupported status")
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
        content.title = NSLocalizedString("每日脉冲晨间提醒", comment: "Daily pulse reminder notification title")
        content.body = NSLocalizedString("到了每日脉冲提醒时间。若今天这一期仍在准备中，请稍候片刻，完成后会再收到“已准备好”通知。", comment: "Daily pulse reminder notification body")
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
        content.title = NSLocalizedString("每日脉冲已准备好", comment: "Daily pulse ready notification title")
        let primaryCard = run.visibleCards.first ?? run.cards.first
        let primaryCardSuffix = primaryCard.map {
            String(format: NSLocalizedString("主卡「%@」。", comment: "Daily pulse ready notification primary card suffix"), $0.title)
        } ?? ""
        content.body = String(
            format: NSLocalizedString("今天的每日脉冲已经整理完成，已为你准备 %d 张主动情报卡片。%@", comment: "Daily pulse ready notification body"),
            run.visibleCards.count,
            primaryCardSuffix
        )
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
            Self.save(run.dayKey, forKey: Self.lastReadyDayKeyDefaultsKey, defaults: defaults)
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

    public nonisolated static func reminderTimeComponents(from input: String) -> (hour: Int, minute: Int)? {
        let trimmed = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]),
                  (0...23).contains(hour),
                  (0...59).contains(minute) else {
                return nil
            }
            return (hour, minute)
        }

        let digits = trimmed.filter(\.isNumber)
        let hour: Int
        let minute: Int

        switch digits.count {
        case 3:
            guard let parsedHour = Int(digits.prefix(1)),
                  let parsedMinute = Int(digits.suffix(2)) else {
                return nil
            }
            hour = parsedHour
            minute = parsedMinute
        case 4:
            guard let parsedHour = Int(digits.prefix(2)),
                  let parsedMinute = Int(digits.suffix(2)) else {
                return nil
            }
            hour = parsedHour
            minute = parsedMinute
        default:
            return nil
        }

        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
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

    public nonisolated static func nextBackgroundPreparationDate(
        referenceDate: Date,
        hour: Int,
        minute: Int,
        forceNextDay: Bool,
        leadTimeMinutes: Int = 15,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        let normalizedHour = normalizedHour(hour)
        let normalizedMinute = normalizedMinute(minute)

        guard let todayReminderDate = calendar.date(
            bySettingHour: normalizedHour,
            minute: normalizedMinute,
            second: 0,
            of: referenceDate
        ) else {
            return nil
        }

        let reminderDate: Date
        if forceNextDay {
            reminderDate = calendar.date(byAdding: .day, value: 1, to: todayReminderDate) ?? todayReminderDate
        } else if referenceDate <= todayReminderDate {
            reminderDate = todayReminderDate
        } else {
            return referenceDate.addingTimeInterval(60)
        }

        let preparationDate = calendar.date(
            byAdding: .minute,
            value: -max(0, leadTimeMinutes),
            to: reminderDate
        ) ?? reminderDate

        if reminderDate > referenceDate {
            let minimumFutureDate = referenceDate.addingTimeInterval(60)
            return preparationDate > minimumFutureDate ? preparationDate : minimumFutureDate
        }

        return preparationDate
    }

    internal nonisolated static func normalizedHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    internal nonisolated static func normalizedMinute(_ minute: Int) -> Int {
        min(max(minute, 0), 59)
    }

    private static func usesDatabase(defaults: UserDefaults) -> Bool {
        defaults === UserDefaults.standard
    }

    private static func boolValue(forKey key: String, defaults: UserDefaults, defaultValue: Bool) -> Bool {
        guard usesDatabase(defaults: defaults) else {
            return defaults.object(forKey: key) as? Bool ?? defaultValue
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigInteger(key: key) {
            return stored != 0
        }
        return defaultValue
    }

    private static func integerValue(forKey key: String, defaults: UserDefaults, defaultValue: Int) -> Int {
        guard usesDatabase(defaults: defaults) else {
            return defaults.object(forKey: key) as? Int ?? defaultValue
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigInteger(key: key) {
            return stored
        }
        return defaultValue
    }

    private static func textValue(forKey key: String, defaults: UserDefaults, defaultValue: String) -> String {
        guard usesDatabase(defaults: defaults) else {
            return defaults.string(forKey: key) ?? defaultValue
        }
        AppConfigLegacyUserDefaultsMigration.migrateStandardUserDefaults()
        if let stored = Persistence.readAppConfigText(key: key) {
            return stored
        }
        return defaultValue
    }

    private static func save(_ value: Bool, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        Persistence.writeAppConfig(key: key, integer: value ? 1 : 0, typeHint: "bool")
    }

    private static func save(_ value: Int, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        Persistence.writeAppConfig(key: key, integer: value, typeHint: "integer")
    }

    private static func save(_ value: String, forKey key: String, defaults: UserDefaults) {
        guard usesDatabase(defaults: defaults) else {
            defaults.set(value, forKey: key)
            return
        }
        Persistence.writeAppConfig(key: key, text: value, typeHint: "text")
    }
}

// ============================================================================
// DailyPulseDeliveryCoordinator.swift
// ============================================================================
// ETOS LLM Studio 每日脉冲主动送达协调器
//
// 功能特性:
// - 管理主动送达开关，以及每个时间点对应的卡片批次
// - 负责调度或移除绑定具体批次的一次性本地通知
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
    public nonisolated static let maximumDeliveryTimes = 6

    @Published public var reminderEnabled: Bool {
        didSet {
            Self.save(reminderEnabled, forKey: Self.reminderEnabledDefaultsKey, defaults: defaults)
            guard !isApplyingStoredSettings else { return }
            Task {
                await refreshReminderSchedule()
            }
        }
    }
    @Published public private(set) var deliveryTimes: [DailyPulseDeliveryTime] {
        didSet {
            let normalizedTimes = Self.normalizedDeliveryTimes(deliveryTimes)
            guard normalizedTimes == deliveryTimes else {
                deliveryTimes = normalizedTimes
                return
            }
            guard deliveryTimes != oldValue else { return }
            Self.saveDeliveryTimes(deliveryTimes, defaults: defaults)
            guard !isApplyingStoredSettings else { return }
            Task {
                await refreshReminderSchedule()
            }
        }
    }

    private let defaults: UserDefaults
    private var isApplyingStoredSettings = false

    private nonisolated static let legacyReminderIdentifier = "dailyPulse.reminder.daily"
    private nonisolated static let cardIdentifierPrefix = "dailyPulse.card."
    private nonisolated static let fallbackIdentifierPrefix = "dailyPulse.fallback."
    private nonisolated static let readyIdentifierPrefix = "dailyPulse.ready."
    private static let reminderEnabledDefaultsKey = "dailyPulse.delivery.reminderEnabled"
    private static let reminderHourDefaultsKey = "dailyPulse.delivery.reminderHour"
    private static let reminderMinuteDefaultsKey = "dailyPulse.delivery.reminderMinute"
    private static let deliveryTimesDefaultsKey = "dailyPulse.delivery.times"
    private static let lastReadyDayKeyDefaultsKey = "dailyPulse.delivery.lastReadyDayKey"

    @Published public private(set) var lastReadyDayKey: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reminderEnabled = Self.boolValue(forKey: Self.reminderEnabledDefaultsKey, defaults: defaults, defaultValue: false)
        let storedSchedule = Self.loadDeliveryTimes(defaults: defaults)
        let migratedTime = DailyPulseDeliveryTime(
            hour: Self.integerValue(forKey: Self.reminderHourDefaultsKey, defaults: defaults, defaultValue: 8),
            minute: Self.integerValue(forKey: Self.reminderMinuteDefaultsKey, defaults: defaults, defaultValue: 30)
        )
        // 上一版会按卡片数自动扩成多个时间；没有 cardCount 字段即可识别并收回为旧版单时间默认值。
        self.deliveryTimes = Self.normalizedDeliveryTimes(
            storedSchedule?.hasPerTimeCardCount == true
                ? storedSchedule?.times ?? [migratedTime]
                : [storedSchedule?.times.first ?? migratedTime]
        )
        let storedLastReadyDayKey = Self.textValue(forKey: Self.lastReadyDayKeyDefaultsKey, defaults: defaults, defaultValue: "")
        self.lastReadyDayKey = storedLastReadyDayKey.isEmpty ? nil : storedLastReadyDayKey
        if storedSchedule?.times != deliveryTimes || storedSchedule?.hasPerTimeCardCount != true {
            Self.saveDeliveryTimes(deliveryTimes, defaults: defaults)
        }
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
        let storedSchedule = Self.loadDeliveryTimes(defaults: defaults)
        let migratedTime = DailyPulseDeliveryTime(
            hour: Self.integerValue(forKey: Self.reminderHourDefaultsKey, defaults: defaults, defaultValue: 8),
            minute: Self.integerValue(forKey: Self.reminderMinuteDefaultsKey, defaults: defaults, defaultValue: 30)
        )
        deliveryTimes = Self.normalizedDeliveryTimes(
            storedSchedule?.hasPerTimeCardCount == true
                ? storedSchedule?.times ?? [migratedTime]
                : [storedSchedule?.times.first ?? migratedTime]
        )
        if storedSchedule?.hasPerTimeCardCount != true {
            Self.saveDeliveryTimes(deliveryTimes, defaults: defaults)
        }
        let storedLastReadyDayKey = Self.textValue(forKey: Self.lastReadyDayKeyDefaultsKey, defaults: defaults, defaultValue: "")
        lastReadyDayKey = storedLastReadyDayKey.isEmpty ? nil : storedLastReadyDayKey
        isApplyingStoredSettings = false
        Task {
            await refreshReminderSchedule()
        }
    }

    public var reminderTimeText: String {
        deliveryTimes.first?.timeText ?? "08:30"
    }

    public var deliveryTimeSummaryText: String {
        ListFormatter.localizedString(byJoining: deliveryTimes.map(\.timeText))
    }

    public var totalCardCount: Int {
        deliveryTimes.reduce(0) { $0 + $1.cardCount }
    }

    public var reminderStatusText: String {
#if canImport(UserNotifications)
        switch AppLocalNotificationCenter.shared.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
#if os(iOS)
            return reminderEnabled
                ? String(format: NSLocalizedString("将按 %@ 送达对应批次；每个时间点会提前单独生成，并结合该时刻与不同的近期对话。", comment: "Daily pulse iOS scheduled batch delivery status"), deliveryTimeSummaryText)
                : NSLocalizedString("提醒已关闭；你仍可在应用内手动查看今日卡片。", comment: "Daily pulse reminder disabled status")
#else
            return reminderEnabled
                ? String(format: NSLocalizedString("将按 %@ 送达对应批次；手表会使用已提前准备的内容，并在前台恢复时补充缺失批次。", comment: "Daily pulse watchOS scheduled batch delivery status"), deliveryTimeSummaryText)
                : NSLocalizedString("提醒已关闭；你仍可在应用内手动查看今日卡片。", comment: "Daily pulse reminder disabled status")
#endif
        case .denied:
            return NSLocalizedString("系统通知权限当前未开启，定时送达暂时不可用。", comment: "Daily pulse watchOS notification denied status")
        case .notDetermined:
            return reminderEnabled
                ? NSLocalizedString("首次开启后会请求通知权限，用于按设定时间送达卡片。", comment: "Daily pulse notification permission not determined enabled status")
                : NSLocalizedString("开启后会按设定时间提醒对应的每日脉冲卡片。", comment: "Daily pulse notification permission not determined disabled status")
        @unknown default:
            return NSLocalizedString("通知权限状态暂时未知。", comment: "Daily pulse notification unknown status")
        }
#else
        return NSLocalizedString("当前平台暂不支持本地通知提醒。", comment: "Daily pulse local notification unsupported status")
#endif
    }

    public func refreshReminderSchedule(referenceDate: Date = Date()) async {
#if canImport(UserNotifications)
        AppLocalNotificationCenter.shared.configureIfNeeded()
        let managedIdentifiers = Self.managedNotificationIdentifiers(referenceDate: referenceDate)
        if !reminderEnabled || !DailyPulseManager.shared.isDailyPulseEnabled {
            AppLocalNotificationCenter.shared.removePendingRequests(withIdentifiers: managedIdentifiers)
            AppLocalNotificationCenter.shared.removeDeliveredRequests(withIdentifiers: [Self.legacyReminderIdentifier])
            _ = await AppLocalNotificationCenter.shared.refreshAuthorizationStatus()
            return
        }

        let granted = await AppLocalNotificationCenter.shared.requestAuthorizationIfNeeded(options: [.alert, .sound, .badge])
        guard granted else { return }

        AppLocalNotificationCenter.shared.removePendingRequests(withIdentifiers: managedIdentifiers)

        let manager = DailyPulseManager.shared
        let todayKey = DailyPulseManager.dayKey(for: referenceDate)
        let tomorrowKey = DailyPulseManager.nextDayKey(from: referenceDate)
        if let todayRun = manager.runs.first(where: { $0.dayKey == todayKey }) {
            await scheduleCardNotifications(for: todayRun, referenceDate: referenceDate)
        } else {
            await scheduleFallbackNotification(dayKey: todayKey, referenceDate: referenceDate)
        }
        if let tomorrowRun = manager.runs.first(where: { $0.dayKey == tomorrowKey }) {
            await scheduleCardNotifications(for: tomorrowRun, referenceDate: referenceDate)
        } else {
            await scheduleFallbackNotification(dayKey: tomorrowKey, referenceDate: referenceDate)
        }
        _ = await AppLocalNotificationCenter.shared.refreshAuthorizationStatus()
#endif
    }

#if canImport(UserNotifications)
    private func scheduleCardNotifications(for run: DailyPulseRun, referenceDate: Date) async {
        for (index, batch) in effectiveDeliveryBatches(for: run).enumerated() {
            guard let deliveryTime = deliveryTimes.first(where: { $0.id == batch.deliveryTimeID }),
                  let deliveryDate = Self.deliveryDate(dayKey: run.dayKey, time: deliveryTime),
                  deliveryDate > referenceDate else {
                continue
            }

            let visibleCards = batch.cardIDs.compactMap { cardID in
                run.cards.first(where: { $0.id == cardID && $0.isVisible })
            }
            guard let primaryCard = visibleCards.first else { continue }

            let content = UNMutableNotificationContent()
            content.title = batch.headline
            content.body = Self.notificationBody(for: visibleCards)
            content.sound = .default
            content.threadIdentifier = "dailyPulse.delivery"
            content.categoryIdentifier = AppLocalNotificationCenter.dailyPulseCategoryIdentifier(kind: "card")
            content.userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(
                kind: "card",
                dayKey: run.dayKey,
                runID: run.id,
                cardID: primaryCard.id
            )

            let request = UNNotificationRequest(
                identifier: Self.cardNotificationIdentifier(dayKey: run.dayKey, index: index),
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: Self.notificationDateComponents(for: deliveryDate),
                    repeats: false
                )
            )
            _ = await AppLocalNotificationCenter.shared.addNotificationRequest(request)
        }
    }

    private func effectiveDeliveryBatches(for run: DailyPulseRun) -> [DailyPulseDeliveryBatch] {
        if let storedBatches = run.deliveryBatches, !storedBatches.isEmpty {
            return storedBatches
        }

        guard let firstTime = deliveryTimes.first else { return [] }
        return [
            DailyPulseDeliveryBatch(
                deliveryTimeID: firstTime.id,
                scheduledAt: Self.deliveryDate(dayKey: run.dayKey, time: firstTime) ?? run.generatedAt,
                headline: run.headline,
                cardIDs: run.cards.map(\.id)
            )
        ]
    }

    private nonisolated static func notificationBody(for cards: [DailyPulseCard]) -> String {
        guard cards.count > 1 else {
            return cards.first?.summary ?? NSLocalizedString("打开应用查看这次每日脉冲。", comment: "Daily Pulse notification empty batch body")
        }
        let titles = ListFormatter.localizedString(byJoining: cards.prefix(3).map(\.title))
        return String(
            format: NSLocalizedString("为你准备了 %d 张卡片：%@", comment: "Daily Pulse notification batch body"),
            cards.count,
            titles
        )
    }

    private func scheduleFallbackNotification(dayKey: String, referenceDate: Date) async {
        for (index, deliveryTime) in deliveryTimes.enumerated() {
            guard let deliveryDate = Self.deliveryDate(dayKey: dayKey, time: deliveryTime),
                  deliveryDate > referenceDate else { continue }

            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("每日脉冲提醒", comment: "Daily pulse fallback notification title")
            content.body = NSLocalizedString("这次每日脉冲尚未完成预先准备，打开应用后会继续尝试生成。", comment: "Daily pulse fallback notification body")
            content.sound = .default
            content.threadIdentifier = "dailyPulse.delivery"
            content.categoryIdentifier = AppLocalNotificationCenter.dailyPulseCategoryIdentifier(kind: "reminder")
            content.userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(kind: "reminder", dayKey: dayKey)

            let request = UNNotificationRequest(
                identifier: Self.fallbackNotificationIdentifier(dayKey: dayKey, index: index),
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: Self.notificationDateComponents(for: deliveryDate),
                    repeats: false
                )
            )
            _ = await AppLocalNotificationCenter.shared.addNotificationRequest(request)
        }
    }
#endif

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

    @discardableResult
    public func updateDeliveryTime(id: UUID, hour: Int, minute: Int) -> Bool {
        guard let index = deliveryTimes.firstIndex(where: { $0.id == id }) else { return false }
        let normalized = DailyPulseDeliveryTime(
            id: id,
            hour: hour,
            minute: minute,
            cardCount: deliveryTimes[index].cardCount
        )
        guard !deliveryTimes.contains(where: { $0.id != id && $0.totalMinutes == normalized.totalMinutes }) else {
            return false
        }
        deliveryTimes[index] = normalized
        invalidatePreparedTomorrowRun()
        return true
    }

    @discardableResult
    public func updateCardCount(id: UUID, count: Int) -> Bool {
        guard let index = deliveryTimes.firstIndex(where: { $0.id == id }) else { return false }
        let normalizedCount = DailyPulseDeliveryTime.normalizedCardCount(count)
        guard deliveryTimes[index].cardCount != normalizedCount else { return true }
        deliveryTimes[index].cardCount = normalizedCount
        invalidatePreparedTomorrowRun()
        return true
    }

    @discardableResult
    public func addDeliveryTime() -> DailyPulseDeliveryTime? {
        guard deliveryTimes.count < Self.maximumDeliveryTimes,
              let time = Self.nextAvailableDeliveryTime(after: deliveryTimes.last, excluding: deliveryTimes) else {
            return nil
        }
        deliveryTimes.append(time)
        invalidatePreparedTomorrowRun()
        return time
    }

    @discardableResult
    public func removeDeliveryTime(id: UUID) -> Bool {
        guard deliveryTimes.count > 1,
              deliveryTimes.contains(where: { $0.id == id }) else { return false }
        deliveryTimes.removeAll(where: { $0.id == id })
        invalidatePreparedTomorrowRun()
        return true
    }

    private func invalidatePreparedTomorrowRun() {
        guard Self.usesDatabase(defaults: defaults) else { return }
        DailyPulseManager.shared.invalidatePreparedTomorrowRun()
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

    internal nonisolated static func deliveryDate(
        dayKey: String,
        time: DailyPulseDeliveryTime,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: dayKey) else { return nil }
        return calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: day
        )
    }

    internal nonisolated static func hasFutureDeliveryTime(
        dayKey: String,
        deliveryTimes: [DailyPulseDeliveryTime],
        referenceDate: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        deliveryTimes.contains { time in
            guard let date = deliveryDate(dayKey: dayKey, time: time, calendar: calendar) else { return false }
            return date > referenceDate
        }
    }

    internal nonisolated static func notificationDateComponents(
        for date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> DateComponents {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.calendar = calendar
        return components
    }

    private nonisolated static func cardNotificationIdentifier(dayKey: String, index: Int) -> String {
        cardIdentifierPrefix + dayKey + ".\(index)"
    }

    private nonisolated static func fallbackNotificationIdentifier(dayKey: String, index: Int) -> String {
        fallbackIdentifierPrefix + dayKey + ".\(index)"
    }

    private nonisolated static func managedNotificationIdentifiers(referenceDate: Date) -> [String] {
        let dayKeys = [
            DailyPulseManager.dayKey(for: referenceDate),
            DailyPulseManager.nextDayKey(from: referenceDate)
        ]
        var identifiers = [legacyReminderIdentifier]
        for dayKey in dayKeys {
            identifiers.append(fallbackIdentifierPrefix + dayKey)
            identifiers.append(contentsOf: (0..<maximumDeliveryTimes).map {
                fallbackNotificationIdentifier(dayKey: dayKey, index: $0)
            })
            identifiers.append(contentsOf: (0..<maximumDeliveryTimes).map {
                cardNotificationIdentifier(dayKey: dayKey, index: $0)
            })
        }
        return identifiers
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

    internal nonisolated static func normalizedDeliveryTimes(
        _ times: [DailyPulseDeliveryTime]
    ) -> [DailyPulseDeliveryTime] {
        var seenMinutes = Set<Int>()
        let normalized = times
            .map {
                DailyPulseDeliveryTime(
                    id: $0.id,
                    hour: $0.hour,
                    minute: $0.minute,
                    cardCount: $0.cardCount
                )
            }
            .filter { seenMinutes.insert($0.totalMinutes).inserted }
            .sorted(by: { $0.totalMinutes < $1.totalMinutes })
        return normalized.isEmpty ? [DailyPulseDeliveryTime(hour: 8, minute: 30)] : Array(normalized.prefix(maximumDeliveryTimes))
    }

    private nonisolated static func nextAvailableDeliveryTime(
        after previous: DailyPulseDeliveryTime?,
        excluding existing: [DailyPulseDeliveryTime]
    ) -> DailyPulseDeliveryTime? {
        let usedMinutes = Set(existing.map(\.totalMinutes))
        let startMinutes = previous?.totalMinutes ?? (8 * 60 + 30)
        let preferredCandidates = [240, 180, 120, 60, 30]
            .map { startMinutes + $0 }
            .filter { $0 < 24 * 60 }
        let fallbackCandidates = Array(stride(from: 0, to: 24 * 60, by: 30))
        for candidate in preferredCandidates + fallbackCandidates {
            guard !usedMinutes.contains(candidate) else { continue }
            return DailyPulseDeliveryTime(
                hour: candidate / 60,
                minute: candidate % 60,
                cardCount: DailyPulseDeliveryTime.defaultCardCount
            )
        }
        return nil
    }

    private struct StoredDeliverySchedule {
        let times: [DailyPulseDeliveryTime]
        let hasPerTimeCardCount: Bool
    }

    private struct StoredDeliveryTimeProbe: Decodable {
        let cardCount: Int?
    }

    private static func loadDeliveryTimes(defaults: UserDefaults) -> StoredDeliverySchedule? {
        let rawValue = textValue(forKey: deliveryTimesDefaultsKey, defaults: defaults, defaultValue: "")
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([DailyPulseDeliveryTime].self, from: data) else {
            return nil
        }
        let probes = try? JSONDecoder().decode([StoredDeliveryTimeProbe].self, from: data)
        return StoredDeliverySchedule(
            times: normalizedDeliveryTimes(decoded),
            hasPerTimeCardCount: probes?.allSatisfy { $0.cardCount != nil } == true
        )
    }

    private static func saveDeliveryTimes(_ times: [DailyPulseDeliveryTime], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalizedDeliveryTimes(times)),
              let rawValue = String(data: data, encoding: .utf8) else {
            return
        }
        save(rawValue, forKey: deliveryTimesDefaultsKey, defaults: defaults)
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

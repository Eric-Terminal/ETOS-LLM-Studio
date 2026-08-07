// ============================================================================
// DailyPulseDeliveryCoordinator.swift
// ============================================================================
// ETOS LLM Studio 每日脉冲主动送达协调器
//
// 功能特性:
// - 管理主动送达开关，以及每张卡片各自的送达时间
// - 负责为每张卡片调度或移除一次性本地通知
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
    private nonisolated static let defaultCardCount = 3
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
        self.deliveryTimes = Self.migratedCardDeliveryTimes(
            from: storedSchedule,
            fallback: migratedTime
        )
        let storedLastReadyDayKey = Self.textValue(forKey: Self.lastReadyDayKeyDefaultsKey, defaults: defaults, defaultValue: "")
        self.lastReadyDayKey = storedLastReadyDayKey.isEmpty ? nil : storedLastReadyDayKey
        if storedSchedule?.times != deliveryTimes || storedSchedule?.hasLegacyCardCounts == true {
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
        deliveryTimes = Self.migratedCardDeliveryTimes(
            from: storedSchedule,
            fallback: migratedTime
        )
        if storedSchedule?.times != deliveryTimes || storedSchedule?.hasLegacyCardCounts == true {
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

    public var totalCardCount: Int {
        deliveryTimes.count
    }

    public var reminderStatusText: String {
#if canImport(UserNotifications)
        switch AppLocalNotificationCenter.shared.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
#if os(iOS)
            return reminderEnabled
                ? NSLocalizedString("每张卡片会按各自设定的时间单独通知；多张卡片可以使用同一时间，并分别直接显示内容。", comment: "Daily Pulse iOS per-card delivery status")
                : NSLocalizedString("提醒已关闭；你仍可在应用内手动查看今日卡片。", comment: "Daily pulse reminder disabled status")
#else
            return reminderEnabled
                ? NSLocalizedString("每张卡片会按各自设定的时间单独通知；相同时间的卡片也会分别显示内容。", comment: "Daily Pulse watchOS per-card delivery status")
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
        let notificationCenter = AppLocalNotificationCenter.shared
        await notificationCenter.removePendingRequests(
            withIdentifierPrefixes: [Self.cardIdentifierPrefix, Self.fallbackIdentifierPrefix]
        )
        notificationCenter.removePendingRequests(withIdentifiers: [Self.legacyReminderIdentifier])
        if !reminderEnabled || !DailyPulseManager.shared.isDailyPulseEnabled {
            notificationCenter.removeDeliveredRequests(withIdentifiers: [Self.legacyReminderIdentifier])
            _ = await notificationCenter.refreshAuthorizationStatus()
            return
        }

        let granted = await notificationCenter.requestAuthorizationIfNeeded(options: [.alert, .sound, .badge])
        guard granted else { return }

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
        _ = await notificationCenter.refreshAuthorizationStatus()
#endif
    }

#if canImport(UserNotifications)
    private func scheduleCardNotifications(for run: DailyPulseRun, referenceDate: Date) async {
        for batch in Self.effectiveDeliveryBatches(
            for: run,
            deliveryTimes: deliveryTimes
        ) {
            guard let deliveryTime = deliveryTimes.first(where: { $0.id == batch.deliveryTimeID }),
                  let deliveryDate = Self.deliveryDate(dayKey: run.dayKey, time: deliveryTime),
                  deliveryDate > referenceDate else {
                continue
            }

            let visibleCards = batch.cardIDs.compactMap { cardID in
                run.cards.first(where: { $0.id == cardID && $0.isVisible })
            }
            for card in visibleCards {
                let notificationText = Self.cardNotificationText(for: card)
                let content = UNMutableNotificationContent()
                content.title = notificationText.title
                content.body = notificationText.body
                content.sound = .default
                content.threadIdentifier = "dailyPulse.delivery"
                content.categoryIdentifier = AppLocalNotificationCenter.dailyPulseCategoryIdentifier(kind: "card")
                content.userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(
                    kind: "card",
                    dayKey: run.dayKey,
                    runID: run.id,
                    cardID: card.id
                )

                let request = UNNotificationRequest(
                    identifier: Self.cardNotificationIdentifier(dayKey: run.dayKey, cardID: card.id),
                    content: content,
                    trigger: UNCalendarNotificationTrigger(
                        dateMatching: Self.notificationDateComponents(for: deliveryDate),
                        repeats: false
                    )
                )
                _ = await AppLocalNotificationCenter.shared.addNotificationRequest(request)
            }
        }
    }

    private func scheduleFallbackNotification(dayKey: String, referenceDate: Date) async {
        var scheduledMinutes = Set<Int>()
        for deliveryTime in deliveryTimes where scheduledMinutes.insert(deliveryTime.totalMinutes).inserted {
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
                identifier: Self.fallbackNotificationIdentifier(
                    dayKey: dayKey,
                    totalMinutes: deliveryTime.totalMinutes
                ),
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

    /// 把旧版无批次记录或送达时间标识已变化的记录映射到当前配置，避免升级后静默丢失通知。
    internal nonisolated static func effectiveDeliveryBatches(
        for run: DailyPulseRun,
        deliveryTimes: [DailyPulseDeliveryTime]
    ) -> [DailyPulseDeliveryBatch] {
        guard !deliveryTimes.isEmpty else { return [] }

        if let storedBatches = run.deliveryBatches, !storedBatches.isEmpty {
            var batchesByTimeID: [UUID: DailyPulseDeliveryBatch] = [:]

            for (index, batch) in storedBatches.enumerated() {
                let deliveryTime = deliveryTimes.first(where: { $0.id == batch.deliveryTimeID })
                    ?? deliveryTimes[min(index, deliveryTimes.count - 1)]
                let scheduledAt = deliveryDate(dayKey: run.dayKey, time: deliveryTime) ?? batch.scheduledAt

                if var existing = batchesByTimeID[deliveryTime.id] {
                    for cardID in batch.cardIDs where !existing.cardIDs.contains(cardID) {
                        existing.cardIDs.append(cardID)
                    }
                    batchesByTimeID[deliveryTime.id] = existing
                } else {
                    var resolvedBatch = batch
                    resolvedBatch.deliveryTimeID = deliveryTime.id
                    resolvedBatch.scheduledAt = scheduledAt
                    batchesByTimeID[deliveryTime.id] = resolvedBatch
                }
            }

            return deliveryTimes.compactMap { batchesByTimeID[$0.id] }
        }

        let cardIDs = run.cards.map(\.id)
        var batchesByTimeID: [UUID: DailyPulseDeliveryBatch] = [:]

        for (index, cardID) in cardIDs.enumerated() {
            let deliveryTime = deliveryTimes[min(index, deliveryTimes.count - 1)]
            if var existing = batchesByTimeID[deliveryTime.id] {
                existing.cardIDs.append(cardID)
                batchesByTimeID[deliveryTime.id] = existing
            } else {
                batchesByTimeID[deliveryTime.id] = DailyPulseDeliveryBatch(
                    deliveryTimeID: deliveryTime.id,
                    scheduledAt: deliveryDate(dayKey: run.dayKey, time: deliveryTime) ?? run.generatedAt,
                    headline: run.headline,
                    cardIDs: [cardID]
                )
            }
        }

        return deliveryTimes.compactMap { batchesByTimeID[$0.id] }
    }

    internal nonisolated static func deliveryConfigurationRequiresRecovery(
        for run: DailyPulseRun,
        deliveryTimes: [DailyPulseDeliveryTime]
    ) -> Bool {
        guard let storedBatches = run.deliveryBatches, !storedBatches.isEmpty else {
            return true
        }
        let currentTimeIDs = Set(deliveryTimes.map(\.id))
        return storedBatches.contains { !currentTimeIDs.contains($0.deliveryTimeID) }
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

        var didScheduleCard = false
        for card in run.visibleCards {
            let notificationText = Self.cardNotificationText(for: card)
            let content = UNMutableNotificationContent()
            content.title = notificationText.title
            content.body = notificationText.body
            content.sound = .default
            content.threadIdentifier = "dailyPulse.delivery"
            content.categoryIdentifier = AppLocalNotificationCenter.dailyPulseCategoryIdentifier(kind: "card")
            content.userInfo = AppLocalNotificationCenter.dailyPulseUserInfo(
                kind: "card",
                dayKey: run.dayKey,
                runID: run.id,
                cardID: card.id
            )

            let request = UNNotificationRequest(
                identifier: Self.cardNotificationIdentifier(dayKey: run.dayKey, cardID: card.id),
                content: content,
                trigger: nil
            )
            if await AppLocalNotificationCenter.shared.addNotificationRequest(request) {
                didScheduleCard = true
            }
        }
        if didScheduleCard {
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

    internal nonisolated static func cardNotificationText(
        for card: DailyPulseCard
    ) -> (title: String, body: String) {
        (card.title, card.summary)
    }

    @discardableResult
    public func updateDeliveryTime(id: UUID, hour: Int, minute: Int) -> Bool {
        guard let index = deliveryTimes.firstIndex(where: { $0.id == id }) else { return false }
        let normalized = DailyPulseDeliveryTime(
            id: id,
            hour: hour,
            minute: minute
        )
        deliveryTimes[index] = normalized
        invalidatePreparedTomorrowRun()
        return true
    }

    public func setCardCount(_ count: Int) {
        let targetCount = max(1, count)
        guard targetCount != deliveryTimes.count else { return }

        var updatedTimes = deliveryTimes
        if targetCount > updatedTimes.count {
            let previousTime = updatedTimes.last ?? DailyPulseDeliveryTime(hour: 8, minute: 30)
            updatedTimes.append(contentsOf: (updatedTimes.count..<targetCount).map { _ in
                DailyPulseDeliveryTime(hour: previousTime.hour, minute: previousTime.minute)
            })
        } else {
            updatedTimes.removeLast(updatedTimes.count - targetCount)
        }
        deliveryTimes = updatedTimes
        invalidatePreparedTomorrowRun()
    }

    @discardableResult
    public func removeCard(id: UUID) -> Bool {
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

    private nonisolated static func cardNotificationIdentifier(dayKey: String, cardID: UUID) -> String {
        cardIdentifierPrefix + dayKey + "." + cardID.uuidString
    }

    private nonisolated static func fallbackNotificationIdentifier(dayKey: String, totalMinutes: Int) -> String {
        fallbackIdentifierPrefix + dayKey + ".\(totalMinutes)"
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
        var seenIDs = Set<UUID>()
        let normalized = times.compactMap { time -> DailyPulseDeliveryTime? in
            guard seenIDs.insert(time.id).inserted else { return nil }
            return DailyPulseDeliveryTime(
                id: time.id,
                hour: time.hour,
                minute: time.minute
            )
        }
        return normalized.isEmpty ? [DailyPulseDeliveryTime(hour: 8, minute: 30)] : normalized
    }

    internal nonisolated static func groupedCardDeliveryTimes(
        _ times: [DailyPulseDeliveryTime]
    ) -> [[DailyPulseDeliveryTime]] {
        // 相同时间的卡片共享一次模型请求，但仍保留各自标识用于独立通知。
        let normalized = normalizedDeliveryTimes(times)
        return Dictionary(grouping: normalized, by: \.totalMinutes)
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    private nonisolated static func migratedCardDeliveryTimes(
        from storedSchedule: StoredDeliverySchedule?,
        fallback: DailyPulseDeliveryTime
    ) -> [DailyPulseDeliveryTime] {
        guard let storedSchedule else {
            return (0..<defaultCardCount).map { _ in
                DailyPulseDeliveryTime(hour: fallback.hour, minute: fallback.minute)
            }
        }
        guard let legacyCardCounts = storedSchedule.legacyCardCounts else {
            return normalizedDeliveryTimes(storedSchedule.times)
        }

        // 上一版把数量保存在时间批次上；展开后首张卡保留原标识，以继续匹配已生成记录。
        let expandedTimes = zip(storedSchedule.times, legacyCardCounts).flatMap { pair in
            (0..<max(1, pair.1)).map { index in
                DailyPulseDeliveryTime(
                    id: index == 0 ? pair.0.id : UUID(),
                    hour: pair.0.hour,
                    minute: pair.0.minute
                )
            }
        }
        return normalizedDeliveryTimes(expandedTimes)
    }

    private struct StoredDeliverySchedule {
        let times: [DailyPulseDeliveryTime]
        let legacyCardCounts: [Int]?

        var hasLegacyCardCounts: Bool {
            legacyCardCounts != nil
        }
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
        let legacyCardCounts: [Int]?
        if let probes,
           probes.count == decoded.count,
           probes.allSatisfy({ $0.cardCount != nil }) {
            legacyCardCounts = probes.map { max(1, $0.cardCount ?? 1) }
        } else {
            legacyCardCounts = nil
        }
        return StoredDeliverySchedule(
            times: decoded,
            legacyCardCounts: legacyCardCounts
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

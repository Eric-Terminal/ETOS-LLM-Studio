// ============================================================================
// ChatAppearanceProfiles.swift
// ============================================================================
// 聊天颜色配置与按时间自动切换
// - 将用户/助手气泡与文字颜色归入可同步的 Profile
// - 通过每日时间段选择当前生效 Profile
// ============================================================================

import Combine
import Foundation

public struct ChatAppearanceColorSlot: Codable, Equatable, Hashable, Sendable {
    public var isEnabled: Bool
    public var hex: String

    public init(isEnabled: Bool = false, hex: String) {
        self.isEnabled = isEnabled
        self.hex = hex
    }
}

public struct ChatAppearanceProfile: Codable, Identifiable, Equatable, Hashable, Sendable {
    public static let defaultProfileID = "default"

    public var id: String
    public var name: String
    public var userBubble: ChatAppearanceColorSlot
    public var assistantBubble: ChatAppearanceColorSlot
    public var lightText: ChatAppearanceColorSlot
    public var darkText: ChatAppearanceColorSlot

    public init(
        id: String = UUID().uuidString,
        name: String,
        userBubble: ChatAppearanceColorSlot = .defaultUserBubble,
        assistantBubble: ChatAppearanceColorSlot = .defaultAssistantBubble,
        lightText: ChatAppearanceColorSlot = .defaultLightText,
        darkText: ChatAppearanceColorSlot = .defaultDarkText
    ) {
        self.id = id
        self.name = name
        self.userBubble = userBubble
        self.assistantBubble = assistantBubble
        self.lightText = lightText
        self.darkText = darkText
    }

    public var isDefaultProfile: Bool {
        id == Self.defaultProfileID
    }

    public func copied(name: String? = nil) -> ChatAppearanceProfile {
        ChatAppearanceProfile(
            name: name ?? Self.nextDefaultName(after: self.name),
            userBubble: userBubble,
            assistantBubble: assistantBubble,
            lightText: lightText,
            darkText: darkText
        )
    }

    static func nextDefaultName(after name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == Self.defaultProfileID ? "Profile" : "\(trimmed) Copy"
    }
}

public extension ChatAppearanceColorSlot {
    static let defaultUserBubble = ChatAppearanceColorSlot(isEnabled: false, hex: "3D8FF2FF")
    static let defaultAssistantBubble = ChatAppearanceColorSlot(isEnabled: false, hex: "F2F2F7FF")
    static let defaultLightText = ChatAppearanceColorSlot(isEnabled: false, hex: "1C1C1EFF")
    static let defaultDarkText = ChatAppearanceColorSlot(isEnabled: false, hex: "FFFFFFFF")
}

public struct ChatAppearanceScheduleRule: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var profileID: String
    public var startMinuteOfDay: Int
    public var endMinuteOfDay: Int

    public init(
        id: String = UUID().uuidString,
        profileID: String,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) {
        self.id = id
        self.profileID = profileID
        self.startMinuteOfDay = Self.normalizedMinute(startMinuteOfDay)
        self.endMinuteOfDay = Self.normalizedMinute(endMinuteOfDay)
    }

    public var isCrossMidnight: Bool {
        startMinuteOfDay > endMinuteOfDay
    }

    public var isValidTimeWindow: Bool {
        startMinuteOfDay != endMinuteOfDay
    }

    public func contains(minuteOfDay minute: Int) -> Bool {
        let normalizedMinute = Self.normalizedMinute(minute)
        if startMinuteOfDay < endMinuteOfDay {
            return normalizedMinute >= startMinuteOfDay && normalizedMinute < endMinuteOfDay
        }
        if startMinuteOfDay > endMinuteOfDay {
            return normalizedMinute >= startMinuteOfDay || normalizedMinute < endMinuteOfDay
        }
        return false
    }

    public static func normalizedMinute(_ minute: Int) -> Int {
        let dayMinutes = 24 * 60
        return ((minute % dayMinutes) + dayMinutes) % dayMinutes
    }

    public static func displayTime(minuteOfDay minute: Int) -> String {
        let normalizedMinute = normalizedMinute(minute)
        return String(format: "%02d:%02d", normalizedMinute / 60, normalizedMinute % 60)
    }

    public var displayTimeRange: String {
        "\(Self.displayTime(minuteOfDay: startMinuteOfDay)) - \(Self.displayTime(minuteOfDay: endMinuteOfDay))"
    }
}

public struct ChatAppearanceProfileConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var profiles: [ChatAppearanceProfile]
    public var scheduleRules: [ChatAppearanceScheduleRule]

    public init(
        schemaVersion: Int = 1,
        profiles: [ChatAppearanceProfile] = [.defaultProfile],
        scheduleRules: [ChatAppearanceScheduleRule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.scheduleRules = scheduleRules
    }

    public var defaultProfile: ChatAppearanceProfile {
        profile(id: ChatAppearanceProfile.defaultProfileID) ?? .defaultProfile
    }

    public func profile(id: String) -> ChatAppearanceProfile? {
        profiles.first { $0.id == id }
    }

    public func activeRule(at date: Date, calendar: Calendar = .current) -> ChatAppearanceScheduleRule? {
        let minute = Self.minuteOfDay(for: date, calendar: calendar)
        return scheduleRules.first { rule in
            profile(id: rule.profileID) != nil && rule.contains(minuteOfDay: minute)
        }
    }

    public func activeProfile(at date: Date, calendar: Calendar = .current) -> ChatAppearanceProfile {
        if let rule = activeRule(at: date, calendar: calendar),
           let profile = profile(id: rule.profileID) {
            return profile
        }
        return defaultProfile
    }

    public func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        guard !scheduleRules.isEmpty else { return nil }
        let currentMinute = Self.minuteOfDay(for: date, calendar: calendar)
        let currentDay = calendar.startOfDay(for: date)
        let boundaries = scheduleRules.flatMap { [$0.startMinuteOfDay, $0.endMinuteOfDay] }
        let futureMinute = boundaries
            .filter { $0 > currentMinute }
            .min()
        let minute = futureMinute ?? boundaries.min()
        guard let minute else { return nil }
        let dayOffset = futureMinute == nil ? 1 : 0
        return calendar.date(byAdding: .day, value: dayOffset, to: currentDay)?
            .addingTimeInterval(TimeInterval(minute * 60))
    }

    public func firstAvailableScheduleWindow(
        preferredStartMinute: Int = 9 * 60,
        durationMinutes: Int = 60
    ) -> (startMinuteOfDay: Int, endMinuteOfDay: Int)? {
        let duration = max(1, min(24 * 60 - 1, durationMinutes))
        let preferredStart = ChatAppearanceScheduleRule.normalizedMinute(preferredStartMinute)
        for offset in 0..<(24 * 60) {
            let start = ChatAppearanceScheduleRule.normalizedMinute(preferredStart + offset)
            let end = ChatAppearanceScheduleRule.normalizedMinute(start + duration)
            var candidateConfiguration = self
            candidateConfiguration.scheduleRules.append(
                ChatAppearanceScheduleRule(
                    profileID: ChatAppearanceProfile.defaultProfileID,
                    startMinuteOfDay: start,
                    endMinuteOfDay: end
                )
            )
            if (try? candidateConfiguration.validateScheduleRules()) != nil {
                return (start, end)
            }
        }
        return nil
    }

    public func normalized() -> ChatAppearanceProfileConfiguration {
        var seenProfileIDs = Set<String>()
        var normalizedProfiles: [ChatAppearanceProfile] = []

        for var profile in profiles {
            guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard seenProfileIDs.insert(profile.id).inserted else { continue }
            if profile.id == ChatAppearanceProfile.defaultProfileID {
                profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ChatAppearanceProfile.defaultProfileID
                    : profile.name
                normalizedProfiles.insert(profile, at: 0)
            } else {
                profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Profile"
                    : profile.name
                normalizedProfiles.append(profile)
            }
        }

        if !seenProfileIDs.contains(ChatAppearanceProfile.defaultProfileID) {
            normalizedProfiles.insert(.defaultProfile, at: 0)
            seenProfileIDs.insert(ChatAppearanceProfile.defaultProfileID)
        }

        var seenRuleIDs = Set<String>()
        let profileIDs = Set(normalizedProfiles.map(\.id))
        let normalizedRules = scheduleRules.compactMap { rule -> ChatAppearanceScheduleRule? in
            guard profileIDs.contains(rule.profileID), rule.isValidTimeWindow else { return nil }
            let id = rule.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? UUID().uuidString
                : rule.id
            guard seenRuleIDs.insert(id).inserted else { return nil }
            return ChatAppearanceScheduleRule(
                id: id,
                profileID: rule.profileID,
                startMinuteOfDay: rule.startMinuteOfDay,
                endMinuteOfDay: rule.endMinuteOfDay
            )
        }

        return ChatAppearanceProfileConfiguration(
            schemaVersion: max(1, schemaVersion),
            profiles: normalizedProfiles,
            scheduleRules: normalizedRules
        )
    }

    public func validateScheduleRules() throws {
        for rule in scheduleRules where !rule.isValidTimeWindow {
            throw ChatAppearanceProfileError.invalidScheduleWindow
        }

        let segments = scheduleRules.flatMap { rule -> [ScheduleSegment] in
            guard rule.isValidTimeWindow else { return [] }
            if rule.startMinuteOfDay < rule.endMinuteOfDay {
                return [ScheduleSegment(ruleID: rule.id, start: rule.startMinuteOfDay, end: rule.endMinuteOfDay)]
            }
            return [
                ScheduleSegment(ruleID: rule.id, start: rule.startMinuteOfDay, end: 24 * 60),
                ScheduleSegment(ruleID: rule.id, start: 0, end: rule.endMinuteOfDay)
            ]
        }

        for lhsIndex in segments.indices {
            for rhsIndex in segments.indices where rhsIndex > lhsIndex {
                let lhs = segments[lhsIndex]
                let rhs = segments[rhsIndex]
                guard lhs.ruleID != rhs.ruleID else { continue }
                if max(lhs.start, rhs.start) < min(lhs.end, rhs.end) {
                    throw ChatAppearanceProfileError.overlappingScheduleRules
                }
            }
        }
    }

    public static func minuteOfDay(for date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private struct ScheduleSegment {
        var ruleID: String
        var start: Int
        var end: Int
    }
}

public extension ChatAppearanceProfile {
    static let defaultProfile = ChatAppearanceProfile(id: defaultProfileID, name: defaultProfileID)
}

public enum ChatAppearanceProfileError: LocalizedError, Equatable {
    case profileNotFound
    case defaultProfileCannotBeDeleted
    case invalidScheduleWindow
    case overlappingScheduleRules
    case noAvailableScheduleWindow
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return NSLocalizedString("未找到颜色配置。", comment: "")
        case .defaultProfileCannotBeDeleted:
            return NSLocalizedString("默认配置不能删除。", comment: "")
        case .invalidScheduleWindow:
            return NSLocalizedString("开始与结束时间不能相同。", comment: "")
        case .overlappingScheduleRules:
            return NSLocalizedString("时间段不能重叠，请调整开始或结束时间。", comment: "")
        case .noAvailableScheduleWindow:
            return NSLocalizedString("没有可用的空闲时间段。", comment: "")
        case .saveFailed:
            return NSLocalizedString("保存颜色配置失败。", comment: "")
        }
    }
}

public enum ChatAppearanceProfileStore {
    public static let configurationStorageKey = "chatAppearance.profileConfiguration.v1"

    private static let legacyEnableUserBubbleKey = "enableCustomUserBubbleColor"
    private static let legacyUserBubbleHexKey = "customUserBubbleColorHex"
    private static let legacyEnableAssistantBubbleKey = "enableCustomAssistantBubbleColor"
    private static let legacyAssistantBubbleHexKey = "customAssistantBubbleColorHex"
    private static let legacyEnableLightTextKey = "enableCustomLightTextColor"
    private static let legacyLightTextHexKey = "customLightTextColorHex"
    private static let legacyEnableDarkTextKey = "enableCustomDarkTextColor"
    private static let legacyDarkTextHexKey = "customDarkTextColorHex"

    public static func loadConfiguration(userDefaults: UserDefaults = .standard) -> ChatAppearanceProfileConfiguration {
        if let decoded = loadStoredConfiguration(userDefaults: userDefaults) {
            let normalized = decoded.normalized()
            if (try? normalized.validateScheduleRules()) == nil {
                var safeConfiguration = normalized
                safeConfiguration.scheduleRules = []
                _ = try? saveConfiguration(safeConfiguration, userDefaults: userDefaults)
                return safeConfiguration
            }
            if normalized != decoded {
                _ = try? saveConfiguration(normalized, userDefaults: userDefaults)
            }
            return normalized
        }

        let migrated = migratedLegacyConfiguration(userDefaults: userDefaults)
        _ = try? saveConfiguration(migrated, userDefaults: userDefaults)
        return migrated
    }

    @discardableResult
    public static func saveConfiguration(
        _ configuration: ChatAppearanceProfileConfiguration,
        userDefaults: UserDefaults = .standard
    ) throws -> ChatAppearanceProfileConfiguration {
        let normalized = configuration.normalized()
        try normalized.validateScheduleRules()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(normalized) else {
            throw ChatAppearanceProfileError.saveFailed
        }

        if usesDatabase(userDefaults: userDefaults) {
            guard let encoded = String(data: data, encoding: .utf8),
                  Persistence.writeAppConfig(key: configurationStorageKey, text: encoded, typeHint: "text") else {
                throw ChatAppearanceProfileError.saveFailed
            }
            userDefaults.removeObject(forKey: configurationStorageKey)
            clearLegacyColorKeys(in: userDefaults)
        } else {
            userDefaults.set(data, forKey: configurationStorageKey)
            mirrorDefaultProfile(normalized.defaultProfile, to: userDefaults)
        }
        return normalized
    }

    public static func migratedLegacyConfiguration(userDefaults: UserDefaults = .standard) -> ChatAppearanceProfileConfiguration {
        let defaultProfile = ChatAppearanceProfile(
            id: ChatAppearanceProfile.defaultProfileID,
            name: ChatAppearanceProfile.defaultProfileID,
            userBubble: ChatAppearanceColorSlot(
                isEnabled: userDefaults.bool(forKey: legacyEnableUserBubbleKey),
                hex: userDefaults.string(forKey: legacyUserBubbleHexKey) ?? ChatAppearanceColorSlot.defaultUserBubble.hex
            ),
            assistantBubble: ChatAppearanceColorSlot(
                isEnabled: userDefaults.bool(forKey: legacyEnableAssistantBubbleKey),
                hex: userDefaults.string(forKey: legacyAssistantBubbleHexKey) ?? ChatAppearanceColorSlot.defaultAssistantBubble.hex
            ),
            lightText: ChatAppearanceColorSlot(
                isEnabled: userDefaults.bool(forKey: legacyEnableLightTextKey),
                hex: userDefaults.string(forKey: legacyLightTextHexKey) ?? ChatAppearanceColorSlot.defaultLightText.hex
            ),
            darkText: ChatAppearanceColorSlot(
                isEnabled: userDefaults.bool(forKey: legacyEnableDarkTextKey),
                hex: userDefaults.string(forKey: legacyDarkTextHexKey) ?? ChatAppearanceColorSlot.defaultDarkText.hex
            )
        )
        return ChatAppearanceProfileConfiguration(profiles: [defaultProfile], scheduleRules: [])
    }

    private static func usesDatabase(userDefaults: UserDefaults) -> Bool {
        userDefaults === UserDefaults.standard
    }

    private static func loadStoredConfiguration(userDefaults: UserDefaults) -> ChatAppearanceProfileConfiguration? {
        if usesDatabase(userDefaults: userDefaults),
           let raw = Persistence.readAppConfigText(key: configurationStorageKey),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ChatAppearanceProfileConfiguration.self, from: data) {
            return decoded
        }

        guard let data = userDefaults.data(forKey: configurationStorageKey),
              let decoded = try? JSONDecoder().decode(ChatAppearanceProfileConfiguration.self, from: data) else {
            return nil
        }
        if usesDatabase(userDefaults: userDefaults),
           Persistence.readAppConfigText(key: configurationStorageKey) == nil {
            _ = try? saveConfiguration(decoded.normalized(), userDefaults: userDefaults)
        }
        return decoded
    }

    private static func mirrorDefaultProfile(_ profile: ChatAppearanceProfile, to userDefaults: UserDefaults) {
        userDefaults.set(profile.userBubble.isEnabled, forKey: legacyEnableUserBubbleKey)
        userDefaults.set(profile.userBubble.hex, forKey: legacyUserBubbleHexKey)
        userDefaults.set(profile.assistantBubble.isEnabled, forKey: legacyEnableAssistantBubbleKey)
        userDefaults.set(profile.assistantBubble.hex, forKey: legacyAssistantBubbleHexKey)
        userDefaults.set(profile.lightText.isEnabled, forKey: legacyEnableLightTextKey)
        userDefaults.set(profile.lightText.hex, forKey: legacyLightTextHexKey)
        userDefaults.set(profile.darkText.isEnabled, forKey: legacyEnableDarkTextKey)
        userDefaults.set(profile.darkText.hex, forKey: legacyDarkTextHexKey)
    }

    private static func clearLegacyColorKeys(in userDefaults: UserDefaults) {
        [
            legacyEnableUserBubbleKey,
            legacyUserBubbleHexKey,
            legacyEnableAssistantBubbleKey,
            legacyAssistantBubbleHexKey,
            legacyEnableLightTextKey,
            legacyLightTextHexKey,
            legacyEnableDarkTextKey,
            legacyDarkTextHexKey
        ].forEach { userDefaults.removeObject(forKey: $0) }
    }
}

@MainActor
public final class ChatAppearanceProfileManager: ObservableObject {
    public static let shared = ChatAppearanceProfileManager()

    @Published public private(set) var configuration: ChatAppearanceProfileConfiguration
    @Published public private(set) var activeProfile: ChatAppearanceProfile
    @Published public private(set) var activeRuleID: String?

    private let userDefaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date
    private let automaticallySchedulesRefresh: Bool
    private var refreshTask: Task<Void, Never>?

    public init(
        userDefaults: UserDefaults = .standard,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        automaticallySchedulesRefresh: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.calendar = calendar
        self.now = now
        self.automaticallySchedulesRefresh = automaticallySchedulesRefresh
        let loadedConfiguration = ChatAppearanceProfileStore.loadConfiguration(userDefaults: userDefaults)
        configuration = loadedConfiguration
        activeProfile = loadedConfiguration.activeProfile(at: now(), calendar: calendar)
        activeRuleID = loadedConfiguration.activeRule(at: now(), calendar: calendar)?.id
    }

    deinit {
        refreshTask?.cancel()
    }

    public func activate() {
        reloadFromStorage()
    }

    public func handleAppBecameActive() {
        reloadFromStorage()
    }

    public func reloadFromStorage() {
        let loaded = ChatAppearanceProfileStore.loadConfiguration(userDefaults: userDefaults)
        apply(configuration: loaded)
    }

    @discardableResult
    public func saveConfiguration(_ configuration: ChatAppearanceProfileConfiguration) throws -> ChatAppearanceProfileConfiguration {
        let saved = try ChatAppearanceProfileStore.saveConfiguration(configuration, userDefaults: userDefaults)
        apply(configuration: saved)
        return saved
    }

    public func addProfile(copying sourceProfileID: String = ChatAppearanceProfile.defaultProfileID, name: String? = nil) throws -> ChatAppearanceProfile {
        let source = configuration.profile(id: sourceProfileID) ?? configuration.defaultProfile
        var newProfile = source.copied(name: name ?? nextProfileName())
        while configuration.profiles.contains(where: { $0.id == newProfile.id }) {
            newProfile.id = UUID().uuidString
        }

        var updated = configuration
        updated.profiles.append(newProfile)
        try saveConfiguration(updated)
        return newProfile
    }

    public func updateProfile(_ profile: ChatAppearanceProfile) throws {
        var updated = configuration
        guard let index = updated.profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ChatAppearanceProfileError.profileNotFound
        }
        var normalizedProfile = profile
        normalizedProfile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Profile" : profile.name
        if normalizedProfile.id == ChatAppearanceProfile.defaultProfileID {
            normalizedProfile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ChatAppearanceProfile.defaultProfileID
                : profile.name
        }
        updated.profiles[index] = normalizedProfile
        try saveConfiguration(updated)
    }

    public func deleteProfile(id: String) throws {
        guard id != ChatAppearanceProfile.defaultProfileID else {
            throw ChatAppearanceProfileError.defaultProfileCannotBeDeleted
        }

        var updated = configuration
        let beforeCount = updated.profiles.count
        updated.profiles.removeAll { $0.id == id }
        guard updated.profiles.count != beforeCount else {
            throw ChatAppearanceProfileError.profileNotFound
        }
        updated.scheduleRules.removeAll { $0.profileID == id }
        try saveConfiguration(updated)
    }

    public func resetColors(profileID: String) throws {
        guard var profile = configuration.profile(id: profileID) else {
            throw ChatAppearanceProfileError.profileNotFound
        }
        profile.userBubble = .defaultUserBubble
        profile.assistantBubble = .defaultAssistantBubble
        profile.lightText = .defaultLightText
        profile.darkText = .defaultDarkText
        try updateProfile(profile)
    }

    @discardableResult
    public func addScheduleRule(profileID: String, startMinuteOfDay: Int, endMinuteOfDay: Int) throws -> ChatAppearanceScheduleRule {
        guard configuration.profile(id: profileID) != nil else {
            throw ChatAppearanceProfileError.profileNotFound
        }
        let rule = ChatAppearanceScheduleRule(
            profileID: profileID,
            startMinuteOfDay: startMinuteOfDay,
            endMinuteOfDay: endMinuteOfDay
        )
        var updated = configuration
        updated.scheduleRules.append(rule)
        try saveConfiguration(updated)
        return rule
    }

    public func updateScheduleRule(_ rule: ChatAppearanceScheduleRule) throws {
        var updated = configuration
        guard let index = updated.scheduleRules.firstIndex(where: { $0.id == rule.id }) else {
            throw ChatAppearanceProfileError.profileNotFound
        }
        updated.scheduleRules[index] = rule
        try saveConfiguration(updated)
    }

    public func deleteScheduleRule(id: String) throws {
        var updated = configuration
        updated.scheduleRules.removeAll { $0.id == id }
        try saveConfiguration(updated)
    }

    public func refreshActiveProfile() {
        refreshActiveProfile(reschedule: true)
    }

    private func apply(
        configuration newConfiguration: ChatAppearanceProfileConfiguration
    ) {
        let normalized = newConfiguration.normalized()
        configuration = normalized
        refreshActiveProfile(reschedule: true)
    }

    private func refreshActiveProfile(reschedule: Bool) {
        let currentDate = now()
        activeProfile = configuration.activeProfile(at: currentDate, calendar: calendar)
        activeRuleID = configuration.activeRule(at: currentDate, calendar: calendar)?.id
        if reschedule {
            scheduleNextRefresh()
        }
    }

    private func scheduleNextRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        guard automaticallySchedulesRefresh,
              let nextDate = configuration.nextBoundary(after: now(), calendar: calendar) else {
            return
        }

        let delay = max(1, min(nextDate.timeIntervalSince(now()), 24 * 60 * 60))
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                // 任务被取消（通常由下一次 scheduleNextRefresh 触发），直接退出，避免触发无限循环
                return
            }
            await MainActor.run { [weak self] in
                self?.refreshActiveProfile()
            }
        }
    }

    private func nextProfileName() -> String {
        var index = 1
        while configuration.profiles.contains(where: { $0.name == "Profile \(index)" }) {
            index += 1
        }
        return "Profile \(index)"
    }
}

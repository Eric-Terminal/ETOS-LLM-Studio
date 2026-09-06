// ============================================================================
// ModelPricing.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义模型本地计费配置、消息费用快照与通用计算逻辑。
// ============================================================================

import Foundation

public enum ModelPricingBillingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case token
    case perRequest

    public var localizedTitle: String {
        switch self {
        case .token:
            return NSLocalizedString("按 Token", comment: "Token-based pricing mode")
        case .perRequest:
            return NSLocalizedString("按次", comment: "Per-request pricing mode")
        }
    }
}

public struct ModelPricing: Codable, Hashable, Sendable {
    public var inputPerMillionTokens: Double?
    public var outputPerMillionTokens: Double?
    public var cacheWritePerMillionTokens: Double?
    /// Anthropic 的默认 5 分钟档沿用通用缓存创建价格，1 小时档单独计价。
    public var cacheWriteOneHourPerMillionTokens: Double?
    public var cacheReadPerMillionTokens: Double?
    public var tiers: [ModelPricingTier]
    public var timeOverridesEnabled: Bool
    public var timeOverrides: [ModelPricingTimeOverride]
    public var billingMode: ModelPricingBillingMode
    public var perRequestPrice: Double?

    public init(
        inputPerMillionTokens: Double? = nil,
        outputPerMillionTokens: Double? = nil,
        cacheWritePerMillionTokens: Double? = nil,
        cacheWriteOneHourPerMillionTokens: Double? = nil,
        cacheReadPerMillionTokens: Double? = nil,
        tiers: [ModelPricingTier] = [],
        timeOverridesEnabled: Bool = false,
        timeOverrides: [ModelPricingTimeOverride] = [],
        billingMode: ModelPricingBillingMode = .token,
        perRequestPrice: Double? = nil
    ) {
        self.inputPerMillionTokens = Self.normalizedPrice(inputPerMillionTokens)
        self.outputPerMillionTokens = Self.normalizedPrice(outputPerMillionTokens)
        self.cacheWritePerMillionTokens = Self.normalizedPrice(cacheWritePerMillionTokens)
        self.cacheWriteOneHourPerMillionTokens = Self.normalizedPrice(cacheWriteOneHourPerMillionTokens)
        self.cacheReadPerMillionTokens = Self.normalizedPrice(cacheReadPerMillionTokens)
        self.tiers = Self.normalizedTiers(tiers)
        self.timeOverridesEnabled = timeOverridesEnabled
        self.timeOverrides = Self.normalizedTimeOverrides(timeOverrides)
        self.billingMode = billingMode
        self.perRequestPrice = Self.normalizedPrice(perRequestPrice)
    }

    public var isEffectivelyEmpty: Bool {
        billingMode == .token
            && inputPerMillionTokens == nil
            && outputPerMillionTokens == nil
            && cacheWritePerMillionTokens == nil
            && cacheWriteOneHourPerMillionTokens == nil
            && cacheReadPerMillionTokens == nil
            && perRequestPrice == nil
            && tiers.isEmpty
            && (!timeOverridesEnabled || timeOverrides.isEmpty)
    }

    public var normalized: ModelPricing {
        ModelPricing(
            inputPerMillionTokens: inputPerMillionTokens,
            outputPerMillionTokens: outputPerMillionTokens,
            cacheWritePerMillionTokens: cacheWritePerMillionTokens,
            cacheWriteOneHourPerMillionTokens: cacheWriteOneHourPerMillionTokens,
            cacheReadPerMillionTokens: cacheReadPerMillionTokens,
            tiers: tiers,
            timeOverridesEnabled: timeOverridesEnabled,
            timeOverrides: timeOverrides,
            billingMode: billingMode,
            perRequestPrice: perRequestPrice
        )
    }

    public func effectivePrices(
        for usage: MessageTokenUsage,
        requestedAt: Date? = nil,
        calendar: Calendar = .current
    ) -> ModelPricingEffectivePrices {
        let basisTokens = ModelCostCalculator.tierBasisTokens(for: usage)
        let selectedTier = tiers
            .filter { $0.minimumTokens <= basisTokens }
            .max { lhs, rhs in
                if lhs.minimumTokens == rhs.minimumTokens {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.minimumTokens < rhs.minimumTokens
            }

        let timeOverride = matchingTimeOverride(requestedAt: requestedAt, calendar: calendar)
        return ModelPricingEffectivePrices(
            tierBasisTokens: basisTokens,
            tierMinimumTokens: selectedTier?.minimumTokens,
            timeOverrideID: timeOverride?.id,
            timeOverrideStartMinuteOfDay: timeOverride?.startMinuteOfDay,
            timeOverrideEndMinuteOfDay: timeOverride?.endMinuteOfDay,
            inputPerMillionTokens: timeOverride?.inputPerMillionTokens ?? selectedTier?.inputPerMillionTokens ?? inputPerMillionTokens,
            outputPerMillionTokens: timeOverride?.outputPerMillionTokens ?? selectedTier?.outputPerMillionTokens ?? outputPerMillionTokens,
            cacheWritePerMillionTokens: timeOverride?.cacheWritePerMillionTokens ?? selectedTier?.cacheWritePerMillionTokens ?? cacheWritePerMillionTokens,
            cacheWriteOneHourPerMillionTokens: timeOverride?.cacheWriteOneHourPerMillionTokens ?? selectedTier?.cacheWriteOneHourPerMillionTokens ?? cacheWriteOneHourPerMillionTokens,
            cacheReadPerMillionTokens: timeOverride?.cacheReadPerMillionTokens ?? selectedTier?.cacheReadPerMillionTokens ?? cacheReadPerMillionTokens
        )
    }

    public func matchingTimeOverride(
        requestedAt: Date?,
        calendar: Calendar = .current
    ) -> ModelPricingTimeOverride? {
        guard timeOverridesEnabled, let requestedAt else { return nil }
        return timeOverrides.first { $0.contains(requestedAt, calendar: calendar) }
    }

    public static func normalizedPrice(_ value: Double?) -> Double? {
        guard let value, value >= 0, value.isFinite else { return nil }
        return value
    }

    public static func normalizedTiers(_ tiers: [ModelPricingTier]) -> [ModelPricingTier] {
        tiers
            .map(\.normalized)
            .filter { !$0.isEffectivelyEmpty }
            .sorted {
                if $0.minimumTokens == $1.minimumTokens {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.minimumTokens < $1.minimumTokens
            }
    }

    public static func normalizedTimeOverrides(_ timeOverrides: [ModelPricingTimeOverride]) -> [ModelPricingTimeOverride] {
        timeOverrides
            .map(\.normalized)
            .filter { !$0.weekdays.isEmpty && !$0.isEffectivelyEmpty }
            .sorted {
                if $0.startMinuteOfDay == $1.startMinuteOfDay {
                    if $0.endMinuteOfDay == $1.endMinuteOfDay {
                        return $0.id.uuidString < $1.id.uuidString
                    }
                    return $0.endMinuteOfDay < $1.endMinuteOfDay
                }
                return $0.startMinuteOfDay < $1.startMinuteOfDay
            }
    }

    public static func minuteOfDay(for date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return ModelPricingTimeOverride.normalizedMinute(
            (components.hour ?? 0) * 60 + (components.minute ?? 0)
        )
    }
}

extension ModelPricing {
    public func normalized(forAPIFormat apiFormat: String) -> ModelPricing {
        var pricing = self
        if ProviderAPIFormatFamily(apiFormat: apiFormat) != .anthropic {
            // 切换协议后以默认 5 分钟价格收回单档，避免隐藏的 1 小时价格继续生效。
            pricing.cacheWriteOneHourPerMillionTokens = nil
            for index in pricing.tiers.indices {
                pricing.tiers[index].cacheWriteOneHourPerMillionTokens = nil
            }
            for index in pricing.timeOverrides.indices {
                pricing.timeOverrides[index].cacheWriteOneHourPerMillionTokens = nil
            }
        }
        return pricing.normalized
    }

    private enum CodingKeys: String, CodingKey {
        case inputPerMillionTokens
        case outputPerMillionTokens
        case cacheWritePerMillionTokens
        case cacheWriteOneHourPerMillionTokens
        case cacheReadPerMillionTokens
        case tiers
        case timeOverridesEnabled
        case timeOverrides
        case billingMode
        case perRequestPrice
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let inputPerMillionTokens = try container.decodeIfPresent(Double.self, forKey: .inputPerMillionTokens)
        let outputPerMillionTokens = try container.decodeIfPresent(Double.self, forKey: .outputPerMillionTokens)
        let cacheWritePerMillionTokens = try container.decodeIfPresent(Double.self, forKey: .cacheWritePerMillionTokens)
        let cacheWriteOneHourPerMillionTokens = try container.decodeIfPresent(Double.self, forKey: .cacheWriteOneHourPerMillionTokens)
        let cacheReadPerMillionTokens = try container.decodeIfPresent(Double.self, forKey: .cacheReadPerMillionTokens)
        let tiers = try container.decodeIfPresent([ModelPricingTier].self, forKey: .tiers) ?? []
        let timeOverridesEnabled = try container.decodeIfPresent(Bool.self, forKey: .timeOverridesEnabled) ?? false
        let timeOverrides = try container.decodeIfPresent([ModelPricingTimeOverride].self, forKey: .timeOverrides) ?? []
        let perRequestPrice = try container.decodeIfPresent(Double.self, forKey: .perRequestPrice)
        let billingMode = try container.decodeIfPresent(ModelPricingBillingMode.self, forKey: .billingMode)
            ?? Self.inferredBillingMode(
                perRequestPrice: perRequestPrice,
                inputPerMillionTokens: inputPerMillionTokens,
                outputPerMillionTokens: outputPerMillionTokens,
                cacheWritePerMillionTokens: cacheWritePerMillionTokens,
                cacheWriteOneHourPerMillionTokens: cacheWriteOneHourPerMillionTokens,
                cacheReadPerMillionTokens: cacheReadPerMillionTokens,
                tiers: tiers,
                timeOverrides: timeOverrides
            )
        self.init(
            inputPerMillionTokens: inputPerMillionTokens,
            outputPerMillionTokens: outputPerMillionTokens,
            cacheWritePerMillionTokens: cacheWritePerMillionTokens,
            cacheWriteOneHourPerMillionTokens: cacheWriteOneHourPerMillionTokens,
            cacheReadPerMillionTokens: cacheReadPerMillionTokens,
            tiers: tiers,
            timeOverridesEnabled: timeOverridesEnabled,
            timeOverrides: timeOverrides,
            billingMode: billingMode,
            perRequestPrice: perRequestPrice
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(inputPerMillionTokens, forKey: .inputPerMillionTokens)
        try container.encodeIfPresent(outputPerMillionTokens, forKey: .outputPerMillionTokens)
        try container.encodeIfPresent(cacheWritePerMillionTokens, forKey: .cacheWritePerMillionTokens)
        try container.encodeIfPresent(cacheWriteOneHourPerMillionTokens, forKey: .cacheWriteOneHourPerMillionTokens)
        try container.encodeIfPresent(cacheReadPerMillionTokens, forKey: .cacheReadPerMillionTokens)
        if !tiers.isEmpty {
            try container.encode(tiers, forKey: .tiers)
        }
        if timeOverridesEnabled {
            try container.encode(timeOverridesEnabled, forKey: .timeOverridesEnabled)
        }
        if !timeOverrides.isEmpty {
            try container.encode(timeOverrides, forKey: .timeOverrides)
        }
        if billingMode != .token {
            try container.encode(billingMode, forKey: .billingMode)
        }
        try container.encodeIfPresent(perRequestPrice, forKey: .perRequestPrice)
    }

    private static func inferredBillingMode(
        perRequestPrice: Double?,
        inputPerMillionTokens: Double?,
        outputPerMillionTokens: Double?,
        cacheWritePerMillionTokens: Double?,
        cacheWriteOneHourPerMillionTokens: Double?,
        cacheReadPerMillionTokens: Double?,
        tiers: [ModelPricingTier],
        timeOverrides: [ModelPricingTimeOverride]
    ) -> ModelPricingBillingMode {
        if perRequestPrice != nil,
           inputPerMillionTokens == nil,
           outputPerMillionTokens == nil,
           cacheWritePerMillionTokens == nil,
           cacheWriteOneHourPerMillionTokens == nil,
           cacheReadPerMillionTokens == nil,
           tiers.isEmpty,
           timeOverrides.isEmpty {
            return .perRequest
        }
        return .token
    }
}

public struct ModelPricingTier: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var minimumTokens: Int
    public var inputPerMillionTokens: Double?
    public var outputPerMillionTokens: Double?
    public var cacheWritePerMillionTokens: Double?
    public var cacheWriteOneHourPerMillionTokens: Double?
    public var cacheReadPerMillionTokens: Double?

    public init(
        id: UUID = UUID(),
        minimumTokens: Int,
        inputPerMillionTokens: Double? = nil,
        outputPerMillionTokens: Double? = nil,
        cacheWritePerMillionTokens: Double? = nil,
        cacheWriteOneHourPerMillionTokens: Double? = nil,
        cacheReadPerMillionTokens: Double? = nil
    ) {
        self.id = id
        self.minimumTokens = max(0, minimumTokens)
        self.inputPerMillionTokens = ModelPricing.normalizedPrice(inputPerMillionTokens)
        self.outputPerMillionTokens = ModelPricing.normalizedPrice(outputPerMillionTokens)
        self.cacheWritePerMillionTokens = ModelPricing.normalizedPrice(cacheWritePerMillionTokens)
        self.cacheWriteOneHourPerMillionTokens = ModelPricing.normalizedPrice(cacheWriteOneHourPerMillionTokens)
        self.cacheReadPerMillionTokens = ModelPricing.normalizedPrice(cacheReadPerMillionTokens)
    }

    public var isEffectivelyEmpty: Bool {
        inputPerMillionTokens == nil
            && outputPerMillionTokens == nil
            && cacheWritePerMillionTokens == nil
            && cacheWriteOneHourPerMillionTokens == nil
            && cacheReadPerMillionTokens == nil
    }

    public var normalized: ModelPricingTier {
        ModelPricingTier(
            id: id,
            minimumTokens: minimumTokens,
            inputPerMillionTokens: inputPerMillionTokens,
            outputPerMillionTokens: outputPerMillionTokens,
            cacheWritePerMillionTokens: cacheWritePerMillionTokens,
            cacheWriteOneHourPerMillionTokens: cacheWriteOneHourPerMillionTokens,
            cacheReadPerMillionTokens: cacheReadPerMillionTokens
        )
    }
}

public struct ModelPricingEffectivePrices: Hashable, Sendable {
    public var tierBasisTokens: Int
    public var tierMinimumTokens: Int?
    public var timeOverrideID: UUID?
    public var timeOverrideStartMinuteOfDay: Int?
    public var timeOverrideEndMinuteOfDay: Int?
    public var inputPerMillionTokens: Double?
    public var outputPerMillionTokens: Double?
    public var cacheWritePerMillionTokens: Double?
    public var cacheWriteOneHourPerMillionTokens: Double?
    public var cacheReadPerMillionTokens: Double?
}

public enum ModelPricingWeekday: Int, Codable, CaseIterable, Hashable, Sendable {
    case sunday = 1
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    public static let everyDay: Set<ModelPricingWeekday> = Set(allCases)
    public static let weekdays: Set<ModelPricingWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    public static let weekend: Set<ModelPricingWeekday> = [.saturday, .sunday]

    nonisolated public var previous: Self {
        switch self {
        case .sunday: return .saturday
        case .monday: return .sunday
        case .tuesday: return .monday
        case .wednesday: return .tuesday
        case .thursday: return .wednesday
        case .friday: return .thursday
        case .saturday: return .friday
        }
    }

    nonisolated public static func ordered(for calendar: Calendar) -> [Self] {
        let firstWeekday = Self(rawValue: calendar.firstWeekday) ?? .sunday
        guard let firstIndex = allCases.firstIndex(of: firstWeekday) else {
            return allCases
        }
        return Array(allCases[firstIndex...]) + Array(allCases[..<firstIndex])
    }
}

public struct ModelPricingTimeOverride: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var startMinuteOfDay: Int
    public var endMinuteOfDay: Int
    public var weekdays: Set<ModelPricingWeekday>
    public var inputPerMillionTokens: Double?
    public var outputPerMillionTokens: Double?
    public var cacheWritePerMillionTokens: Double?
    public var cacheWriteOneHourPerMillionTokens: Double?
    public var cacheReadPerMillionTokens: Double?

    public init(
        id: UUID = UUID(),
        startMinuteOfDay: Int,
        endMinuteOfDay: Int,
        weekdays: Set<ModelPricingWeekday> = ModelPricingWeekday.everyDay,
        inputPerMillionTokens: Double? = nil,
        outputPerMillionTokens: Double? = nil,
        cacheWritePerMillionTokens: Double? = nil,
        cacheWriteOneHourPerMillionTokens: Double? = nil,
        cacheReadPerMillionTokens: Double? = nil
    ) {
        self.id = id
        self.startMinuteOfDay = Self.normalizedMinute(startMinuteOfDay)
        self.endMinuteOfDay = Self.normalizedMinute(endMinuteOfDay)
        self.weekdays = weekdays
        self.inputPerMillionTokens = ModelPricing.normalizedPrice(inputPerMillionTokens)
        self.outputPerMillionTokens = ModelPricing.normalizedPrice(outputPerMillionTokens)
        self.cacheWritePerMillionTokens = ModelPricing.normalizedPrice(cacheWritePerMillionTokens)
        self.cacheWriteOneHourPerMillionTokens = ModelPricing.normalizedPrice(cacheWriteOneHourPerMillionTokens)
        self.cacheReadPerMillionTokens = ModelPricing.normalizedPrice(cacheReadPerMillionTokens)
    }

    public var isEffectivelyEmpty: Bool {
        inputPerMillionTokens == nil
            && outputPerMillionTokens == nil
            && cacheWritePerMillionTokens == nil
            && cacheWriteOneHourPerMillionTokens == nil
            && cacheReadPerMillionTokens == nil
    }

    public var isAllDay: Bool {
        startMinuteOfDay == endMinuteOfDay
    }

    public var isCrossMidnight: Bool {
        startMinuteOfDay > endMinuteOfDay
    }

    public var normalized: ModelPricingTimeOverride {
        ModelPricingTimeOverride(
            id: id,
            startMinuteOfDay: startMinuteOfDay,
            endMinuteOfDay: endMinuteOfDay,
            weekdays: weekdays,
            inputPerMillionTokens: inputPerMillionTokens,
            outputPerMillionTokens: outputPerMillionTokens,
            cacheWritePerMillionTokens: cacheWritePerMillionTokens,
            cacheWriteOneHourPerMillionTokens: cacheWriteOneHourPerMillionTokens,
            cacheReadPerMillionTokens: cacheReadPerMillionTokens
        )
    }

    public func contains(minuteOfDay minute: Int) -> Bool {
        let minute = Self.normalizedMinute(minute)
        if startMinuteOfDay < endMinuteOfDay {
            return minute >= startMinuteOfDay && minute < endMinuteOfDay
        }
        if startMinuteOfDay > endMinuteOfDay {
            return minute >= startMinuteOfDay || minute < endMinuteOfDay
        }
        return true
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let minute = ModelPricing.minuteOfDay(for: date, calendar: calendar)
        guard contains(minuteOfDay: minute),
              let currentWeekday = ModelPricingWeekday(rawValue: calendar.component(.weekday, from: date)) else {
            return false
        }

        // 午夜后的片段仍属于开始日，避免“周五夜间”在周六零点被错误排除。
        let scheduleWeekday = isCrossMidnight && minute < endMinuteOfDay
            ? currentWeekday.previous
            : currentWeekday
        return weekdays.contains(scheduleWeekday)
    }

    public static func normalizedMinute(_ minute: Int) -> Int {
        let dayMinutes = 24 * 60
        return ((minute % dayMinutes) + dayMinutes) % dayMinutes
    }
}

extension ModelPricingTimeOverride {
    private enum CodingKeys: String, CodingKey {
        case id
        case startMinuteOfDay
        case endMinuteOfDay
        case weekdays
        case inputPerMillionTokens
        case outputPerMillionTokens
        case cacheWritePerMillionTokens
        case cacheWriteOneHourPerMillionTokens
        case cacheReadPerMillionTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            startMinuteOfDay: try container.decode(Int.self, forKey: .startMinuteOfDay),
            endMinuteOfDay: try container.decode(Int.self, forKey: .endMinuteOfDay),
            weekdays: Set(
                try container.decodeIfPresent([ModelPricingWeekday].self, forKey: .weekdays)
                    ?? ModelPricingWeekday.allCases
            ),
            inputPerMillionTokens: try container.decodeIfPresent(Double.self, forKey: .inputPerMillionTokens),
            outputPerMillionTokens: try container.decodeIfPresent(Double.self, forKey: .outputPerMillionTokens),
            cacheWritePerMillionTokens: try container.decodeIfPresent(Double.self, forKey: .cacheWritePerMillionTokens),
            cacheWriteOneHourPerMillionTokens: try container.decodeIfPresent(Double.self, forKey: .cacheWriteOneHourPerMillionTokens),
            cacheReadPerMillionTokens: try container.decodeIfPresent(Double.self, forKey: .cacheReadPerMillionTokens)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startMinuteOfDay, forKey: .startMinuteOfDay)
        try container.encode(endMinuteOfDay, forKey: .endMinuteOfDay)
        if weekdays != ModelPricingWeekday.everyDay {
            try container.encode(weekdays.sorted { $0.rawValue < $1.rawValue }, forKey: .weekdays)
        }
        try container.encodeIfPresent(inputPerMillionTokens, forKey: .inputPerMillionTokens)
        try container.encodeIfPresent(outputPerMillionTokens, forKey: .outputPerMillionTokens)
        try container.encodeIfPresent(cacheWritePerMillionTokens, forKey: .cacheWritePerMillionTokens)
        try container.encodeIfPresent(cacheWriteOneHourPerMillionTokens, forKey: .cacheWriteOneHourPerMillionTokens)
        try container.encodeIfPresent(cacheReadPerMillionTokens, forKey: .cacheReadPerMillionTokens)
    }
}

public enum ModelPricingTimeRangeText {
    nonisolated public static func text(
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) -> String {
        if ModelPricingTimeOverride.normalizedMinute(startMinuteOfDay)
            == ModelPricingTimeOverride.normalizedMinute(endMinuteOfDay) {
            return NSLocalizedString("全天", comment: "All-day peak valley pricing range")
        }
        return "\(displayTime(minuteOfDay: startMinuteOfDay)) - \(displayTime(minuteOfDay: endMinuteOfDay))"
    }

    nonisolated public static func displayTime(minuteOfDay minute: Int) -> String {
        let minute = ModelPricingTimeOverride.normalizedMinute(minute)
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}

public enum ModelPricingWeekdayText {
    nonisolated public static func title(for weekday: ModelPricingWeekday) -> String {
        switch weekday {
        case .sunday: return NSLocalizedString("周日", comment: "Sunday pricing schedule option")
        case .monday: return NSLocalizedString("周一", comment: "Monday pricing schedule option")
        case .tuesday: return NSLocalizedString("周二", comment: "Tuesday pricing schedule option")
        case .wednesday: return NSLocalizedString("周三", comment: "Wednesday pricing schedule option")
        case .thursday: return NSLocalizedString("周四", comment: "Thursday pricing schedule option")
        case .friday: return NSLocalizedString("周五", comment: "Friday pricing schedule option")
        case .saturday: return NSLocalizedString("周六", comment: "Saturday pricing schedule option")
        }
    }

    nonisolated public static func summary(
        for weekdays: Set<ModelPricingWeekday>,
        calendar: Calendar
    ) -> String {
        if weekdays == ModelPricingWeekday.everyDay {
            return NSLocalizedString("每天", comment: "Every day pricing schedule summary")
        }
        if weekdays == ModelPricingWeekday.weekdays {
            return NSLocalizedString("工作日", comment: "Weekdays pricing schedule summary")
        }
        if weekdays == ModelPricingWeekday.weekend {
            return NSLocalizedString("周末", comment: "Weekend pricing schedule summary")
        }
        guard !weekdays.isEmpty else {
            return NSLocalizedString("未选择", comment: "No pricing schedule weekdays selected")
        }

        return ModelPricingWeekday.ordered(for: calendar)
            .filter(weekdays.contains)
            .map { title(for: $0) }
            .joined(separator: " • ")
    }
}

public enum ModelPricingTierRangeText {
    nonisolated public static func text(
        minimumTokens: Int,
        nextMinimumTokens: Int? = nil
    ) -> String {
        let minimumTokens = max(0, minimumTokens)
        if let nextMinimumTokens = nextMinimumTokens.map({ max(0, $0) }),
           nextMinimumTokens > minimumTokens {
            let upperBoundary = max(0, nextMinimumTokens - 1)
            if minimumTokens == 0 {
                return String(
                    format: NSLocalizedString("<= %@ tokens", comment: "Pricing tier upper-bound title"),
                    compactTokenText(upperBoundary)
                )
            }
            return String(
                format: NSLocalizedString("> %@ 且 <= %@ tokens", comment: "Pricing tier closed range title"),
                compactTokenText(max(0, minimumTokens - 1)),
                compactTokenText(upperBoundary)
            )
        }

        if minimumTokens == 0 {
            return NSLocalizedString("全部 tokens", comment: "Pricing tier all tokens title")
        }
        return String(
            format: NSLocalizedString("> %@ tokens", comment: "Pricing tier lower-bound title"),
            compactTokenText(max(0, minimumTokens - 1))
        )
    }

    nonisolated private static func compactTokenText(_ tokens: Int) -> String {
        let tokens = max(0, tokens)
        if tokens >= 1_000_000 {
            return compactScaledTokenText(tokens, divisor: 1_000_000, suffix: "M")
        }
        if tokens >= 1_000 {
            return compactScaledTokenText(tokens, divisor: 1_000, suffix: "K")
        }
        return "\(tokens)"
    }

    nonisolated private static func compactScaledTokenText(_ tokens: Int, divisor: Int, suffix: String) -> String {
        let scaledTenths = Int((Double(tokens) / Double(divisor) * 10).rounded())
        if scaledTenths % 10 == 0 {
            return "\(scaledTenths / 10)\(suffix)"
        }
        return String(format: "%.1f%@", Double(scaledTenths) / 10, suffix)
    }
}

public struct MessageModelReference: Codable, Hashable, Sendable {
    public var providerID: UUID?
    public var providerName: String
    public var modelUUID: UUID?
    public var modelName: String
    public var modelDisplayName: String

    public init(
        providerID: UUID?,
        providerName: String,
        modelUUID: UUID?,
        modelName: String,
        modelDisplayName: String
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelUUID = modelUUID
        self.modelName = modelName
        self.modelDisplayName = modelDisplayName
    }
}

public enum MessageCostComponentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case request
    case input
    case output
    case cacheWrite
    case cacheWriteFiveMinute
    case cacheWriteOneHour
    case cacheRead

    public var localizedTitle: String {
        switch self {
        case .request:
            return NSLocalizedString("请求", comment: "Cost component request title")
        case .input:
            return NSLocalizedString("输入", comment: "Cost component input title")
        case .output:
            return NSLocalizedString("输出", comment: "Cost component output title")
        case .cacheWrite:
            return NSLocalizedString("缓存创建", comment: "Cost component cache write title")
        case .cacheWriteFiveMinute:
            return NSLocalizedString("缓存创建（5 分钟）", comment: "5 分钟缓存创建费用")
        case .cacheWriteOneHour:
            return NSLocalizedString("缓存创建（1 小时）", comment: "1 小时缓存创建费用")
        case .cacheRead:
            return NSLocalizedString("缓存命中", comment: "Cost component cache read title")
        }
    }
}

public struct MessageCostComponent: Codable, Identifiable, Hashable, Sendable {
    public var id: MessageCostComponentKind { kind }
    public var kind: MessageCostComponentKind
    public var tokens: Int
    public var pricePerMillionTokens: Double
    public var subtotal: Double

    public init(
        kind: MessageCostComponentKind,
        tokens: Int,
        pricePerMillionTokens: Double,
        subtotal: Double
    ) {
        self.kind = kind
        self.tokens = max(0, tokens)
        self.pricePerMillionTokens = max(0, pricePerMillionTokens)
        self.subtotal = max(0, subtotal)
    }
}

public struct MessageCostEstimate: Codable, Hashable, Sendable {
    public var totalCost: Double
    public var tierBasisTokens: Int
    public var tierMinimumTokens: Int?
    public var timeOverrideID: UUID?
    public var timeOverrideStartMinuteOfDay: Int?
    public var timeOverrideEndMinuteOfDay: Int?
    public var components: [MessageCostComponent]
    public var isEstimatedFromCurrentPricing: Bool

    public init(
        totalCost: Double,
        tierBasisTokens: Int,
        tierMinimumTokens: Int?,
        timeOverrideID: UUID? = nil,
        timeOverrideStartMinuteOfDay: Int? = nil,
        timeOverrideEndMinuteOfDay: Int? = nil,
        components: [MessageCostComponent],
        isEstimatedFromCurrentPricing: Bool = false
    ) {
        self.totalCost = max(0, totalCost)
        self.tierBasisTokens = max(0, tierBasisTokens)
        self.tierMinimumTokens = tierMinimumTokens.map { max(0, $0) }
        self.timeOverrideID = timeOverrideID
        self.timeOverrideStartMinuteOfDay = timeOverrideStartMinuteOfDay.map(ModelPricingTimeOverride.normalizedMinute)
        self.timeOverrideEndMinuteOfDay = timeOverrideEndMinuteOfDay.map(ModelPricingTimeOverride.normalizedMinute)
        self.components = components.filter { $0.tokens > 0 && $0.pricePerMillionTokens >= 0 }
        self.isEstimatedFromCurrentPricing = isEstimatedFromCurrentPricing
    }

    public var hasCost: Bool {
        !components.isEmpty
    }
}

public enum ModelCostCalculator {
    public static func tierBasisTokens(for usage: MessageTokenUsage) -> Int {
        billableInputTokens(for: usage)
            + max(0, usage.cacheWriteTokens ?? 0)
            + max(0, usage.cacheReadTokens ?? 0)
    }

    public static func estimateCost(
        usage: MessageTokenUsage?,
        pricing: ModelPricing?,
        requestedAt: Date? = nil,
        calendar: Calendar = .current,
        isEstimatedFromCurrentPricing: Bool = false,
        requestCount: Int = 1
    ) -> MessageCostEstimate? {
        guard let pricing = pricing?.normalized, !pricing.isEffectivelyEmpty else {
            return nil
        }

        if pricing.billingMode == .perRequest {
            return estimatePerRequestCost(
                usage: usage,
                pricing: pricing,
                isEstimatedFromCurrentPricing: isEstimatedFromCurrentPricing,
                requestCount: requestCount
            )
        }

        guard let usage, usage.hasAnyData else { return nil }

        let effective = pricing.effectivePrices(for: usage, requestedAt: requestedAt, calendar: calendar)
        var components: [MessageCostComponent] = []

        appendComponent(
            kind: .input,
            tokens: billableInputTokens(for: usage),
            pricePerMillionTokens: effective.inputPerMillionTokens,
            to: &components
        )
        appendComponent(
            kind: .output,
            tokens: usage.completionTokens,
            pricePerMillionTokens: effective.outputPerMillionTokens,
            to: &components
        )
        if usage.cacheWriteFiveMinuteTokens != nil || usage.cacheWriteOneHourTokens != nil {
            let oneHourTokens = max(0, usage.cacheWriteOneHourTokens ?? 0)
            // 兼容只返回总量及部分时长明细的代理，未区分的余额沿用默认 5 分钟档。
            let fiveMinuteTokens = max(0, (usage.cacheWriteTokens ?? 0) - oneHourTokens)
            appendComponent(
                kind: .cacheWriteFiveMinute,
                tokens: max(fiveMinuteTokens, usage.cacheWriteFiveMinuteTokens ?? 0),
                pricePerMillionTokens: effective.cacheWritePerMillionTokens,
                to: &components
            )
            appendComponent(
                kind: .cacheWriteOneHour,
                tokens: oneHourTokens,
                pricePerMillionTokens: effective.cacheWriteOneHourPerMillionTokens,
                to: &components
            )
        } else {
            appendComponent(
                kind: .cacheWrite,
                tokens: usage.cacheWriteTokens,
                pricePerMillionTokens: effective.cacheWritePerMillionTokens,
                to: &components
            )
        }
        appendComponent(
            kind: .cacheRead,
            tokens: usage.cacheReadTokens,
            pricePerMillionTokens: effective.cacheReadPerMillionTokens,
            to: &components
        )

        guard !components.isEmpty else { return nil }
        let total = components.reduce(0) { $0 + $1.subtotal }
        return MessageCostEstimate(
            totalCost: total,
            tierBasisTokens: effective.tierBasisTokens,
            tierMinimumTokens: effective.tierMinimumTokens,
            timeOverrideID: effective.timeOverrideID,
            timeOverrideStartMinuteOfDay: effective.timeOverrideStartMinuteOfDay,
            timeOverrideEndMinuteOfDay: effective.timeOverrideEndMinuteOfDay,
            components: components,
            isEstimatedFromCurrentPricing: isEstimatedFromCurrentPricing
        )
    }

    private static func estimatePerRequestCost(
        usage: MessageTokenUsage?,
        pricing: ModelPricing,
        isEstimatedFromCurrentPricing: Bool,
        requestCount: Int
    ) -> MessageCostEstimate? {
        guard let perRequestPrice = pricing.perRequestPrice else { return nil }
        let normalizedRequestCount = max(1, requestCount)
        let component = MessageCostComponent(
            kind: .request,
            tokens: normalizedRequestCount,
            pricePerMillionTokens: perRequestPrice,
            subtotal: Double(normalizedRequestCount) * perRequestPrice
        )
        return MessageCostEstimate(
            totalCost: component.subtotal,
            tierBasisTokens: usage.map { tierBasisTokens(for: $0) } ?? 0,
            tierMinimumTokens: nil,
            components: [component],
            isEstimatedFromCurrentPricing: isEstimatedFromCurrentPricing
        )
    }

    private static func appendComponent(
        kind: MessageCostComponentKind,
        tokens: Int?,
        pricePerMillionTokens: Double?,
        to components: inout [MessageCostComponent]
    ) {
        guard let tokens, tokens > 0, let pricePerMillionTokens, pricePerMillionTokens >= 0 else { return }
        let subtotal = Double(tokens) / 1_000_000 * pricePerMillionTokens
        components.append(
            MessageCostComponent(
                kind: kind,
                tokens: tokens,
                pricePerMillionTokens: pricePerMillionTokens,
                subtotal: subtotal
            )
        )
    }

    static func billableInputTokens(for usage: MessageTokenUsage) -> Int {
        if let uncachedInputTokens = usage.uncachedInputTokens {
            return max(0, uncachedInputTokens)
        }
        let promptTokens = max(0, usage.promptTokens ?? 0)
        let cacheReadTokens = max(0, usage.cacheReadTokens ?? 0)
        return max(0, promptTokens - cacheReadTokens)
    }
}

public enum MessageCostResolver {
    public static func resolvedCost(
        for message: ChatMessage,
        providers: [Provider]
    ) -> MessageCostEstimate? {
        if let snapshot = message.costEstimate, snapshot.hasCost {
            return snapshot
        }
        guard let modelReference = message.modelReference,
              let pricing = matchingPricing(for: modelReference, providers: providers) else {
            return nil
        }
        return ModelCostCalculator.estimateCost(
            usage: message.tokenUsage,
            pricing: pricing,
            requestedAt: message.requestedAt ?? message.responseMetrics?.requestStartedAt,
            isEstimatedFromCurrentPricing: true
        )
    }

    public static func matchingPricing(
        for reference: MessageModelReference,
        providers: [Provider]
    ) -> ModelPricing? {
        let providerCandidates: [Provider]
        if let providerID = reference.providerID,
           let provider = providers.first(where: { $0.id == providerID }) {
            providerCandidates = [provider]
        } else {
            let normalizedName = reference.providerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            providerCandidates = providers.filter {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
            }
        }

        for provider in providerCandidates {
            if let modelUUID = reference.modelUUID,
               let model = provider.models.first(where: { $0.id == modelUUID }),
               let pricing = model.pricing?.normalized,
               !pricing.isEffectivelyEmpty {
                return pricing
            }
            let normalizedModelName = reference.modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let model = provider.models.first(where: {
                $0.modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedModelName
            }),
               let pricing = model.pricing?.normalized,
               !pricing.isEffectivelyEmpty {
                return pricing
            }
        }

        return nil
    }
}

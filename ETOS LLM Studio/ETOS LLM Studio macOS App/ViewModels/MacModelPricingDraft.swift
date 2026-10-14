import ETOSCore
import Foundation

/// 保留输入中的空值和未完成数字，只有明确提交时才转换为核心价格配置。
struct MacModelPriceFields: Equatable, Sendable {
    var input = ""
    var output = ""
    var cacheWrite = ""
    var cacheWriteOneHour = ""
    var cacheRead = ""

    init(input: Double? = nil, output: Double? = nil, cacheWrite: Double? = nil,
         cacheWriteOneHour: Double? = nil, cacheRead: Double? = nil) {
        self.input = input.map { String($0) } ?? ""
        self.output = output.map { String($0) } ?? ""
        self.cacheWrite = cacheWrite.map { String($0) } ?? ""
        self.cacheWriteOneHour = cacheWriteOneHour.map { String($0) } ?? ""
        self.cacheRead = cacheRead.map { String($0) } ?? ""
    }

    func pricing(anthropic: Bool) throws -> ModelPricing {
        try ModelPricing(inputPerMillionTokens: Self.price(input), outputPerMillionTokens: Self.price(output),
                         cacheWritePerMillionTokens: Self.price(cacheWrite),
                         cacheWriteOneHourPerMillionTokens: anthropic ? Self.price(cacheWriteOneHour) : nil,
                         cacheReadPerMillionTokens: Self.price(cacheRead))
    }

    static func price(_ text: String) throws -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Double(value), let price = ModelPricing.normalizedPrice(number) else {
            throw MacModelPricingError.invalidPrice
        }
        return price
    }
}

struct MacModelPricingTierDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var minimumTokens = "0"
    var prices = MacModelPriceFields()

    init() {}
    init(_ tier: ModelPricingTier) {
        id = tier.id
        minimumTokens = String(tier.minimumTokens)
        prices = .init(input: tier.inputPerMillionTokens, output: tier.outputPerMillionTokens,
                       cacheWrite: tier.cacheWritePerMillionTokens, cacheWriteOneHour: tier.cacheWriteOneHourPerMillionTokens,
                       cacheRead: tier.cacheReadPerMillionTokens)
    }
}

struct MacModelPricingTimeDraft: Identifiable, Equatable, Sendable {
    var id = UUID()
    var start = "00:00"
    var end = "01:00"
    var weekdays = ModelPricingWeekday.everyDay
    var prices = MacModelPriceFields()

    init() {}
    init(_ time: ModelPricingTimeOverride) {
        id = time.id
        start = ModelPricingTimeRangeText.displayTime(minuteOfDay: time.startMinuteOfDay)
        end = ModelPricingTimeRangeText.displayTime(minuteOfDay: time.endMinuteOfDay)
        weekdays = time.weekdays
        prices = .init(input: time.inputPerMillionTokens, output: time.outputPerMillionTokens,
                       cacheWrite: time.cacheWritePerMillionTokens, cacheWriteOneHour: time.cacheWriteOneHourPerMillionTokens,
                       cacheRead: time.cacheReadPerMillionTokens)
    }
}

struct MacModelPricingDraft: Equatable, Sendable {
    var mode: ModelPricingBillingMode = .token
    var perRequest = ""
    var prices = MacModelPriceFields()
    var tiers: [MacModelPricingTierDraft] = []
    var timeEnabled = false
    var times: [MacModelPricingTimeDraft] = []

    init(_ pricing: ModelPricing? = nil) {
        guard let pricing else { return }
        mode = pricing.billingMode
        perRequest = pricing.perRequestPrice.map { String($0) } ?? ""
        prices = .init(input: pricing.inputPerMillionTokens, output: pricing.outputPerMillionTokens,
                       cacheWrite: pricing.cacheWritePerMillionTokens, cacheWriteOneHour: pricing.cacheWriteOneHourPerMillionTokens,
                       cacheRead: pricing.cacheReadPerMillionTokens)
        tiers = pricing.tiers.map(MacModelPricingTierDraft.init)
        timeEnabled = pricing.timeOverridesEnabled
        times = pricing.timeOverrides.map(MacModelPricingTimeDraft.init)
    }

    /// 在后台验证全部草稿；无效输入不能被当作留空而悄悄删除已有价格。
    func pricing(apiFormat: String) throws -> ModelPricing? {
        let anthropic = ProviderAPIFormatFamily(apiFormat: apiFormat) == .anthropic
        var result = try prices.pricing(anthropic: anthropic)
        result.billingMode = mode
        result.perRequestPrice = try MacModelPriceFields.price(perRequest)
        result.tiers = try tiers.map { tier in
            guard let minimum = Int(tier.minimumTokens.trimmingCharacters(in: .whitespacesAndNewlines)), minimum >= 0 else {
                throw MacModelPricingError.invalidThreshold
            }
            let values = try tier.prices.pricing(anthropic: anthropic)
            return ModelPricingTier(id: tier.id, minimumTokens: minimum, inputPerMillionTokens: values.inputPerMillionTokens,
                                    outputPerMillionTokens: values.outputPerMillionTokens, cacheWritePerMillionTokens: values.cacheWritePerMillionTokens,
                                    cacheWriteOneHourPerMillionTokens: values.cacheWriteOneHourPerMillionTokens,
                                    cacheReadPerMillionTokens: values.cacheReadPerMillionTokens)
        }
        result.timeOverridesEnabled = timeEnabled
        result.timeOverrides = try times.map { time in
            guard let start = ModelPricingTimeRangeText.minuteOfDay(from: time.start),
                  let end = ModelPricingTimeRangeText.minuteOfDay(from: time.end) else { throw MacModelPricingError.invalidTime }
            guard !time.weekdays.isEmpty else { throw MacModelPricingError.missingWeekdays }
            let values = try time.prices.pricing(anthropic: anthropic)
            return ModelPricingTimeOverride(id: time.id, startMinuteOfDay: start, endMinuteOfDay: end, weekdays: time.weekdays,
                                            inputPerMillionTokens: values.inputPerMillionTokens, outputPerMillionTokens: values.outputPerMillionTokens,
                                            cacheWritePerMillionTokens: values.cacheWritePerMillionTokens,
                                            cacheWriteOneHourPerMillionTokens: values.cacheWriteOneHourPerMillionTokens,
                                            cacheReadPerMillionTokens: values.cacheReadPerMillionTokens)
        }
        let normalized = result.normalized
        return normalized.isEffectivelyEmpty ? nil : normalized
    }
}

enum MacModelPricingError: LocalizedError {
    case invalidPrice, invalidThreshold, invalidTime, missingWeekdays
    var errorDescription: String? {
        switch self {
        case .invalidPrice: NSLocalizedString("价格须留空或填写有限的非负数。", comment: "")
        case .invalidThreshold: NSLocalizedString("阶梯起始 Tokens 须填写非负整数。", comment: "")
        case .invalidTime: NSLocalizedString("时间须使用 00:00 到 23:59 的格式。", comment: "")
        case .missingWeekdays: NSLocalizedString("每个价格时间段至少选择一个重复日。", comment: "")
        }
    }
}

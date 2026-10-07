import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacModelPricingDraftTests {
    @Test("完整价格草稿往返保留微小单价、零值、档位标识和跨午夜时间")
    func pricingRoundTrip() throws {
        let tier = ModelPricingTier(minimumTokens: 100_000, inputPerMillionTokens: 0,
                                    cacheWriteOneHourPerMillionTokens: 0.000000000123)
        let time = ModelPricingTimeOverride(startMinuteOfDay: 22 * 60, endMinuteOfDay: 2 * 60,
                                            weekdays: [.monday, .friday], outputPerMillionTokens: 0.123456789123,
                                            cacheWriteOneHourPerMillionTokens: 2)
        let original = ModelPricing(inputPerMillionTokens: 1e-12, outputPerMillionTokens: 2.123456789,
                                    cacheWritePerMillionTokens: 0, cacheWriteOneHourPerMillionTokens: 4,
                                    cacheReadPerMillionTokens: 0.01, tiers: [tier], timeOverridesEnabled: true,
                                    timeOverrides: [time], billingMode: .perRequest, perRequestPrice: 0.000000000123)
        let result = try #require(MacModelPricingDraft(original).pricing(apiFormat: "anthropic"))
        #expect(result == original)
        let encoded = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(ModelPricing.self, from: encoded) == original)
    }

    @Test("切换协议统一清除基础、阶梯和峰谷的专属一小时档位")
    func protocolSpecificPrices() throws {
        let source = ModelPricing(inputPerMillionTokens: 1, cacheWriteOneHourPerMillionTokens: 4,
                                  tiers: [.init(minimumTokens: 100, outputPerMillionTokens: 2, cacheWriteOneHourPerMillionTokens: 5)],
                                  timeOverridesEnabled: true,
                                  timeOverrides: [.init(startMinuteOfDay: 0, endMinuteOfDay: 60, cacheWriteOneHourPerMillionTokens: 6, cacheReadPerMillionTokens: 0)])
        let result = try #require(MacModelPricingDraft(source).pricing(apiFormat: "openai-responses"))
        #expect(result == source.normalized(forAPIFormat: "openai-responses"))
        #expect(result.tiers.first?.cacheWriteOneHourPerMillionTokens == nil)
        #expect(result.timeOverrides.first?.cacheWriteOneHourPerMillionTokens == nil)
        #expect(result.timeOverrides.first?.cacheReadPerMillionTokens == 0)
    }

    @Test("空值允许继承，非法或无限价格不会被静默丢弃", arguments: ["-1", "NaN", "inf", "1e999", "abc", "1.2.3"])
    func rejectsInvalidPrice(_ input: String) {
        var draft = MacModelPricingDraft()
        draft.prices.input = input
        #expect(throws: MacModelPricingError.self) { try draft.pricing(apiFormat: "anthropic") }
    }

    @Test("时间与阶梯无效时保留待修复草稿，关闭峰谷不删除有效时段")
    func validatesSchedulesAndThresholds() throws {
        var draft = MacModelPricingDraft(.init(inputPerMillionTokens: 1))
        var tier = MacModelPricingTierDraft()
        tier.prices.output = "2"
        tier.minimumTokens = "100.5"
        draft.tiers = [tier]
        #expect(throws: MacModelPricingError.self) { try draft.pricing(apiFormat: "gemini") }
        draft.tiers[0].minimumTokens = "100"
        var time = MacModelPricingTimeDraft()
        time.prices.input = "0"
        time.start = "24:00"
        draft.times = [time]
        #expect(throws: MacModelPricingError.self) { try draft.pricing(apiFormat: "gemini") }
        draft.times[0].start = "9：05"
        draft.times[0].end = "09:05"
        draft.times[0].weekdays = []
        #expect(throws: MacModelPricingError.self) { try draft.pricing(apiFormat: "gemini") }
        draft.times[0].weekdays = [.wednesday]
        let result = try #require(draft.pricing(apiFormat: "gemini"))
        #expect(!result.timeOverridesEnabled)
        #expect(result.timeOverrides.first?.id == time.id)
        #expect(result.timeOverrides.first?.isAllDay == true)
        #expect(result.timeOverrides.first?.inputPerMillionTokens == 0)
    }

    @Test("显式清空产生空配置，按次零价格保留计费方式")
    func clearAndZeroRequestPrice() throws {
        #expect(try MacModelPricingDraft().pricing(apiFormat: "anthropic") == nil)
        #expect(try MacModelPriceFields.price(" \n") == nil)
        var draft = MacModelPricingDraft()
        draft.mode = .perRequest
        draft.perRequest = "0"
        let result = try #require(draft.pricing(apiFormat: "anthropic"))
        #expect(result.billingMode == .perRequest)
        #expect(result.perRequestPrice == 0)
    }
}

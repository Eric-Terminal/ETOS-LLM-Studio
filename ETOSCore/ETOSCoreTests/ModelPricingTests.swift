// ============================================================================
// ModelPricingTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责模型计费配置、费用计算与费用快照持久化测试。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("模型计费测试")
struct ModelPricingTests {
    @Test("两种缓存时长分别计费且阶梯依据不重复累计缓存")
    func mixedCacheDurationsUseSeparatePrices() throws {
        let usage = MessageTokenUsage(
            promptTokens: 2_048, completionTokens: 503, totalTokens: nil,
            cacheWriteTokens: 248, cacheWriteFiveMinuteTokens: 148, cacheWriteOneHourTokens: 100,
            cacheReadTokens: 1_800, uncachedInputTokens: 2_048
        )
        let pricing = ModelPricing(
            inputPerMillionTokens: 3, outputPerMillionTokens: 15,
            cacheWritePerMillionTokens: 3.75, cacheWriteOneHourPerMillionTokens: 6,
            cacheReadPerMillionTokens: 0.3
        )
        let estimate = try #require(ModelCostCalculator.estimateCost(usage: usage, pricing: pricing))
        #expect(estimate.tierBasisTokens == 4_096)
        #expect(estimate.components.first { $0.kind == .input }?.tokens == 2_048)
        #expect(estimate.components.first { $0.kind == .cacheWriteFiveMinute }?.tokens == 148)
        #expect(estimate.components.first { $0.kind == .cacheWriteOneHour }?.tokens == 100)
        #expect(!estimate.components.contains { $0.kind == .cacheWrite })
        #expect(abs(estimate.totalCost - 0.015384) < 0.000001)
        let restored = try JSONDecoder().decode(MessageCostEstimate.self, from: JSONEncoder().encode(estimate))
        #expect(restored == estimate)
        let restoredUsage = try JSONDecoder().decode(MessageTokenUsage.self, from: JSONEncoder().encode(usage))
        #expect(restoredUsage == usage)
    }

    @Test("旧配置及无时长明细的缓存总量沿用默认价格")
    func legacyCachePricingRemainsCompatible() throws {
        let pricing = try JSONDecoder().decode(ModelPricing.self, from: Data(#"{"cacheWritePerMillionTokens":3.75}"#.utf8))
        #expect(pricing.cacheWriteOneHourPerMillionTokens == nil)
        let usage = MessageTokenUsage(promptTokens: nil, completionTokens: nil, totalTokens: nil, cacheWriteTokens: 1_000)
        let estimate = try #require(ModelCostCalculator.estimateCost(usage: usage, pricing: pricing))
        #expect(estimate.components.count == 1)
        #expect(estimate.components.first?.kind == .cacheWrite)
        #expect(abs(estimate.totalCost - 0.00375) < 0.000001)

        let oneHourUsage = MessageTokenUsage(
            promptTokens: nil, completionTokens: nil, totalTokens: nil,
            cacheWriteTokens: 1_000, cacheWriteFiveMinuteTokens: 0, cacheWriteOneHourTokens: 1_000
        )
        // 已知时长不能套用另一档价格；留空仍表示不参与估算，零价则显式保留费用项。
        #expect(ModelCostCalculator.estimateCost(usage: oneHourUsage, pricing: pricing) == nil)
        let freePricing = ModelPricing(cacheWriteOneHourPerMillionTokens: 0)
        let free = try #require(ModelCostCalculator.estimateCost(usage: oneHourUsage, pricing: freePricing))
        #expect(free.components.first?.kind == .cacheWriteOneHour)
        #expect(free.totalCost == 0)
    }

    @Test("两档缓存价格分别继承阶梯和峰谷覆盖并可序列化")
    func cacheDurationPricesInheritIndependently() throws {
        let calendar = utcCalendar()
        let usage = MessageTokenUsage(
            promptTokens: 100, completionTokens: nil, totalTokens: nil,
            cacheWriteTokens: 2_000, cacheWriteFiveMinuteTokens: 1_000, cacheWriteOneHourTokens: 1_000
        )
        let pricing = ModelPricing(
            cacheWritePerMillionTokens: 3.75, cacheWriteOneHourPerMillionTokens: 6,
            tiers: [ModelPricingTier(minimumTokens: 2_000, cacheWriteOneHourPerMillionTokens: 8)],
            timeOverridesEnabled: true,
            timeOverrides: [ModelPricingTimeOverride(startMinuteOfDay: 600, endMinuteOfDay: 720, cacheWritePerMillionTokens: 2)]
        )
        let restored = try JSONDecoder().decode(ModelPricing.self, from: JSONEncoder().encode(pricing))
        #expect(restored == pricing)
        let effective = restored.effectivePrices(for: usage, requestedAt: date(hour: 11, minute: 0, calendar: calendar), calendar: calendar)
        #expect(effective.cacheWritePerMillionTokens == 2)
        #expect(effective.cacheWriteOneHourPerMillionTokens == 8)
        #expect(effective.tierMinimumTokens == 2_000)
        let offPeak = restored.effectivePrices(for: usage, requestedAt: date(hour: 13, minute: 0, calendar: calendar), calendar: calendar)
        #expect(offPeak.cacheWritePerMillionTokens == 3.75)
        #expect(offPeak.cacheWriteOneHourPerMillionTokens == 8)
    }

    @Test("收回单档清除所有一小时价格并保留默认档和计费方式")
    func adapterChangeCollapsesAllCachePriceLevels() {
        let pricing = ModelPricing(
            cacheWritePerMillionTokens: 3.75, cacheWriteOneHourPerMillionTokens: 6,
            tiers: [
                ModelPricingTier(minimumTokens: 100, cacheWritePerMillionTokens: 5, cacheWriteOneHourPerMillionTokens: 8),
                ModelPricingTier(minimumTokens: 200, cacheWriteOneHourPerMillionTokens: 10)
            ],
            timeOverridesEnabled: true,
            timeOverrides: [ModelPricingTimeOverride(startMinuteOfDay: 600, endMinuteOfDay: 720, cacheWritePerMillionTokens: 2, cacheWriteOneHourPerMillionTokens: 4)],
            billingMode: .perRequest, perRequestPrice: 0.5
        )
        #expect(pricing.normalized(forAPIFormat: "anthropic") == pricing)
        for format in ["openai-compatible", "openai-responses", "gemini"] {
            let collapsed = pricing.normalized(forAPIFormat: format)
            #expect(collapsed.cacheWritePerMillionTokens == 3.75)
            #expect(collapsed.cacheWriteOneHourPerMillionTokens == nil)
            #expect(collapsed.tiers.count == 1)
            #expect(collapsed.tiers.first?.cacheWritePerMillionTokens == 5)
            #expect(collapsed.tiers.first?.cacheWriteOneHourPerMillionTokens == nil)
            #expect(collapsed.timeOverrides.first?.cacheWritePerMillionTokens == 2)
            #expect(collapsed.timeOverrides.first?.cacheWriteOneHourPerMillionTokens == nil)
            #expect(collapsed.billingMode == .perRequest)
            #expect(collapsed.perRequestPrice == 0.5)
            #expect(collapsed.normalized(forAPIFormat: "anthropic").cacheWriteOneHourPerMillionTokens == nil)
        }
    }

    @Test("同步合并保留缓存时长明细且旧用量解码不要求新字段")
    func cacheDurationUsageMergesWithLegacyUsage() throws {
        let legacy = try JSONDecoder().decode(MessageTokenUsage.self, from: Data(#"{"promptTokens":20,"cacheWriteTokens":300}"#.utf8))
        #expect(legacy.cacheWriteFiveMinuteTokens == nil)
        #expect(legacy.cacheWriteOneHourTokens == nil)
        #expect(legacy.uncachedInputTokens == nil)
        let detailed = MessageTokenUsage(
            promptTokens: 20, completionTokens: 8, totalTokens: nil,
            cacheWriteTokens: 300, cacheWriteFiveMinuteTokens: 100, cacheWriteOneHourTokens: 200,
            uncachedInputTokens: 20
        )
        #expect(SyncEngine.mergeTokenUsage(legacy, detailed) == detailed)
        #expect(SyncEngine.mergeTokenUsage(detailed, legacy) == detailed)
    }

    @Test("空价格不会产生费用")
    func emptyPricingProducesNoCost() {
        let usage = MessageTokenUsage(promptTokens: 1_000, completionTokens: 500, totalTokens: 1_500)

        let estimate = ModelCostCalculator.estimateCost(usage: usage, pricing: ModelPricing())

        #expect(estimate == nil)
    }

    @Test("按次价格不依赖 token 用量并按请求数量累计")
    func perRequestPricingAddsFixedRequestCost() throws {
        let pricing = ModelPricing(billingMode: .perRequest, perRequestPrice: 0.03)

        let estimate = try #require(
            ModelCostCalculator.estimateCost(
                usage: nil,
                pricing: pricing,
                requestCount: 3
            )
        )

        #expect(estimate.tierBasisTokens == 0)
        #expect(estimate.components.count == 1)
        #expect(estimate.components.first?.kind == .request)
        #expect(estimate.components.first?.tokens == 3)
        #expect(estimate.components.first?.pricePerMillionTokens == 0.03)
        #expect(abs(estimate.totalCost - 0.09) < 0.000001)
    }

    @Test("按次价格可以估算没有 token 用量的旧消息")
    func resolverUsesPerRequestPricingWithoutTokenUsage() throws {
        let providerID = UUID()
        let modelID = UUID()
        let reference = MessageModelReference(
            providerID: providerID,
            providerName: "Per Request Provider",
            modelUUID: modelID,
            modelName: "per-request",
            modelDisplayName: "Per Request"
        )
        let provider = Provider(
            id: providerID,
            name: "Per Request Provider",
            baseURL: "https://per-request.example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    id: modelID,
                    modelName: "per-request",
                    pricing: ModelPricing(billingMode: .perRequest, perRequestPrice: 0.05)
                )
            ]
        )
        let message = ChatMessage(
            role: .assistant,
            content: "旧消息",
            modelReference: reference
        )

        let estimate = try #require(MessageCostResolver.resolvedCost(for: message, providers: [provider]))

        #expect(estimate.isEstimatedFromCurrentPricing)
        #expect(estimate.components.first?.kind == .request)
        #expect(abs(estimate.totalCost - 0.05) < 0.000001)
    }

    @Test("基础价格会按未命中输入输出和缓存费用累计")
    func basePricingAddsAllConfiguredComponents() throws {
        let usage = MessageTokenUsage(
            promptTokens: 5_000,
            completionTokens: 2_000,
            totalTokens: 7_700,
            cacheWriteTokens: 400,
            cacheReadTokens: 300
        )
        let pricing = ModelPricing(
            inputPerMillionTokens: 0.5,
            outputPerMillionTokens: 3,
            cacheWritePerMillionTokens: 1,
            cacheReadPerMillionTokens: 0.1
        )

        let estimate = try #require(ModelCostCalculator.estimateCost(usage: usage, pricing: pricing))

        #expect(estimate.tierBasisTokens == 5_400)
        #expect(estimate.tierMinimumTokens == nil)
        #expect(estimate.components.count == 4)
        #expect(estimate.components.first(where: { $0.kind == .input })?.tokens == 4_700)
        #expect(abs(estimate.totalCost - 0.00878) < 0.000001)
    }

    @Test("阶梯按输入和缓存 Token 命中并整条请求使用档位价格")
    func tierPricingUsesWholeRequestPrice() throws {
        let usage = MessageTokenUsage(
            promptTokens: 5_500,
            completionTokens: 1_000,
            totalTokens: 6_700,
            cacheWriteTokens: 700,
            cacheReadTokens: 500
        )
        let pricing = ModelPricing(
            inputPerMillionTokens: 1,
            outputPerMillionTokens: 10,
            cacheWritePerMillionTokens: 2,
            cacheReadPerMillionTokens: 0.5,
            tiers: [
                ModelPricingTier(minimumTokens: 5_000, inputPerMillionTokens: 0.5, outputPerMillionTokens: 8),
                ModelPricingTier(minimumTokens: 6_000, inputPerMillionTokens: 0.25, cacheReadPerMillionTokens: 0.1)
            ]
        )

        let estimate = try #require(ModelCostCalculator.estimateCost(usage: usage, pricing: pricing))

        #expect(estimate.tierBasisTokens == 6_200)
        #expect(estimate.tierMinimumTokens == 6_000)
        #expect(estimate.components.first(where: { $0.kind == .input })?.tokens == 5_000)
        #expect(estimate.components.first(where: { $0.kind == .input })?.pricePerMillionTokens == 0.25)
        #expect(estimate.components.first(where: { $0.kind == .output })?.pricePerMillionTokens == 10)
        #expect(estimate.components.first(where: { $0.kind == .cacheWrite })?.pricePerMillionTokens == 2)
        #expect(estimate.components.first(where: { $0.kind == .cacheRead })?.pricePerMillionTokens == 0.1)
        #expect(abs(estimate.totalCost - 0.0127) < 0.000001)
    }

    @Test("峰谷定价命中时间段时覆盖填写的价格")
    func peakValleyPricingOverridesConfiguredPricesInWindow() throws {
        let calendar = utcCalendar()
        let usage = MessageTokenUsage(promptTokens: 1_000, completionTokens: 1_000, totalTokens: 2_000)
        let timeOverrideID = UUID(uuidString: "00000000-0000-0000-0000-000000000095")!
        let pricing = ModelPricing(
            inputPerMillionTokens: 1,
            outputPerMillionTokens: 2,
            timeOverridesEnabled: true,
            timeOverrides: [
                ModelPricingTimeOverride(
                    id: timeOverrideID,
                    startMinuteOfDay: 10 * 60,
                    endMinuteOfDay: 12 * 60,
                    inputPerMillionTokens: 0.5,
                    outputPerMillionTokens: 1
                )
            ]
        )

        let estimate = try #require(
            ModelCostCalculator.estimateCost(
                usage: usage,
                pricing: pricing,
                requestedAt: date(hour: 10, minute: 30, calendar: calendar),
                calendar: calendar
            )
        )

        #expect(estimate.timeOverrideID == timeOverrideID)
        #expect(estimate.timeOverrideStartMinuteOfDay == 10 * 60)
        #expect(estimate.timeOverrideEndMinuteOfDay == 12 * 60)
        #expect(estimate.components.first(where: { $0.kind == .input })?.pricePerMillionTokens == 0.5)
        #expect(estimate.components.first(where: { $0.kind == .output })?.pricePerMillionTokens == 1)
        #expect(abs(estimate.totalCost - 0.0015) < 0.000001)
    }

    @Test("峰谷定价未命中时间段时使用外层价格")
    func peakValleyPricingFallsBackOutsideWindow() throws {
        let calendar = utcCalendar()
        let usage = MessageTokenUsage(promptTokens: 1_000, completionTokens: 1_000, totalTokens: 2_000)
        let pricing = ModelPricing(
            inputPerMillionTokens: 1,
            outputPerMillionTokens: 2,
            timeOverridesEnabled: true,
            timeOverrides: [
                ModelPricingTimeOverride(
                    startMinuteOfDay: 10 * 60,
                    endMinuteOfDay: 12 * 60,
                    inputPerMillionTokens: 0.5,
                    outputPerMillionTokens: 1
                )
            ]
        )

        let estimate = try #require(
            ModelCostCalculator.estimateCost(
                usage: usage,
                pricing: pricing,
                requestedAt: date(hour: 14, minute: 0, calendar: calendar),
                calendar: calendar
            )
        )

        #expect(estimate.timeOverrideID == nil)
        #expect(estimate.components.first(where: { $0.kind == .input })?.pricePerMillionTokens == 1)
        #expect(estimate.components.first(where: { $0.kind == .output })?.pricePerMillionTokens == 2)
        #expect(abs(estimate.totalCost - 0.003) < 0.000001)
    }

    @Test("峰谷定价支持跨午夜并继承未填写价格")
    func peakValleyPricingSupportsCrossMidnightAndInheritance() throws {
        let calendar = utcCalendar()
        let usage = MessageTokenUsage(promptTokens: 2_000, completionTokens: 1_000, totalTokens: 3_000)
        let pricing = ModelPricing(
            inputPerMillionTokens: 1,
            outputPerMillionTokens: 2,
            timeOverridesEnabled: true,
            timeOverrides: [
                ModelPricingTimeOverride(
                    startMinuteOfDay: 23 * 60,
                    endMinuteOfDay: 2 * 60,
                    inputPerMillionTokens: 0.25
                )
            ]
        )

        let estimate = try #require(
            ModelCostCalculator.estimateCost(
                usage: usage,
                pricing: pricing,
                requestedAt: date(hour: 1, minute: 30, calendar: calendar),
                calendar: calendar
            )
        )

        #expect(estimate.components.first(where: { $0.kind == .input })?.pricePerMillionTokens == 0.25)
        #expect(estimate.components.first(where: { $0.kind == .output })?.pricePerMillionTokens == 2)
        #expect(abs(estimate.totalCost - 0.0025) < 0.000001)
    }

    @Test("峰谷定价支持周末全天重复")
    func peakValleyPricingSupportsAllDayWeekends() throws {
        let calendar = utcCalendar()
        let timeOverrideID = UUID(uuidString: "00000000-0000-0000-0000-000000000096")!
        let pricing = ModelPricing(
            inputPerMillionTokens: 1,
            timeOverridesEnabled: true,
            timeOverrides: [
                ModelPricingTimeOverride(
                    id: timeOverrideID,
                    startMinuteOfDay: 0,
                    endMinuteOfDay: 0,
                    weekdays: ModelPricingWeekday.weekend,
                    inputPerMillionTokens: 0.25
                )
            ]
        )

        #expect(
            pricing.matchingTimeOverride(
                requestedAt: date(day: 4, hour: 15, minute: 0, calendar: calendar),
                calendar: calendar
            )?.id == timeOverrideID
        )
        #expect(
            pricing.matchingTimeOverride(
                requestedAt: date(day: 5, hour: 23, minute: 59, calendar: calendar),
                calendar: calendar
            )?.id == timeOverrideID
        )
        #expect(
            pricing.matchingTimeOverride(
                requestedAt: date(day: 6, hour: 15, minute: 0, calendar: calendar),
                calendar: calendar
            ) == nil
        )
        #expect(ModelPricingTimeRangeText.text(startMinuteOfDay: 0, endMinuteOfDay: 0) == NSLocalizedString("全天", comment: ""))
    }

    @Test("跨午夜时段按开始日重复")
    func crossMidnightPricingUsesStartingWeekday() {
        let calendar = utcCalendar()
        let timeOverride = ModelPricingTimeOverride(
            startMinuteOfDay: 23 * 60,
            endMinuteOfDay: 2 * 60,
            weekdays: [.monday],
            inputPerMillionTokens: 0.25
        )

        #expect(timeOverride.contains(date(day: 6, hour: 23, minute: 30, calendar: calendar), calendar: calendar))
        #expect(timeOverride.contains(date(day: 7, hour: 1, minute: 30, calendar: calendar), calendar: calendar))
        #expect(!timeOverride.contains(date(day: 6, hour: 1, minute: 30, calendar: calendar), calendar: calendar))
        #expect(!timeOverride.contains(date(day: 7, hour: 23, minute: 30, calendar: calendar), calendar: calendar))
    }

    @Test("阶梯范围文本使用紧凑 token 边界")
    func tierRangeTextUsesCompactBoundaries() {
        #expect(ModelPricingTierRangeText.text(minimumTokens: 0, nextMinimumTokens: 200_001).contains("200K"))
        #expect(ModelPricingTierRangeText.text(minimumTokens: 200_001).contains("200K"))

        let middleRange = ModelPricingTierRangeText.text(minimumTokens: 100_001, nextMinimumTokens: 200_001)
        #expect(middleRange.contains("100K"))
        #expect(middleRange.contains("200K"))
    }

    @Test("旧模型配置解码时价格为空")
    func legacyModelDecodesWithEmptyPricing() throws {
        let data = try #require(
            #"{"id":"00000000-0000-0000-0000-000000000001","modelName":"legacy-model","isActivated":true}"#
                .data(using: .utf8)
        )

        let model = try JSONDecoder().decode(Model.self, from: data)

        #expect(model.pricing == nil)
    }

    @Test("旧价格配置解码时峰谷定价默认关闭")
    func legacyPricingDecodesWithPeakValleyDisabled() throws {
        let data = try #require(
            #"{"inputPerMillionTokens":1,"outputPerMillionTokens":2}"#
                .data(using: .utf8)
        )

        let pricing = try JSONDecoder().decode(ModelPricing.self, from: data)

        #expect(pricing.inputPerMillionTokens == 1)
        #expect(!pricing.timeOverridesEnabled)
        #expect(pricing.timeOverrides.isEmpty)
    }

    @Test("旧峰谷时段解码时默认每天重复")
    func legacyTimeOverrideDecodesWithEveryDaySchedule() throws {
        let data = try #require(
            #"{"id":"00000000-0000-0000-0000-000000000097","startMinuteOfDay":600,"endMinuteOfDay":720,"inputPerMillionTokens":0.5}"#
                .data(using: .utf8)
        )

        let timeOverride = try JSONDecoder().decode(ModelPricingTimeOverride.self, from: data)

        #expect(timeOverride.weekdays == ModelPricingWeekday.everyDay)
    }

    @Test("只有每次请求价格的配置会按按次模式解码")
    func perRequestOnlyPricingDecodesAsPerRequestMode() throws {
        let data = try #require(
            #"{"perRequestPrice":0.03}"#
                .data(using: .utf8)
        )

        let pricing = try JSONDecoder().decode(ModelPricing.self, from: data)

        #expect(pricing.billingMode == .perRequest)
        #expect(pricing.perRequestPrice == 0.03)
    }

    @Test("非空价格配置可以 Codable 往返")
    func pricingCodableRoundTrip() throws {
        let model = Model(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            modelName: "priced-model",
            displayName: "Priced Model",
            pricing: ModelPricing(
                inputPerMillionTokens: 0.5,
                outputPerMillionTokens: 3,
                tiers: [
                    ModelPricingTier(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                        minimumTokens: 10_000,
                        inputPerMillionTokens: 0.4
                    )
                ],
                timeOverridesEnabled: true,
                timeOverrides: [
                    ModelPricingTimeOverride(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                        startMinuteOfDay: 10 * 60,
                        endMinuteOfDay: 12 * 60,
                        weekdays: ModelPricingWeekday.weekend,
                        outputPerMillionTokens: 1.5
                    )
                ]
            )
        )

        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.pricing?.inputPerMillionTokens == 0.5)
        #expect(decoded.pricing?.outputPerMillionTokens == 3)
        #expect(decoded.pricing?.tiers.first?.minimumTokens == 10_000)
        #expect(decoded.pricing?.tiers.first?.inputPerMillionTokens == 0.4)
        #expect(decoded.pricing?.timeOverridesEnabled == true)
        #expect(decoded.pricing?.timeOverrides.first?.startMinuteOfDay == 10 * 60)
        #expect(decoded.pricing?.timeOverrides.first?.weekdays == ModelPricingWeekday.weekend)
        #expect(decoded.pricing?.timeOverrides.first?.outputPerMillionTokens == 1.5)
    }

    @Test("Provider SQLite 可以保存并加载模型价格")
    func providerSQLiteRoundTripKeepsPricing() {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        let originalProviders = ConfigLoader.loadProviders()
        defer {
            resetProviders(to: originalProviders)
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }
        resetProviders(to: [])

        let provider = Provider(
            id: UUID(),
            name: "Pricing Provider",
            baseURL: "https://pricing.example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    modelName: "priced",
                    pricing: ModelPricing(
                        inputPerMillionTokens: 0.2,
                        outputPerMillionTokens: 1.2,
                        cacheReadPerMillionTokens: 0.05,
                        tiers: [
                            ModelPricingTier(minimumTokens: 8_000, outputPerMillionTokens: 1)
                        ]
                    )
                )
            ]
        )

        ConfigLoader.saveProvider(provider)
        let loaded = ConfigLoader.loadProviders().first(where: { $0.id == provider.id })

        #expect(loaded?.models.first?.pricing?.inputPerMillionTokens == 0.2)
        #expect(loaded?.models.first?.pricing?.outputPerMillionTokens == 1.2)
        #expect(loaded?.models.first?.pricing?.cacheReadPerMillionTokens == 0.05)
        #expect(loaded?.models.first?.pricing?.tiers.first?.minimumTokens == 8_000)
        #expect(loaded?.models.first?.pricing?.tiers.first?.outputPerMillionTokens == 1)
    }

    @Test("GRDB 消息持久化保留模型引用和费用快照")
    func grdbMessageRoundTripKeepsModelReferenceAndCostEstimate() throws {
        let previousOverride = Persistence.grdbEnabledOverrideForTests
        Persistence.grdbEnabledOverrideForTests = true
        Persistence.resetGRDBStoreForTests()
        defer {
            Persistence.grdbEnabledOverrideForTests = previousOverride
            Persistence.resetGRDBStoreForTests()
        }

        let session = ChatSession(id: UUID(), name: "费用快照会话", isTemporary: false)
        let providerID = UUID()
        let modelID = UUID()
        let modelReference = MessageModelReference(
            providerID: providerID,
            providerName: "Pricing Provider",
            modelUUID: modelID,
            modelName: "priced",
            modelDisplayName: "Priced"
        )
        let usage = MessageTokenUsage(promptTokens: 1_000, completionTokens: 500, totalTokens: 1_500)
        let estimate = try #require(
            ModelCostCalculator.estimateCost(
                usage: usage,
                pricing: ModelPricing(inputPerMillionTokens: 1, outputPerMillionTokens: 2)
            )
        )
        let message = ChatMessage(
            role: .assistant,
            content: "带费用的回复",
            tokenUsage: usage,
            modelReference: modelReference,
            costEstimate: estimate
        )

        Persistence.saveChatSessions([session])
        Persistence.saveMessages([message], for: session.id)

        let loaded = Persistence.loadMessages(for: session.id)
        #expect(loaded.first?.modelReference == modelReference)
        #expect(loaded.first?.costEstimate == estimate)

        Persistence.saveChatSessions([])
        Persistence.deleteSessionArtifacts(sessionID: session.id)
    }

    @Test("消息费用解析优先使用快照并能按当前价格估算旧消息")
    func resolverPrefersSnapshotAndFallsBackToCurrentPricing() throws {
        let providerID = UUID()
        let modelID = UUID()
        let reference = MessageModelReference(
            providerID: providerID,
            providerName: "Pricing Provider",
            modelUUID: modelID,
            modelName: "priced",
            modelDisplayName: "Priced"
        )
        let usage = MessageTokenUsage(promptTokens: 1_000, completionTokens: 500, totalTokens: 1_500)
        let provider = Provider(
            id: providerID,
            name: "Pricing Provider",
            baseURL: "https://pricing.example.com",
            apiKeys: [],
            apiFormat: "openai-compatible",
            models: [
                Model(
                    id: modelID,
                    modelName: "priced",
                    pricing: ModelPricing(inputPerMillionTokens: 1, outputPerMillionTokens: 2)
                )
            ]
        )
        let oldMessage = ChatMessage(
            role: .assistant,
            content: "旧消息",
            tokenUsage: usage,
            modelReference: reference
        )

        let fallbackEstimate = try #require(
            MessageCostResolver.resolvedCost(for: oldMessage, providers: [provider])
        )
        #expect(fallbackEstimate.isEstimatedFromCurrentPricing)
        #expect(abs(fallbackEstimate.totalCost - 0.002) < 0.000001)

        let snapshot = try #require(
            ModelCostCalculator.estimateCost(
                usage: usage,
                pricing: ModelPricing(inputPerMillionTokens: 10, outputPerMillionTokens: 20)
            )
        )
        let snapshotMessage = ChatMessage(
            role: .assistant,
            content: "新消息",
            tokenUsage: usage,
            modelReference: reference,
            costEstimate: snapshot
        )

        let resolvedSnapshot = try #require(
            MessageCostResolver.resolvedCost(for: snapshotMessage, providers: [provider])
        )
        #expect(!resolvedSnapshot.isEstimatedFromCurrentPricing)
        #expect(resolvedSnapshot == snapshot)
    }

    private func resetProviders(to providers: [Provider]) {
        ConfigLoader.loadProviders().forEach { ConfigLoader.deleteProvider($0) }
        providers.forEach { ConfigLoader.saveProvider($0) }
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(day: Int = 1, hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: minute))!
    }
}

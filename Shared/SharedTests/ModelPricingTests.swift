// ============================================================================
// ModelPricingTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责模型计费配置、费用计算与费用快照持久化测试。
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("模型计费测试")
struct ModelPricingTests {
    @Test("空价格不会产生费用")
    func emptyPricingProducesNoCost() {
        let usage = MessageTokenUsage(promptTokens: 1_000, completionTokens: 500, totalTokens: 1_500)

        let estimate = ModelCostCalculator.estimateCost(usage: usage, pricing: ModelPricing())

        #expect(estimate == nil)
    }

    @Test("基础价格会累计输入输出和缓存费用")
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

        #expect(estimate.tierBasisTokens == 5_700)
        #expect(estimate.tierMinimumTokens == nil)
        #expect(estimate.components.count == 4)
        #expect(abs(estimate.totalCost - 0.00893) < 0.000001)
    }

    @Test("阶梯按输入和缓存 Token 命中并整条请求使用档位价格")
    func tierPricingUsesWholeRequestPrice() throws {
        let usage = MessageTokenUsage(
            promptTokens: 5_000,
            completionTokens: 1_000,
            totalTokens: 6_200,
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
        #expect(estimate.components.first(where: { $0.kind == .input })?.pricePerMillionTokens == 0.25)
        #expect(estimate.components.first(where: { $0.kind == .output })?.pricePerMillionTokens == 10)
        #expect(estimate.components.first(where: { $0.kind == .cacheWrite })?.pricePerMillionTokens == 2)
        #expect(estimate.components.first(where: { $0.kind == .cacheRead })?.pricePerMillionTokens == 0.1)
        #expect(abs(estimate.totalCost - 0.0127) < 0.000001)
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
                ]
            )
        )

        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(Model.self, from: data)

        #expect(decoded.pricing?.inputPerMillionTokens == 0.5)
        #expect(decoded.pricing?.outputPerMillionTokens == 3)
        #expect(decoded.pricing?.tiers.first?.minimumTokens == 10_000)
        #expect(decoded.pricing?.tiers.first?.inputPerMillionTokens == 0.4)
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
}

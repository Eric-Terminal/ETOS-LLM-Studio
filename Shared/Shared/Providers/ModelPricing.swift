// ============================================================================
// ModelPricing.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义模型本地计费配置、消息费用快照与通用计算逻辑。
// ============================================================================

import Foundation

public struct ModelPricing: Codable, Hashable, Sendable {
    public static let defaultCurrencySymbol = "$"

    public var currencySymbol: String
    public var inputPerMillionTokens: Double?
    public var outputPerMillionTokens: Double?
    public var cacheWritePerMillionTokens: Double?
    public var cacheReadPerMillionTokens: Double?
    public var tiers: [ModelPricingTier]

    public init(
        currencySymbol: String = ModelPricing.defaultCurrencySymbol,
        inputPerMillionTokens: Double? = nil,
        outputPerMillionTokens: Double? = nil,
        cacheWritePerMillionTokens: Double? = nil,
        cacheReadPerMillionTokens: Double? = nil,
        tiers: [ModelPricingTier] = []
    ) {
        let trimmedCurrency = currencySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currencySymbol = trimmedCurrency.isEmpty ? ModelPricing.defaultCurrencySymbol : trimmedCurrency
        self.inputPerMillionTokens = Self.normalizedPrice(inputPerMillionTokens)
        self.outputPerMillionTokens = Self.normalizedPrice(outputPerMillionTokens)
        self.cacheWritePerMillionTokens = Self.normalizedPrice(cacheWritePerMillionTokens)
        self.cacheReadPerMillionTokens = Self.normalizedPrice(cacheReadPerMillionTokens)
        self.tiers = Self.normalizedTiers(tiers)
    }

    public var isEffectivelyEmpty: Bool {
        inputPerMillionTokens == nil
            && outputPerMillionTokens == nil
            && cacheWritePerMillionTokens == nil
            && cacheReadPerMillionTokens == nil
            && tiers.isEmpty
    }

    public var normalized: ModelPricing {
        ModelPricing(
            currencySymbol: currencySymbol,
            inputPerMillionTokens: inputPerMillionTokens,
            outputPerMillionTokens: outputPerMillionTokens,
            cacheWritePerMillionTokens: cacheWritePerMillionTokens,
            cacheReadPerMillionTokens: cacheReadPerMillionTokens,
            tiers: tiers
        )
    }

    public func effectivePrices(for usage: MessageTokenUsage) -> ModelPricingEffectivePrices {
        let basisTokens = ModelCostCalculator.tierBasisTokens(for: usage)
        let selectedTier = tiers
            .filter { $0.minimumTokens <= basisTokens }
            .max { lhs, rhs in
                if lhs.minimumTokens == rhs.minimumTokens {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.minimumTokens < rhs.minimumTokens
            }

        return ModelPricingEffectivePrices(
            currencySymbol: currencySymbol,
            tierBasisTokens: basisTokens,
            tierMinimumTokens: selectedTier?.minimumTokens,
            inputPerMillionTokens: selectedTier?.inputPerMillionTokens ?? inputPerMillionTokens,
            outputPerMillionTokens: selectedTier?.outputPerMillionTokens ?? outputPerMillionTokens,
            cacheWritePerMillionTokens: selectedTier?.cacheWritePerMillionTokens ?? cacheWritePerMillionTokens,
            cacheReadPerMillionTokens: selectedTier?.cacheReadPerMillionTokens ?? cacheReadPerMillionTokens
        )
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
}

public struct ModelPricingTier: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var minimumTokens: Int
    public var inputPerMillionTokens: Double?
    public var outputPerMillionTokens: Double?
    public var cacheWritePerMillionTokens: Double?
    public var cacheReadPerMillionTokens: Double?

    public init(
        id: UUID = UUID(),
        minimumTokens: Int,
        inputPerMillionTokens: Double? = nil,
        outputPerMillionTokens: Double? = nil,
        cacheWritePerMillionTokens: Double? = nil,
        cacheReadPerMillionTokens: Double? = nil
    ) {
        self.id = id
        self.minimumTokens = max(0, minimumTokens)
        self.inputPerMillionTokens = ModelPricing.normalizedPrice(inputPerMillionTokens)
        self.outputPerMillionTokens = ModelPricing.normalizedPrice(outputPerMillionTokens)
        self.cacheWritePerMillionTokens = ModelPricing.normalizedPrice(cacheWritePerMillionTokens)
        self.cacheReadPerMillionTokens = ModelPricing.normalizedPrice(cacheReadPerMillionTokens)
    }

    public var isEffectivelyEmpty: Bool {
        inputPerMillionTokens == nil
            && outputPerMillionTokens == nil
            && cacheWritePerMillionTokens == nil
            && cacheReadPerMillionTokens == nil
    }

    public var normalized: ModelPricingTier {
        ModelPricingTier(
            id: id,
            minimumTokens: minimumTokens,
            inputPerMillionTokens: inputPerMillionTokens,
            outputPerMillionTokens: outputPerMillionTokens,
            cacheWritePerMillionTokens: cacheWritePerMillionTokens,
            cacheReadPerMillionTokens: cacheReadPerMillionTokens
        )
    }
}

public struct ModelPricingEffectivePrices: Hashable, Sendable {
    public var currencySymbol: String
    public var tierBasisTokens: Int
    public var tierMinimumTokens: Int?
    public var inputPerMillionTokens: Double?
    public var outputPerMillionTokens: Double?
    public var cacheWritePerMillionTokens: Double?
    public var cacheReadPerMillionTokens: Double?
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
    case input
    case output
    case cacheWrite
    case cacheRead

    public var localizedTitle: String {
        switch self {
        case .input:
            return NSLocalizedString("输入", comment: "Cost component input title")
        case .output:
            return NSLocalizedString("输出", comment: "Cost component output title")
        case .cacheWrite:
            return NSLocalizedString("缓存创建", comment: "Cost component cache write title")
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
    public var currencySymbol: String
    public var totalCost: Double
    public var tierBasisTokens: Int
    public var tierMinimumTokens: Int?
    public var components: [MessageCostComponent]
    public var isEstimatedFromCurrentPricing: Bool

    public init(
        currencySymbol: String,
        totalCost: Double,
        tierBasisTokens: Int,
        tierMinimumTokens: Int?,
        components: [MessageCostComponent],
        isEstimatedFromCurrentPricing: Bool = false
    ) {
        let trimmedCurrency = currencySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currencySymbol = trimmedCurrency.isEmpty ? ModelPricing.defaultCurrencySymbol : trimmedCurrency
        self.totalCost = max(0, totalCost)
        self.tierBasisTokens = max(0, tierBasisTokens)
        self.tierMinimumTokens = tierMinimumTokens.map { max(0, $0) }
        self.components = components.filter { $0.tokens > 0 && $0.pricePerMillionTokens >= 0 }
        self.isEstimatedFromCurrentPricing = isEstimatedFromCurrentPricing
    }

    public var hasCost: Bool {
        !components.isEmpty
    }
}

public enum ModelCostCalculator {
    public static func tierBasisTokens(for usage: MessageTokenUsage) -> Int {
        max(0, usage.promptTokens ?? 0)
            + max(0, usage.cacheWriteTokens ?? 0)
            + max(0, usage.cacheReadTokens ?? 0)
    }

    public static func estimateCost(
        usage: MessageTokenUsage?,
        pricing: ModelPricing?,
        isEstimatedFromCurrentPricing: Bool = false
    ) -> MessageCostEstimate? {
        guard let usage, usage.hasAnyData, let pricing = pricing?.normalized, !pricing.isEffectivelyEmpty else {
            return nil
        }

        let effective = pricing.effectivePrices(for: usage)
        var components: [MessageCostComponent] = []

        appendComponent(
            kind: .input,
            tokens: usage.promptTokens,
            pricePerMillionTokens: effective.inputPerMillionTokens,
            to: &components
        )
        appendComponent(
            kind: .output,
            tokens: usage.completionTokens,
            pricePerMillionTokens: effective.outputPerMillionTokens,
            to: &components
        )
        appendComponent(
            kind: .cacheWrite,
            tokens: usage.cacheWriteTokens,
            pricePerMillionTokens: effective.cacheWritePerMillionTokens,
            to: &components
        )
        appendComponent(
            kind: .cacheRead,
            tokens: usage.cacheReadTokens,
            pricePerMillionTokens: effective.cacheReadPerMillionTokens,
            to: &components
        )

        guard !components.isEmpty else { return nil }
        let total = components.reduce(0) { $0 + $1.subtotal }
        return MessageCostEstimate(
            currencySymbol: effective.currencySymbol,
            totalCost: total,
            tierBasisTokens: effective.tierBasisTokens,
            tierMinimumTokens: effective.tierMinimumTokens,
            components: components,
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
}

public enum MessageCostResolver {
    public static func resolvedCost(
        for message: ChatMessage,
        providers: [Provider]
    ) -> MessageCostEstimate? {
        if let snapshot = message.costEstimate, snapshot.hasCost {
            return snapshot
        }
        guard let usage = message.tokenUsage,
              let modelReference = message.modelReference,
              let pricing = matchingPricing(for: modelReference, providers: providers) else {
            return nil
        }
        return ModelCostCalculator.estimateCost(
            usage: usage,
            pricing: pricing,
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

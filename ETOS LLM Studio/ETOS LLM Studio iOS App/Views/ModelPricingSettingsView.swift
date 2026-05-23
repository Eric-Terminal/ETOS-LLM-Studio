// ============================================================================
// ModelPricingSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 端模型本地价格设置。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ModelPricingSettingsView: View {
    @Binding var pricing: ModelPricing?
    @State private var draft = ModelPricingDraft()

    var body: some View {
        Form {
            Section(
                header: Text(NSLocalizedString("基础价格", comment: "Model pricing base price section")),
                footer: Text(NSLocalizedString("价格单位为每 1M tokens。留空表示这类 token 不参与费用估算。", comment: "Model pricing unit hint"))
            ) {
                TextField(NSLocalizedString("货币符号", comment: "Currency symbol field"), text: $draft.currencySymbol)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                ModelPricingTextField(
                    title: NSLocalizedString("输入价格", comment: "Input token price"),
                    text: $draft.inputPrice
                )
                ModelPricingTextField(
                    title: NSLocalizedString("输出价格", comment: "Output token price"),
                    text: $draft.outputPrice
                )
                ModelPricingTextField(
                    title: NSLocalizedString("缓存创建价格", comment: "Cache write token price"),
                    text: $draft.cacheWritePrice
                )
                ModelPricingTextField(
                    title: NSLocalizedString("缓存命中价格", comment: "Cache read token price"),
                    text: $draft.cacheReadPrice
                )
            }

            Section(
                header: Text(NSLocalizedString("阶梯价格", comment: "Tiered model pricing section")),
                footer: Text(NSLocalizedString("阶梯依据为输入 Tokens + 缓存创建 Tokens + 缓存命中 Tokens。命中某个起始值后，整条请求使用该档位价格；阶梯留空的价格继承基础价格。", comment: "Tiered pricing rule hint"))
            ) {
                if draft.tiers.isEmpty {
                    Text(NSLocalizedString("当前没有阶梯价格。", comment: "No tiered pricing empty state"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedTierBindings, id: \.wrappedValue.id) { tierBinding in
                        NavigationLink {
                            ModelPricingTierSettingsView(tier: tierBinding)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                let tier = tierBinding.wrappedValue
                                Text(tierRangeTitle(tier))
                                Text(tierSubtitle(tier))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteTiers)
                }

                Button {
                    draft.tiers.append(ModelPricingTierDraft())
                } label: {
                    Label(NSLocalizedString("添加阶梯", comment: "Add pricing tier button"), systemImage: "plus")
                }
            }

            Section {
                Button(role: .destructive) {
                    draft = ModelPricingDraft()
                    persistDraft()
                } label: {
                    Label(NSLocalizedString("清空价格设置", comment: "Clear pricing settings button"), systemImage: "trash")
                }
                .disabled(draft.isEmpty)
            }
        }
        .navigationTitle(NSLocalizedString("价格设置", comment: "Model pricing settings title"))
        .onAppear {
            draft = ModelPricingDraft(pricing: pricing)
        }
        .onDisappear {
            persistDraft()
        }
        .onChange(of: draft) { _, _ in
            persistDraft()
        }
    }

    private func persistDraft() {
        pricing = draft.modelPricing
    }

    private func deleteTiers(at offsets: IndexSet) {
        let orderedIndices = sortedTierIndices
        let removingIDs: [UUID] = offsets.compactMap { offset in
            guard orderedIndices.indices.contains(offset) else { return nil }
            return draft.tiers[orderedIndices[offset]].id
        }
        draft.tiers.removeAll { removingIDs.contains($0.id) }
        persistDraft()
    }

    private var sortedTierBindings: [Binding<ModelPricingTierDraft>] {
        sortedTierIndices.map { $draft.tiers[$0] }
    }

    private var sortedTierIndices: [Int] {
        draft.tiers.indices.sorted {
            let lhs = draft.tiers[$0]
            let rhs = draft.tiers[$1]
            if lhs.minimumTokenValue == rhs.minimumTokenValue {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.minimumTokenValue < rhs.minimumTokenValue
        }
    }

    private func tierRangeTitle(_ tier: ModelPricingTierDraft) -> String {
        ModelPricingTierRangeText.text(
            minimumTokens: tier.minimumTokenValue,
            nextMinimumTokens: nextTierMinimum(after: tier)
        )
    }

    private func tierSubtitle(_ tier: ModelPricingTierDraft) -> String {
        guard tier.hasAnyPrice else {
            return NSLocalizedString("未填写价格，将不会保存", comment: "Empty pricing tier hint")
        }
        let priceParts = [
            priceSummary(title: NSLocalizedString("输入", comment: "Cost component input title"), text: tier.inputPrice, inheritedText: draft.inputPrice),
            priceSummary(title: NSLocalizedString("输出", comment: "Cost component output title"), text: tier.outputPrice, inheritedText: draft.outputPrice),
            priceSummary(title: NSLocalizedString("缓存创建", comment: "Cost component cache write title"), text: tier.cacheWritePrice, inheritedText: draft.cacheWritePrice),
            priceSummary(title: NSLocalizedString("缓存命中", comment: "Cost component cache read title"), text: tier.cacheReadPrice, inheritedText: draft.cacheReadPrice)
        ].compactMap { $0 }
        if priceParts.isEmpty {
            return NSLocalizedString("未填写价格，将不会保存", comment: "Empty pricing tier hint")
        }
        return priceParts.joined(separator: " • ")
    }

    private func priceSummary(title: String, text: String, inheritedText: String) -> String? {
        let price = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedPrice = inheritedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrice = price.isEmpty ? inheritedPrice : price
        guard !effectivePrice.isEmpty else { return nil }
        let currency = draft.currencySymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = "\(currency.isEmpty ? ModelPricing.defaultCurrencySymbol : currency)\(effectivePrice)"
        return String(format: NSLocalizedString("%@：%@", comment: "Label value pair"), title, value)
    }

    private func nextTierMinimum(after tier: ModelPricingTierDraft) -> Int? {
        let orderedTiers = draft.tiers
            .map { ($0.id, $0.minimumTokenValue) }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.uuidString < $1.0.uuidString
                }
                return $0.1 < $1.1
            }
        guard let index = orderedTiers.firstIndex(where: { $0.0 == tier.id }) else {
            return nil
        }
        let minimum = orderedTiers[index].1
        return orderedTiers.dropFirst(index + 1).map(\.1).first { $0 > minimum }
    }
}

private struct ModelPricingTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.decimalPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

private struct ModelPricingTierSettingsView: View {
    @Binding var tier: ModelPricingTierDraft

    var body: some View {
        Form {
            Section(
                header: Text(NSLocalizedString("阶梯条件", comment: "Pricing tier condition section")),
                footer: Text(NSLocalizedString("达到这个 token 数后，整条请求使用该档位价格。", comment: "Pricing tier threshold hint"))
            ) {
                TextField(NSLocalizedString("起始 Tokens", comment: "Pricing tier minimum tokens field"), text: $tier.minimumTokens)
                    .keyboardType(.numberPad)
            }

            Section(
                header: Text(NSLocalizedString("阶梯价格", comment: "Pricing tier prices section")),
                footer: Text(NSLocalizedString("留空时继承基础价格。", comment: "Tier price inherit hint"))
            ) {
                ModelPricingTextField(
                    title: NSLocalizedString("输入价格", comment: "Input token price"),
                    text: $tier.inputPrice
                )
                ModelPricingTextField(
                    title: NSLocalizedString("输出价格", comment: "Output token price"),
                    text: $tier.outputPrice
                )
                ModelPricingTextField(
                    title: NSLocalizedString("缓存创建价格", comment: "Cache write token price"),
                    text: $tier.cacheWritePrice
                )
                ModelPricingTextField(
                    title: NSLocalizedString("缓存命中价格", comment: "Cache read token price"),
                    text: $tier.cacheReadPrice
                )
            }
        }
        .navigationTitle(NSLocalizedString("阶梯价格", comment: "Pricing tier detail title"))
    }
}

struct ModelPricingDraft: Equatable {
    var currencySymbol: String = ModelPricing.defaultCurrencySymbol
    var inputPrice: String = ""
    var outputPrice: String = ""
    var cacheWritePrice: String = ""
    var cacheReadPrice: String = ""
    var tiers: [ModelPricingTierDraft] = []

    nonisolated init() {}

    nonisolated init(pricing: ModelPricing?) {
        let pricing = pricing?.normalized
        currencySymbol = pricing?.currencySymbol ?? ModelPricing.defaultCurrencySymbol
        inputPrice = Self.string(from: pricing?.inputPerMillionTokens)
        outputPrice = Self.string(from: pricing?.outputPerMillionTokens)
        cacheWritePrice = Self.string(from: pricing?.cacheWritePerMillionTokens)
        cacheReadPrice = Self.string(from: pricing?.cacheReadPerMillionTokens)
        tiers = pricing?.tiers.map { ModelPricingTierDraft(tier: $0) } ?? []
    }

    nonisolated var isEmpty: Bool {
        modelPricing == nil
    }

    nonisolated var modelPricing: ModelPricing? {
        let normalized = ModelPricing(
            currencySymbol: currencySymbol,
            inputPerMillionTokens: Self.double(from: inputPrice),
            outputPerMillionTokens: Self.double(from: outputPrice),
            cacheWritePerMillionTokens: Self.double(from: cacheWritePrice),
            cacheReadPerMillionTokens: Self.double(from: cacheReadPrice),
            tiers: tiers.compactMap(\.modelPricingTier)
        )
        return normalized.isEffectivelyEmpty ? nil : normalized
    }

    nonisolated static func double(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed).flatMap(ModelPricing.normalizedPrice)
    }

    nonisolated static func string(from value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", value).trimmingTrailingZerosForPrice()
    }
}

struct ModelPricingTierDraft: Identifiable, Equatable {
    var id: UUID = UUID()
    var minimumTokens: String = ""
    var inputPrice: String = ""
    var outputPrice: String = ""
    var cacheWritePrice: String = ""
    var cacheReadPrice: String = ""

    nonisolated init() {}

    nonisolated init(tier: ModelPricingTier) {
        id = tier.id
        minimumTokens = "\(tier.minimumTokens)"
        inputPrice = ModelPricingDraft.string(from: tier.inputPerMillionTokens)
        outputPrice = ModelPricingDraft.string(from: tier.outputPerMillionTokens)
        cacheWritePrice = ModelPricingDraft.string(from: tier.cacheWritePerMillionTokens)
        cacheReadPrice = ModelPricingDraft.string(from: tier.cacheReadPerMillionTokens)
    }

    nonisolated var minimumTokenValue: Int {
        max(0, Int(minimumTokens.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    nonisolated var hasAnyPrice: Bool {
        !inputPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !outputPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !cacheWritePrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !cacheReadPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated var modelPricingTier: ModelPricingTier? {
        let tier = ModelPricingTier(
            id: id,
            minimumTokens: minimumTokenValue,
            inputPerMillionTokens: ModelPricingDraft.double(from: inputPrice),
            outputPerMillionTokens: ModelPricingDraft.double(from: outputPrice),
            cacheWritePerMillionTokens: ModelPricingDraft.double(from: cacheWritePrice),
            cacheReadPerMillionTokens: ModelPricingDraft.double(from: cacheReadPrice)
        )
        return tier.isEffectivelyEmpty ? nil : tier
    }
}

private extension String {
    nonisolated func trimmingTrailingZerosForPrice() -> String {
        var value = self
        while value.contains("."), value.last == "0" {
            value.removeLast()
        }
        if value.last == "." {
            value.removeLast()
        }
        return value
    }
}

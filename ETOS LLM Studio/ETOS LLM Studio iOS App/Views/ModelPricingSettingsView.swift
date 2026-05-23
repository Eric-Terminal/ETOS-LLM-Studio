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
                    ForEach($draft.tiers) { $tier in
                        NavigationLink {
                            ModelPricingTierSettingsView(tier: $tier)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tierTitle(tier))
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
        draft.tiers.remove(atOffsets: offsets)
        persistDraft()
    }

    private func tierTitle(_ tier: ModelPricingTierDraft) -> String {
        let minimum = Int(tier.minimumTokens) ?? 0
        return String(
            format: NSLocalizedString("从 %d tokens 起", comment: "Pricing tier minimum token title"),
            max(0, minimum)
        )
    }

    private func tierSubtitle(_ tier: ModelPricingTierDraft) -> String {
        let filledCount = [
            tier.inputPrice,
            tier.outputPrice,
            tier.cacheWritePrice,
            tier.cacheReadPrice
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        if filledCount == 0 {
            return NSLocalizedString("未填写价格，将不会保存", comment: "Empty pricing tier hint")
        }
        return String(
            format: NSLocalizedString("已填写 %d 项价格", comment: "Pricing tier filled price count"),
            filledCount
        )
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

    nonisolated var modelPricingTier: ModelPricingTier? {
        let tier = ModelPricingTier(
            id: id,
            minimumTokens: Int(minimumTokens.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
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

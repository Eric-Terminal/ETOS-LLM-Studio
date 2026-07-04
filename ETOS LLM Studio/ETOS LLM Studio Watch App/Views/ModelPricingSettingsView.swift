// ============================================================================
// ModelPricingSettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 模型本地价格设置
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct ModelPricingSettingsView: View {
    @Binding var pricing: ModelPricing?
    @State private var draft = ModelPricingDraft()

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("计费方式", comment: "Model pricing billing mode section")),
                footer: Text(NSLocalizedString("按 Token 时继续使用输入、输出和缓存 token 单价；按次时每条模型请求使用固定价格。", comment: "Model pricing billing mode footer"))
            ) {
                Picker(NSLocalizedString("计费方式", comment: "Model pricing billing mode picker"), selection: $draft.billingMode) {
                    ForEach(ModelPricingBillingMode.allCases, id: \.self) { mode in
                        Text(mode.localizedTitle)
                            .tag(mode)
                    }
                }
            }

            if draft.billingMode == .perRequest {
                Section(
                    header: Text(NSLocalizedString("按次价格", comment: "Per-request pricing section")),
                    footer: Text(NSLocalizedString("按次计费每条模型请求只计算一次固定价格，不依赖服务商是否返回 token 用量。", comment: "Per-request pricing footer"))
                ) {
                    ModelPricingTextField(title: NSLocalizedString("每次请求价格", comment: "Per-request price field"), text: $draft.perRequestPrice)
                }
            } else {
                Section(
                    header: Text(NSLocalizedString("基础价格", comment: "Model pricing base price section")),
                    footer: Text(NSLocalizedString("单位为每 1M tokens，留空表示不参与估算。", comment: "Watch model pricing unit hint"))
                ) {
                    ModelPricingTextField(title: NSLocalizedString("输入价格", comment: "Input token price"), text: $draft.inputPrice)
                    ModelPricingTextField(title: NSLocalizedString("输出价格", comment: "Output token price"), text: $draft.outputPrice)
                    ModelPricingTextField(title: NSLocalizedString("缓存创建价格", comment: "Cache write token price"), text: $draft.cacheWritePrice)
                    ModelPricingTextField(title: NSLocalizedString("缓存命中价格", comment: "Cache read token price"), text: $draft.cacheReadPrice)
                }

                Section(
                    header: Text(NSLocalizedString("阶梯价格", comment: "Tiered model pricing section")),
                    footer: Text(NSLocalizedString("阶梯依据为输入 + 缓存创建 + 缓存命中。阶梯空价格继承基础价格。", comment: "Watch tiered pricing rule hint"))
                ) {
                    ForEach(sortedTierBindings, id: \.wrappedValue.id) { tierBinding in
                        NavigationLink {
                            ModelPricingTierSettingsView(tier: tierBinding)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                let tier = tierBinding.wrappedValue
                                Text(tierRangeTitle(tier))
                                Text(tierSubtitle(tier))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteTiers)

                    Button {
                        draft.tiers.append(ModelPricingTierDraft())
                    } label: {
                        Label(NSLocalizedString("添加阶梯", comment: "Add pricing tier button"), systemImage: "plus")
                    }
                }

                Section(
                    header: Text(NSLocalizedString("峰谷定价", comment: "Peak valley pricing section")),
                    footer: Text(NSLocalizedString("默认关闭；开启后，只在命中的每日时间段覆盖价格，其他时间仍按基础/阶梯价格估算。", comment: "Peak valley pricing section footer"))
                ) {
                    Toggle(NSLocalizedString("启用峰谷定价", comment: "Enable peak valley pricing toggle"), isOn: $draft.timeOverridesEnabled)

                    if draft.timeOverridesEnabled {
                        NavigationLink {
                            ModelPricingTimeOverridesView(draft: $draft)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NSLocalizedString("时间段价格", comment: "Peak valley time range prices row"))
                                Text(timeOverridesSummary)
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if !draft.timeOverrides.isEmpty {
                        LabeledContent(NSLocalizedString("时间段价格", comment: "Peak valley time range prices row")) {
                            Text(NSLocalizedString("峰谷已关闭", comment: "Peak valley pricing disabled summary"))
                                .foregroundStyle(.secondary)
                        }
                    }
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
        .onChange(of: draft, initial: false) { _, _ in
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
        return priceParts.isEmpty
            ? NSLocalizedString("未填写价格，将不会保存", comment: "Empty pricing tier hint")
            : priceParts.joined(separator: " • ")
    }

    private func priceSummary(title: String, text: String, inheritedText: String) -> String? {
        let price = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedPrice = inheritedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrice = price.isEmpty ? inheritedPrice : price
        guard !effectivePrice.isEmpty else { return nil }
        return String(format: NSLocalizedString("%@：%@", comment: "Label value pair"), title, effectivePrice)
    }

    private var timeOverridesSummary: String {
        let savedTimeOverrideCount = draft.timeOverrides.compactMap(\.modelPricingTimeOverride).count
        guard savedTimeOverrideCount > 0 else {
            return NSLocalizedString("未配置", comment: "Model pricing not configured summary")
        }
        return String(
            format: NSLocalizedString("%d 个峰谷时段", comment: "Peak valley pricing ranges summary"),
            savedTimeOverrideCount
        )
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
        TextField(title, text: $text.watchKeyboardNewlineBinding())
    }
}

private struct ModelPricingTierSettingsView: View {
    @Binding var tier: ModelPricingTierDraft

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("阶梯条件", comment: "Pricing tier condition section")),
                footer: Text(NSLocalizedString("达到这个 token 数后，整条请求使用该档位价格。", comment: "Pricing tier threshold hint"))
            ) {
                TextField(NSLocalizedString("起始 Tokens", comment: "Pricing tier minimum tokens field"), text: $tier.minimumTokens.watchKeyboardNewlineBinding())
            }

            Section(
                header: Text(NSLocalizedString("阶梯价格", comment: "Pricing tier prices section")),
                footer: Text(NSLocalizedString("留空时继承基础价格。", comment: "Tier price inherit hint"))
            ) {
                ModelPricingTextField(title: NSLocalizedString("输入价格", comment: "Input token price"), text: $tier.inputPrice)
                ModelPricingTextField(title: NSLocalizedString("输出价格", comment: "Output token price"), text: $tier.outputPrice)
                ModelPricingTextField(title: NSLocalizedString("缓存创建价格", comment: "Cache write token price"), text: $tier.cacheWritePrice)
                ModelPricingTextField(title: NSLocalizedString("缓存命中价格", comment: "Cache read token price"), text: $tier.cacheReadPrice)
            }
        }
        .navigationTitle(NSLocalizedString("阶梯价格", comment: "Pricing tier detail title"))
    }
}

private struct ModelPricingTimeOverridesView: View {
    @Binding var draft: ModelPricingDraft

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("峰谷时间段", comment: "Peak valley pricing ranges section")),
                footer: Text(NSLocalizedString("时间段命中后只覆盖这里填写的价格；未填写的项目继续继承基础价格和已命中的阶梯价格。", comment: "Peak valley pricing ranges footer"))
            ) {
                ForEach(sortedTimeOverrideBindings, id: \.wrappedValue.id) { timeOverrideBinding in
                    NavigationLink {
                        ModelPricingTimeOverrideSettingsView(timeOverride: timeOverrideBinding)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            let timeOverride = timeOverrideBinding.wrappedValue
                            Text(timeRangeTitle(timeOverride))
                            Text(timeOverrideSubtitle(timeOverride))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: deleteTimeOverrides)

                if draft.timeOverrides.isEmpty {
                    Text(NSLocalizedString("当前没有峰谷时间段。", comment: "No peak valley pricing ranges empty state"))
                        .foregroundStyle(.secondary)
                }

                Button {
                    draft.timeOverrides.append(ModelPricingTimeOverrideDraft())
                } label: {
                    Label(NSLocalizedString("添加时间段", comment: "Add peak valley pricing range button"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(NSLocalizedString("峰谷定价", comment: "Peak valley pricing title"))
    }

    private var sortedTimeOverrideBindings: [Binding<ModelPricingTimeOverrideDraft>] {
        sortedTimeOverrideIndices.map { $draft.timeOverrides[$0] }
    }

    private var sortedTimeOverrideIndices: [Int] {
        draft.timeOverrides.indices.sorted {
            let lhs = draft.timeOverrides[$0]
            let rhs = draft.timeOverrides[$1]
            if lhs.startMinuteOfDay == rhs.startMinuteOfDay {
                if lhs.endMinuteOfDay == rhs.endMinuteOfDay {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.endMinuteOfDay < rhs.endMinuteOfDay
            }
            return lhs.startMinuteOfDay < rhs.startMinuteOfDay
        }
    }

    private func deleteTimeOverrides(at offsets: IndexSet) {
        let orderedIndices = sortedTimeOverrideIndices
        let removingIDs: [UUID] = offsets.compactMap { offset in
            guard orderedIndices.indices.contains(offset) else { return nil }
            return draft.timeOverrides[orderedIndices[offset]].id
        }
        draft.timeOverrides.removeAll { removingIDs.contains($0.id) }
    }

    private func timeRangeTitle(_ timeOverride: ModelPricingTimeOverrideDraft) -> String {
        ModelPricingTimeRangeText.text(
            startMinuteOfDay: timeOverride.startMinuteOfDay,
            endMinuteOfDay: timeOverride.endMinuteOfDay
        )
    }

    private func timeOverrideSubtitle(_ timeOverride: ModelPricingTimeOverrideDraft) -> String {
        guard timeOverride.isValidTimeWindow else {
            return NSLocalizedString("时间段不能相同", comment: "Invalid peak valley pricing range hint")
        }
        guard timeOverride.hasAnyPrice else {
            return NSLocalizedString("未填写价格，将不会保存", comment: "Empty pricing tier hint")
        }
        let priceParts = [
            priceSummary(title: NSLocalizedString("输入", comment: "Cost component input title"), text: timeOverride.inputPrice, inheritedText: draft.inputPrice),
            priceSummary(title: NSLocalizedString("输出", comment: "Cost component output title"), text: timeOverride.outputPrice, inheritedText: draft.outputPrice),
            priceSummary(title: NSLocalizedString("缓存创建", comment: "Cost component cache write title"), text: timeOverride.cacheWritePrice, inheritedText: draft.cacheWritePrice),
            priceSummary(title: NSLocalizedString("缓存命中", comment: "Cost component cache read title"), text: timeOverride.cacheReadPrice, inheritedText: draft.cacheReadPrice)
        ].compactMap { $0 }
        return priceParts.isEmpty
            ? NSLocalizedString("未填写价格，将不会保存", comment: "Empty pricing tier hint")
            : priceParts.joined(separator: " • ")
    }

    private func priceSummary(title: String, text: String, inheritedText: String) -> String? {
        let price = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inheritedPrice = inheritedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrice = price.isEmpty ? inheritedPrice : price
        guard !effectivePrice.isEmpty else { return nil }
        return String(format: NSLocalizedString("%@：%@", comment: "Label value pair"), title, effectivePrice)
    }
}

private struct ModelPricingTimeOverrideSettingsView: View {
    @Binding var timeOverride: ModelPricingTimeOverrideDraft

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("峰谷时间段", comment: "Peak valley pricing time range section")),
                footer: Text(NSLocalizedString("时间段不能相同；跨午夜时间段会自动延续到次日。", comment: "Peak valley pricing time range footer"))
            ) {
                DatePicker(
                    NSLocalizedString("开始时间", comment: ""),
                    selection: startTimeBinding,
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    NSLocalizedString("结束时间", comment: ""),
                    selection: endTimeBinding,
                    displayedComponents: .hourAndMinute
                )
            }

            Section(
                header: Text(NSLocalizedString("覆盖价格", comment: "Peak valley override prices section")),
                footer: Text(NSLocalizedString("留空时继承基础价格和已命中的阶梯价格。", comment: "Peak valley override prices footer"))
            ) {
                ModelPricingTextField(title: NSLocalizedString("输入价格", comment: "Input token price"), text: $timeOverride.inputPrice)
                ModelPricingTextField(title: NSLocalizedString("输出价格", comment: "Output token price"), text: $timeOverride.outputPrice)
                ModelPricingTextField(title: NSLocalizedString("缓存创建价格", comment: "Cache write token price"), text: $timeOverride.cacheWritePrice)
                ModelPricingTextField(title: NSLocalizedString("缓存命中价格", comment: "Cache read token price"), text: $timeOverride.cacheReadPrice)
            }
        }
        .navigationTitle(NSLocalizedString("峰谷价格", comment: "Peak valley pricing detail title"))
    }

    private var startTimeBinding: Binding<Date> {
        Binding(
            get: { ModelPricingTimeOverrideDraft.date(fromMinuteOfDay: timeOverride.startMinuteOfDay) },
            set: { timeOverride.startMinuteOfDay = ModelPricingTimeOverrideDraft.minuteOfDay(from: $0) }
        )
    }

    private var endTimeBinding: Binding<Date> {
        Binding(
            get: { ModelPricingTimeOverrideDraft.date(fromMinuteOfDay: timeOverride.endMinuteOfDay) },
            set: { timeOverride.endMinuteOfDay = ModelPricingTimeOverrideDraft.minuteOfDay(from: $0) }
        )
    }
}

struct ModelPricingDraft: Equatable {
    var billingMode: ModelPricingBillingMode = .token
    var perRequestPrice: String = ""
    var inputPrice: String = ""
    var outputPrice: String = ""
    var cacheWritePrice: String = ""
    var cacheReadPrice: String = ""
    var tiers: [ModelPricingTierDraft] = []
    var timeOverridesEnabled: Bool = false
    var timeOverrides: [ModelPricingTimeOverrideDraft] = []

    nonisolated init() {}

    nonisolated init(pricing: ModelPricing?) {
        let pricing = pricing?.normalized
        billingMode = pricing?.billingMode ?? .token
        perRequestPrice = Self.string(from: pricing?.perRequestPrice)
        inputPrice = Self.string(from: pricing?.inputPerMillionTokens)
        outputPrice = Self.string(from: pricing?.outputPerMillionTokens)
        cacheWritePrice = Self.string(from: pricing?.cacheWritePerMillionTokens)
        cacheReadPrice = Self.string(from: pricing?.cacheReadPerMillionTokens)
        tiers = pricing?.tiers.map { ModelPricingTierDraft(tier: $0) } ?? []
        timeOverridesEnabled = pricing?.timeOverridesEnabled ?? false
        timeOverrides = pricing?.timeOverrides.map { ModelPricingTimeOverrideDraft(timeOverride: $0) } ?? []
    }

    nonisolated var isEmpty: Bool {
        billingMode == .token
            && perRequestPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && inputPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && outputPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cacheWritePrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cacheReadPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tiers.isEmpty
            && !timeOverridesEnabled
            && timeOverrides.isEmpty
    }

    nonisolated var modelPricing: ModelPricing? {
        let normalized = ModelPricing(
            inputPerMillionTokens: Self.double(from: inputPrice),
            outputPerMillionTokens: Self.double(from: outputPrice),
            cacheWritePerMillionTokens: Self.double(from: cacheWritePrice),
            cacheReadPerMillionTokens: Self.double(from: cacheReadPrice),
            tiers: tiers.compactMap(\.modelPricingTier),
            timeOverridesEnabled: timeOverridesEnabled,
            timeOverrides: timeOverrides.compactMap(\.modelPricingTimeOverride),
            billingMode: billingMode,
            perRequestPrice: Self.double(from: perRequestPrice)
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

struct ModelPricingTimeOverrideDraft: Identifiable, Equatable {
    var id: UUID = UUID()
    var startMinuteOfDay: Int = 0
    var endMinuteOfDay: Int = 60
    var inputPrice: String = ""
    var outputPrice: String = ""
    var cacheWritePrice: String = ""
    var cacheReadPrice: String = ""

    nonisolated init() {}

    nonisolated init(timeOverride: ModelPricingTimeOverride) {
        id = timeOverride.id
        startMinuteOfDay = timeOverride.startMinuteOfDay
        endMinuteOfDay = timeOverride.endMinuteOfDay
        inputPrice = ModelPricingDraft.string(from: timeOverride.inputPerMillionTokens)
        outputPrice = ModelPricingDraft.string(from: timeOverride.outputPerMillionTokens)
        cacheWritePrice = ModelPricingDraft.string(from: timeOverride.cacheWritePerMillionTokens)
        cacheReadPrice = ModelPricingDraft.string(from: timeOverride.cacheReadPerMillionTokens)
    }

    nonisolated var isValidTimeWindow: Bool {
        startMinuteOfDay != endMinuteOfDay
    }

    nonisolated var hasAnyPrice: Bool {
        !inputPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !outputPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !cacheWritePrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !cacheReadPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated var modelPricingTimeOverride: ModelPricingTimeOverride? {
        guard isValidTimeWindow else { return nil }
        let timeOverride = ModelPricingTimeOverride(
            id: id,
            startMinuteOfDay: startMinuteOfDay,
            endMinuteOfDay: endMinuteOfDay,
            inputPerMillionTokens: ModelPricingDraft.double(from: inputPrice),
            outputPerMillionTokens: ModelPricingDraft.double(from: outputPrice),
            cacheWritePerMillionTokens: ModelPricingDraft.double(from: cacheWritePrice),
            cacheReadPerMillionTokens: ModelPricingDraft.double(from: cacheReadPrice)
        )
        return timeOverride.isEffectivelyEmpty ? nil : timeOverride
    }

    nonisolated static func date(fromMinuteOfDay minute: Int) -> Date {
        let minute = ModelPricingTimeOverride.normalizedMinute(minute)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minute / 60, minute: minute % 60)) ?? Date()
    }

    nonisolated static func minuteOfDay(from date: Date) -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return ModelPricingTimeOverride.normalizedMinute((components.hour ?? 0) * 60 + (components.minute ?? 0))
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

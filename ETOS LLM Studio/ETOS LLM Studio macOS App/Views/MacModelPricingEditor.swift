import ETOSCore
import SwiftUI

struct MacModelPricingEditor: View {
    let modelID: UUID
    let pricing: ModelPricing?
    let apiFormat: String
    let onSave: (ModelPricing?) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var draft = MacModelPricingDraft()
    @State private var isBusy = true
    @State private var prepared = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?

    private var anthropic: Bool { ProviderAPIFormatFamily(apiFormat: apiFormat) == .anthropic }
    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-model-pricing-\(modelID)") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "model-pricing-\(modelID)", title: NSLocalizedString("价格设置", comment: ""),
                                         details: NSLocalizedString("Mac 模型价格草稿使用说明", comment: ""), documentID: "model-pricing")
                    Picker(NSLocalizedString("计费方式", comment: ""), selection: $draft.mode) {
                        ForEach(ModelPricingBillingMode.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
                    }
                } footer: {
                    Text(NSLocalizedString("模型修改先返回提供商草稿，保存提供商后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if draft.mode == .perRequest {
                    Section {
                        TextField(NSLocalizedString("每次请求价格", comment: ""), text: $draft.perRequest)
                    } footer: {
                        Text(NSLocalizedString("每条模型请求计费一次。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        MacModelPriceForm(prices: $draft.prices, anthropic: anthropic)
                    } header: { Text(NSLocalizedString("基础价格", comment: "")) } footer: {
                        Text(NSLocalizedString("价格单位为每 1M tokens。留空表示这类 token 不参与费用估算。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach($draft.tiers) { $tier in
                            NavigationLink {
                                MacModelPricingTierEditor(modelID: modelID, tier: $tier, anthropic: anthropic, editable: !isBusy)
                            } label: {
                                LabeledContent(NSLocalizedString("起始 Tokens", comment: ""), value: tier.minimumTokens)
                            }
                            .contextMenu { Button(NSLocalizedString("删除", comment: ""), role: .destructive) { draft.tiers.removeAll { $0.id == tier.id } } }
                        }
                        Button(NSLocalizedString("添加阶梯", comment: "")) { draft.tiers.append(.init()) }
                    } header: { Text(NSLocalizedString("阶梯价格", comment: "")) } footer: {
                        Text(NSLocalizedString("达到档位后，整次请求按该档价格估算。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Toggle(NSLocalizedString("启用峰谷定价", comment: ""), isOn: $draft.timeEnabled)
                        ForEach($draft.times) { $time in
                            NavigationLink {
                                MacModelPricingTimeEditor(modelID: modelID, time: $time, anthropic: anthropic, editable: !isBusy)
                            } label: {
                                HStack { Text(time.start); Image(systemName: "arrow.right").accessibilityHidden(true); Text(time.end) }.monospacedDigit()
                            }
                            .contextMenu { Button(NSLocalizedString("删除", comment: ""), role: .destructive) { draft.times.removeAll { $0.id == time.id } } }
                        }
                        Button(NSLocalizedString("添加时间段", comment: "")) { draft.times.append(.init()) }
                    } header: { Text(NSLocalizedString("峰谷定价", comment: "")) } footer: {
                        Text(NSLocalizedString("仅在指定的重复日和时间段覆盖价格。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(NSLocalizedString("清空价格设置", comment: ""), role: .destructive) { draft = MacModelPricingDraft() }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isBusy || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("价格设置", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isBusy) }
                ToolbarItem(placement: .confirmationAction) { Button(NSLocalizedString("完成", comment: "")) { save() }.disabled(isBusy || workspace.isRestoringData) }
            }
            .guideSettingsPageContext(id: pageID, title: NSLocalizedString("价格设置", comment: ""),
                                      documents: [GuideDocumentReference(id: "model-pricing", title: "Model Pricing")], settings: guideSettings)
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 520, minHeight: 580)
        .interactiveDismissDisabled(isBusy)
        .task {
            guard !prepared else { return }
            let pricing = pricing, format = apiFormat
            let value = await Task.detached { MacModelPricingDraft(pricing?.normalized(forAPIFormat: format)) }.value
            guard !Task.isCancelled else { return }
            draft = value; prepared = true; isBusy = false
        }
        .onDisappear { saveTask?.cancel() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("model_then_provider_draft_until_save") }),
            .readOnly("api_format", label: NSLocalizedString("API 格式", comment: ""), value: { .string(apiFormat) }),
            .readOnly("tier_count", label: NSLocalizedString("阶梯数量", comment: ""), value: { .int(draft.tiers.count) }),
            .readOnly("time_count", label: NSLocalizedString("峰谷时间段数量", comment: ""), value: { .int(draft.times.count) })
        ]
        guard !isBusy, !workspace.isRestoringData else { return fields }
        fields.append(.string("billing_mode", label: NSLocalizedString("计费方式", comment: ""), allowedValues: ModelPricingBillingMode.allCases.map(\.rawValue),
                              get: { draft.mode.rawValue }, set: { if let mode = ModelPricingBillingMode(rawValue: $0) { draft.mode = mode } }))
        if draft.mode == .perRequest {
            fields.append(MacModelPriceForm.setting("per_request", label: NSLocalizedString("每次请求价格", comment: ""), text: $draft.perRequest))
        } else {
            fields += MacModelPriceForm.settings($draft.prices, anthropic: anthropic)
            fields.append(.bool("time_enabled", label: NSLocalizedString("启用峰谷定价", comment: ""), get: { draft.timeEnabled }, set: { draft.timeEnabled = $0 }))
        }
        return fields
    }

    private func save() {
        guard !isBusy, !workspace.isRestoringData else { return }
        let source = draft, format = apiFormat
        isBusy = true
        saveTask = Task {
            defer { isBusy = false }
            do {
                let pricing = try await Task.detached { try source.pricing(apiFormat: format) }.value
                guard !Task.isCancelled, !workspace.isRestoringData, draft == source else { return }
                onSave(pricing)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct MacModelPricingTierEditor: View {
    let modelID: UUID
    @Binding var tier: MacModelPricingTierDraft
    let anthropic: Bool
    let editable: Bool

    var body: some View {
        Form {
            Section { TextField(NSLocalizedString("起始 Tokens", comment: ""), text: $tier.minimumTokens) }
            Section { MacModelPriceForm(prices: $tier.prices, anthropic: anthropic) } footer: {
                Text(NSLocalizedString("阶梯留空的价格继承基础价格。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!editable)
        .navigationTitle(NSLocalizedString("阶梯价格", comment: ""))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-model-pricing-\(modelID)-tier-\(tier.id)"), title: NSLocalizedString("阶梯价格", comment: ""),
            documents: [GuideDocumentReference(id: "model-pricing", title: "Model Pricing")], settings: [
                .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("pricing_draft_until_done") })
            ] + (editable ? [
                .string("minimum_tokens", label: NSLocalizedString("起始 Tokens", comment: ""), get: { tier.minimumTokens }, set: { tier.minimumTokens = $0 })
            ] + MacModelPriceForm.settings($tier.prices, anthropic: anthropic) : [])
        )
    }
}

private struct MacModelPricingTimeEditor: View {
    let modelID: UUID
    @Binding var time: MacModelPricingTimeDraft
    let anthropic: Bool
    let editable: Bool

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("开始时间", comment: ""), text: $time.start).monospacedDigit()
                TextField(NSLocalizedString("结束时间", comment: ""), text: $time.end).monospacedDigit()
            } footer: {
                Text(NSLocalizedString("Mac 峰谷时间输入说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(ModelPricingWeekday.allCases, id: \.self) { weekday in
                    Toggle(ModelPricingWeekdayText.title(for: weekday), isOn: Binding(get: { time.weekdays.contains(weekday) }, set: {
                        if $0 { time.weekdays.insert(weekday) } else { time.weekdays.remove(weekday) }
                    }))
                }
            } header: { Text(NSLocalizedString("重复日", comment: "")) }
            Section { MacModelPriceForm(prices: $time.prices, anthropic: anthropic) } footer: {
                Text(NSLocalizedString("Mac 峰谷价格继承说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(!editable)
        .navigationTitle(NSLocalizedString("峰谷价格", comment: ""))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-model-pricing-\(modelID)-time-\(time.id)"), title: NSLocalizedString("峰谷价格", comment: ""),
            documents: [GuideDocumentReference(id: "model-pricing", title: "Model Pricing")], settings: [
                .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("pricing_draft_until_done") })
            ] + (editable ? [
                .string("start_time", label: NSLocalizedString("开始时间", comment: ""), get: { time.start }, set: { time.start = $0 }),
                .string("end_time", label: NSLocalizedString("结束时间", comment: ""), get: { time.end }, set: { time.end = $0 }),
                .json("weekdays", label: NSLocalizedString("重复日", comment: ""), schema: GuideModelPricingSettingsSupport.weekdaysSchema,
                      get: { GuideModelPricingSettingsSupport.weekdaysValue(time.weekdays) }, normalize: GuideModelPricingSettingsSupport.normalizeWeekdays,
                      set: { time.weekdays = try GuideModelPricingSettingsSupport.weekdays(from: $0) })
            ] + MacModelPriceForm.settings($time.prices, anthropic: anthropic) : [])
        )
    }
}

/// 基础、阶梯和峰谷共用字段与向导定义，避免某一层遗漏缓存档位或空值语义。
private struct MacModelPriceForm: View {
    @Binding var prices: MacModelPriceFields
    let anthropic: Bool
    var body: some View {
        TextField(NSLocalizedString("输入价格", comment: ""), text: $prices.input)
        TextField(NSLocalizedString("输出价格", comment: ""), text: $prices.output)
        TextField(anthropic ? NSLocalizedString("缓存创建价格（5 分钟）", comment: "") : NSLocalizedString("缓存创建价格", comment: ""), text: $prices.cacheWrite)
        if anthropic { TextField(NSLocalizedString("缓存创建价格（1 小时）", comment: ""), text: $prices.cacheWriteOneHour) }
        TextField(NSLocalizedString("缓存命中价格", comment: ""), text: $prices.cacheRead)
    }

    static func settings(_ prices: Binding<MacModelPriceFields>, anthropic: Bool) -> [GuidePageSetting] {
        [setting("input_price", label: NSLocalizedString("输入价格", comment: ""), text: prices.input),
         setting("output_price", label: NSLocalizedString("输出价格", comment: ""), text: prices.output),
         setting("cache_write_price", label: anthropic ? NSLocalizedString("缓存创建价格（5 分钟）", comment: "") : NSLocalizedString("缓存创建价格", comment: ""), text: prices.cacheWrite),
         setting("cache_read_price", label: NSLocalizedString("缓存命中价格", comment: ""), text: prices.cacheRead)]
        + (anthropic ? [setting("cache_write_one_hour_price", label: NSLocalizedString("缓存创建价格（1 小时）", comment: ""), text: prices.cacheWriteOneHour)] : [])
    }

    static func setting(_ key: String, label: String, text: Binding<String>) -> GuidePageSetting {
        .json(key, label: label, schema: GuideModelPricingSettingsSupport.optionalPriceSchema,
              get: {
            do { return try MacModelPriceFields.price(text.wrappedValue).map(JSONValue.double) ?? .null }
            catch { return .string(text.wrappedValue) }
        }, normalize: GuideModelPricingSettingsSupport.normalizePrice,
              set: { value in
            // Double 的往返字符串不截断到固定小数位，保留很低的 Token 单价。
            switch try GuideModelPricingSettingsSupport.normalizePrice(value) {
            case .double(let price): text.wrappedValue = String(price)
            case .null: text.wrappedValue = ""
            default: throw GuideError.invalidToolArguments
            }
        })
    }
}

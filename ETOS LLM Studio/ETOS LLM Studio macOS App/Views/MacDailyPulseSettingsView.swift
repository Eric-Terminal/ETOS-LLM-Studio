import ETOSCore
import SwiftUI

@MainActor
struct MacDailyPulseSettingsView: View {
    @ObservedObject var model: MacDailyPulseModel
    @ObservedObject var manager: DailyPulseManager
    @ObservedObject var delivery: DailyPulseDeliveryCoordinator
    let snapshot: MacDailyPulsePresentation
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var notifications = AppLocalNotificationCenter.shared
    @State private var editingTime: MacDailyPulsePresentation.TimeRow?
    private var editable: Bool { isActive && model.canEdit && !model.isPreparing }

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("启用每日脉冲", comment: ""), isOn: $manager.isDailyPulseEnabled)
                Toggle(NSLocalizedString("每日首次打开自动补生成", comment: ""), isOn: $manager.autoGenerateEnabled)
                Picker(NSLocalizedString("每日脉冲模型", comment: ""), selection: $configuration.dailyPulseModelIdentifier) {
                    Text(NSLocalizedString("未选择（跟随当前对话模型）", comment: "")).tag("")
                    if !configuration.dailyPulseModelIdentifier.isEmpty,
                       !workspace.sessionModelCatalog.availableIDs.contains(configuration.dailyPulseModelIdentifier) {
                        Text(NSLocalizedString("已选模型不可用", comment: "")).tag(configuration.dailyPulseModelIdentifier)
                    }
                    ForEach(workspace.sessionModelCatalog.rows) { Text($0.title).tag($0.id) }
                }
            } footer: {
                Text(NSLocalizedString("关闭后不会再生成新的每日脉冲；已有卡片、任务和反馈记录仍会保留。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(NSLocalizedString("定时送达", comment: ""), isOn: $delivery.reminderEnabled)
                Stepper(value: Binding(get: { delivery.totalCardCount }, set: { delivery.setCardCount($0) }), in: 1...Int.max) {
                    LabeledContent(NSLocalizedString("卡片数量", comment: ""), value: String(delivery.totalCardCount))
                }
                ForEach(snapshot.times) { time in
                    Button { editingTime = time } label: { LabeledContent(time.title, value: time.time) }
                }
            } header: { Text(NSLocalizedString("主动送达", comment: "")) } footer: {
                Text(delivery.reminderStatusText).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField(NSLocalizedString("当前关注焦点", comment: ""), text: $manager.focusText, axis: .vertical).lineLimit(3...8)
                TextField(NSLocalizedString("明日想看什么", comment: ""), text: $manager.tomorrowCurationText, axis: .vertical).lineLimit(3...8)
            }
            Section {
                Toggle(NSLocalizedString("纳入 MCP 服务器能力", comment: ""), isOn: $manager.includeMCPContext)
                Toggle(NSLocalizedString("纳入快捷指令能力", comment: ""), isOn: $manager.includeShortcutContext)
                Toggle(NSLocalizedString("纳入最近外部结果", comment: ""), isOn: $manager.includeRecentExternalResults)
                Toggle(NSLocalizedString("纳入公告与趋势信号", comment: ""), isOn: $manager.includeTrendContext)
            }
        }
        .formStyle(.grouped)
        .disabled(!isActive || !model.canEdit)
        .task { await notifications.refreshAuthorizationStatus() }
        .sheet(item: $editingTime) { time in MacDailyPulseTimeEditor(model: model, original: time) }
        .onChange(of: isActive) { _, active in if !active { editingTime = nil } }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-daily-pulse-settings-\(model.revision)"),
            title: NSLocalizedString("每日脉冲", comment: ""),
            documents: [GuideDocumentReference(id: "daily-pulse", title: "Daily Pulse")], isActive: editable,
            settings: [
                .bool("enabled", label: NSLocalizedString("启用每日脉冲", comment: ""), get: { manager.isDailyPulseEnabled }, set: { manager.isDailyPulseEnabled = $0 }),
                .bool("auto_generate", label: NSLocalizedString("每日首次打开自动补生成", comment: ""), get: { manager.autoGenerateEnabled }, set: { manager.autoGenerateEnabled = $0 }),
                .bool("reminders", label: NSLocalizedString("定时送达", comment: ""), get: { delivery.reminderEnabled }, set: { delivery.reminderEnabled = $0 }),
                .integer("card_count", label: NSLocalizedString("卡片数量", comment: ""), range: 1...Int.max, get: { delivery.totalCardCount }, set: { delivery.setCardCount($0) }),
                .readOnly("delivery_times", label: NSLocalizedString("各卡片送达时间", comment: ""), value: { model.presentation?.guideTimes ?? .null }),
                .string("model", label: NSLocalizedString("每日脉冲模型", comment: ""), allowedValues: workspace.sessionModelCatalog.guideIDs,
                    get: { configuration.dailyPulseModelIdentifier }, set: { configuration.dailyPulseModelIdentifier = $0 }),
                .string("focus", label: NSLocalizedString("当前关注焦点", comment: ""), get: { manager.focusText }, set: { manager.focusText = $0 }),
                .string("curation", label: NSLocalizedString("明日想看什么", comment: ""), get: { manager.tomorrowCurationText }, set: { manager.tomorrowCurationText = $0 }),
                .bool("mcp_context", label: NSLocalizedString("纳入 MCP 服务器能力", comment: ""), get: { manager.includeMCPContext }, set: { manager.includeMCPContext = $0 }),
                .bool("shortcut_context", label: NSLocalizedString("纳入快捷指令能力", comment: ""), get: { manager.includeShortcutContext }, set: { manager.includeShortcutContext = $0 }),
                .bool("external_results", label: NSLocalizedString("纳入最近外部结果", comment: ""), get: { manager.includeRecentExternalResults }, set: { manager.includeRecentExternalResults = $0 }),
                .bool("trend_context", label: NSLocalizedString("纳入公告与趋势信号", comment: ""), get: { manager.includeTrendContext }, set: { manager.includeTrendContext = $0 })
            ])
    }
}

@MainActor
private struct MacDailyPulseTimeEditor: View {
    @ObservedObject var model: MacDailyPulseModel
    let original: MacDailyPulsePresentation.TimeRow
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var components: (hour: Int, minute: Int)?
    @State private var error: String?
    @State private var visible = false
    @State private var showsGuide = false
    @State private var confirmsRemoval = false
    private var available: Bool { visible && model.canEdit && !model.isPreparing }

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("送达时间", comment: ""), text: $draft).monospacedDigit()
                if components == nil {
                    Text(NSLocalizedString("时间格式不正确，请输入 00:00-23:59。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if (model.delivery?.totalCardCount ?? 0) > 1 {
                    Button(NSLocalizedString("删除卡片", comment: ""), role: .destructive) { confirmsRemoval = true }
                }
            }
            .formStyle(.grouped)
            .disabled(!available)
            .navigationTitle(NSLocalizedString("编辑卡片", comment: ""))
            .toolbar {
                Button { showsGuide.toggle() } label: { Label(NSLocalizedString("页面向导", comment: ""), systemImage: "sparkles") }
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(!available || components == nil)
            }
            .inspector(isPresented: $showsGuide) { MacGuideView().inspectorColumnWidth(min: 300, ideal: 360, max: 500) }
            .confirmationDialog(NSLocalizedString("删除卡片", comment: ""), isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                    guard available, model.delivery?.removeCard(id: original.id) == true else { return }
                    dismiss()
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-pulse-time-\(original.id)-\(model.revision)"),
                title: NSLocalizedString("编辑卡片", comment: ""),
                documents: [GuideDocumentReference(id: "daily-pulse", title: "Daily Pulse")], isActive: available,
                settings: [
                    .readOnly("manual_save_required", label: NSLocalizedString("保存", comment: ""), value: { .bool(true) }),
                    .readOnly("id", label: NSLocalizedString("送达时间 ID", comment: ""), value: { .string(original.id.uuidString) }),
                    .json("time_draft", label: NSLocalizedString("送达时间", comment: ""), schema: .dictionary(["type": .string("string")]),
                        get: { .string(draft) }, normalize: { value in
                            guard case .string(let text) = value,
                                  let parsed = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: text) else { throw GuideError.invalidToolArguments }
                            return .string(String(format: "%02d:%02d", parsed.hour, parsed.minute))
                        }, set: { value in
                            guard case .string(let text) = value else { throw GuideError.invalidToolArguments }
                            draft = text; components = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: text)
                        })
                ])
        }
        .frame(minWidth: 380, minHeight: 220)
        .onAppear { visible = true; draft = original.time; components = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: draft) }
        .onDisappear { visible = false }
        .onChange(of: draft) { _, text in components = DailyPulseDeliveryCoordinator.reminderTimeComponents(from: text) }
    }

    private func save() {
        guard available, let components else { return }
        guard model.presentation?.times.first(where: { $0.id == original.id })?.time == original.time,
              model.delivery?.updateDeliveryTime(id: original.id, hour: components.hour, minute: components.minute) == true else {
            error = NSLocalizedString("送达时间已变更，请重新打开编辑。", comment: "")
            return
        }
        dismiss()
    }
}

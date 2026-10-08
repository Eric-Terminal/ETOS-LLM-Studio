import ETOSCore
import SwiftUI

struct MacAppearanceScheduleEditor: View {
    @ObservedObject var model: MacAppearanceModel
    @State var rule: ChatAppearanceScheduleRule
    let catalog: MacAppearanceCatalog
    let epoch: UUID
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended && model.epoch == epoch }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "appearance-schedule", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 聊天配色使用说明", comment: ""), documentID: "settings-display", isActive: available)
                    Picker(NSLocalizedString("颜色配置", comment: ""), selection: $rule.profileID) {
                        ForEach(catalog.profiles) { Text($0.title).tag($0.id) }
                    }
                    DatePicker(NSLocalizedString("开始时间", comment: ""), selection: time($rule.startMinuteOfDay), displayedComponents: .hourAndMinute)
                    DatePicker(NSLocalizedString("结束时间", comment: ""), selection: time($rule.endMinuteOfDay), displayedComponents: .hourAndMinute)
                } footer: {
                    Text(NSLocalizedString("没有匹配时间段时会使用默认配置；时间段不能重叠。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            // 这里只编辑每日墙钟分钟，不把当前时区偏移写进数据库。
            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            .formStyle(.grouped).navigationTitle(NSLocalizedString("自动切换", comment: ""))
            .onAppear { visible = true }.onDisappear { visible = false }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-appearance-schedule-\(rule.id)-\(epoch)"),
                title: NSLocalizedString("自动切换", comment: ""), documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
                isActive: available && visible && !model.isSaving, settings: [
                    .string("profile_id", label: NSLocalizedString("颜色配置", comment: ""), allowedValues: catalog.profileIDs, allowsEmpty: false,
                            get: { rule.profileID }, set: { rule.profileID = $0 }),
                    .integer("start_minute", label: NSLocalizedString("开始时间", comment: ""), range: 0...1439, get: { rule.startMinuteOfDay }, set: { rule.startMinuteOfDay = $0 }),
                    .integer("end_minute", label: NSLocalizedString("结束时间", comment: ""), range: 0...1439, get: { rule.endMinuteOfDay }, set: { rule.endMinuteOfDay = $0 }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ])
        }
        .disabled(!available || model.isSaving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.isSaving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    Task { if await model.save(.schedule(rule), original: catalog.configuration, expectedEpoch: epoch) { dismiss() } }
                }.disabled(!available || !model.canEdit)
            }
        }
        .modifier(MacGuideInspector()).frame(minWidth: 480, minHeight: 380)
        .interactiveDismissDisabled(model.isSaving)
    }

    private func time(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(get: { Date(timeIntervalSinceReferenceDate: Double(minute.wrappedValue) * 60) },
                set: { minute.wrappedValue = ChatAppearanceScheduleRule.normalizedMinute(Int($0.timeIntervalSinceReferenceDate / 60)) })
    }
}

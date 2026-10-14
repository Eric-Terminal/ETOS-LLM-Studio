import ETOSCore
import SwiftUI

struct MacAppearanceSettingsView: View {
    @ObservedObject var model: MacAppearanceModel
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var visible = false
    @State private var profileTarget: ProfileTarget?
    @State private var scheduleTarget: ScheduleTarget?
    @State private var deleting: Deletion?
    private struct ProfileTarget: Identifiable { let id = UUID(); let profile: ChatAppearanceProfile; let catalog: MacAppearanceCatalog; let epoch: UUID }
    private struct ScheduleTarget: Identifiable { let id = UUID(); let rule: ChatAppearanceScheduleRule; let catalog: MacAppearanceCatalog; let epoch: UUID }
    private struct Deletion { let change: MacAppearanceChange; let original: ChatAppearanceProfileConfiguration; let epoch: UUID }
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "appearance", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 聊天配色使用说明", comment: ""), documentID: "settings-display", isActive: available)
                if let catalog = model.catalog {
                    LabeledContent(NSLocalizedString("当前生效配置", comment: ""), value: catalog.activeTitle)
                }
                Button(NSLocalizedString("刷新", comment: "")) { model.reload() }.disabled(model.isLoading || model.isSaving)
            }
            if model.isLoading || model.isSaving { ProgressView() }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if let catalog = model.catalog {
                Section {
                    ForEach(catalog.profiles) { profile in
                        HStack {
                            Button(profile.title) { edit(profile.value, catalog: catalog) }
                            Spacer()
                            Button { edit(profile.value.copied(name: NSLocalizedString("新颜色配置", comment: "")), catalog: catalog) } label: {
                                Label(NSLocalizedString("复制", comment: ""), systemImage: "doc.on.doc")
                            }
                            if !profile.value.isDefaultProfile {
                                Button(role: .destructive) {
                                    deleting = Deletion(change: .deleteProfile(profile.id), original: catalog.configuration, epoch: model.epoch)
                                } label: { Label(NSLocalizedString("删除", comment: ""), systemImage: "trash") }
                            }
                        }.buttonStyle(.borderless)
                    }
                    Button(NSLocalizedString("新增颜色配置", comment: "")) {
                        edit(catalog.defaultProfile.copied(name: NSLocalizedString("新颜色配置", comment: "")), catalog: catalog)
                    }
                } header: { Text(NSLocalizedString("颜色配置", comment: "")) }
                    .disabled(!model.canEdit)
                Section {
                    ForEach(catalog.schedules) { schedule in
                        HStack {
                            Button(schedule.title) { scheduleTarget = .init(rule: schedule.value, catalog: catalog, epoch: model.epoch) }
                            Spacer()
                            Button(role: .destructive) {
                                deleting = Deletion(change: .deleteSchedule(schedule.id), original: catalog.configuration, epoch: model.epoch)
                            } label: { Label(NSLocalizedString("删除", comment: ""), systemImage: "trash") }
                        }.buttonStyle(.borderless)
                    }
                    Button(NSLocalizedString("新增时间段", comment: "")) {
                        scheduleTarget = .init(rule: .init(profileID: ChatAppearanceProfile.defaultProfileID,
                            startMinuteOfDay: 9 * 60, endMinuteOfDay: 10 * 60), catalog: catalog, epoch: model.epoch)
                    }
                } header: { Text(NSLocalizedString("自动切换", comment: "")) } footer: {
                    Text(NSLocalizedString("没有匹配时间段时会使用默认配置；时间段不能重叠。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(!model.canEdit)
            }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("颜色配置", comment: "")).disabled(!available)
        .onAppear { visible = true; model.reload() }
        .onDisappear { visible = false }
        .onChange(of: model.epoch) { _, _ in profileTarget = nil; scheduleTarget = nil; deleting = nil }
        .onChange(of: available) { _, value in if !value { profileTarget = nil; scheduleTarget = nil; deleting = nil } }
        .sheet(item: $profileTarget) { target in
            MacAppearanceProfileEditor(model: model, profile: target.profile, original: target.catalog.configuration,
                epoch: target.epoch, isActive: available)
        }
        .sheet(item: $scheduleTarget) { target in
            MacAppearanceScheduleEditor(model: model, rule: target.rule, catalog: target.catalog, epoch: target.epoch, isActive: available)
        }
        .alert(NSLocalizedString("删除配置", comment: ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let target = deleting, available else { return }; deleting = nil
                Task { _ = await model.save(target.change, original: target.original, expectedEpoch: target.epoch) }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deleting = nil }
        } message: {
            switch deleting?.change {
            case .some(.deleteProfile(_)):
                Text(NSLocalizedString("删除颜色配置时，也会删除使用它的自动切换时间段。", comment: ""))
            default: Text(NSLocalizedString("确定删除这个时间段吗？", comment: ""))
            }
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-appearance-\(model.epoch)"),
            title: NSLocalizedString("颜色配置", comment: ""), documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
            isActive: available && visible && model.canEdit && profileTarget == nil && scheduleTarget == nil && deleting == nil,
            settings: [
                .readOnly("profiles", label: NSLocalizedString("可用颜色配置", comment: ""), value: { model.catalog?.guideValue ?? .array([]) }),
                .readOnly("active_profile", label: NSLocalizedString("当前生效配置", comment: ""), value: { .string(model.activeProfile.id) }),
                .readOnly("schedule_count", label: NSLocalizedString("自动切换", comment: ""), value: { .int(model.catalog?.schedules.count ?? 0) }),
                .readOnly("editing_requires_navigation", label: NSLocalizedString("编辑", comment: ""), value: { .bool(true) })
            ])
    }

    private func edit(_ profile: ChatAppearanceProfile, catalog: MacAppearanceCatalog) {
        profileTarget = .init(profile: profile, catalog: catalog, epoch: model.epoch)
    }
}

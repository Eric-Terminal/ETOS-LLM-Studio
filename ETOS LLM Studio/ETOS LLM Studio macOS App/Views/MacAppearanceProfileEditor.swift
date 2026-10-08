import ETOSCore
import SwiftUI

struct MacAppearanceProfileEditor: View {
    @ObservedObject var model: MacAppearanceModel
    @StateObject private var draft: MacAppearanceProfileDraft
    let original: ChatAppearanceProfileConfiguration
    let epoch: UUID
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended && model.epoch == epoch }

    init(model: MacAppearanceModel, profile: ChatAppearanceProfile, original: ChatAppearanceProfileConfiguration, epoch: UUID, isActive: Bool) {
        self.model = model; self.original = original; self.epoch = epoch; self.isActive = isActive
        _draft = StateObject(wrappedValue: MacAppearanceProfileDraft(profile))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "appearance-profile", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 聊天配色使用说明", comment: ""), documentID: "settings-display", isActive: available)
                    TextField(NSLocalizedString("名称", comment: ""), text: Binding(
                        get: { MacAppearanceCatalog.title(draft.profile) }, set: { draft.profile.name = $0 }))
                }
                Section { MacAppearanceColorField(slot: $draft.profile.userBubble) } header: { Text(NSLocalizedString("用户气泡", comment: "")) }
                Section { MacAppearanceColorField(slot: $draft.profile.assistantBubble) } header: { Text(NSLocalizedString("助手气泡", comment: "")) }
                Section {
                    ForEach(MacAppearanceTextGroup.allCases) { group in
                        NavigationLink(group.title) {
                            MacAppearanceTextStyleEditor(draft: draft, group: group, isActive: available && !model.isSaving && !draft.isWorking)
                        }
                    }
                } header: { Text(NSLocalizedString("文字颜色", comment: "")) }
                Section { Button(NSLocalizedString("恢复默认聊天颜色", comment: "")) { draft.reset() } }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped).navigationTitle(NSLocalizedString("颜色配置", comment: ""))
            .onAppear { visible = true }.onDisappear { visible = false }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-appearance-profile-\(draft.profile.id)-\(epoch)"),
                title: NSLocalizedString("颜色配置", comment: ""), documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
                isActive: available && visible && !model.isSaving && !draft.isWorking, settings: guideSettings)
        }
        .disabled(!available || model.isSaving || draft.isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.isSaving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    Task { if await model.save(.profile(draft.profile), original: original, expectedEpoch: epoch) { dismiss() } }
                }.disabled(!available || !model.canEdit || draft.isWorking)
            }
        }
        .modifier(MacGuideInspector()).frame(minWidth: 520, minHeight: 560)
        .interactiveDismissDisabled(model.isSaving)
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .string("name", label: NSLocalizedString("名称", comment: ""), allowsEmpty: false, get: { MacAppearanceCatalog.title(draft.profile) }, set: { draft.profile.name = $0 }),
            .bool("user_bubble_enabled", label: NSLocalizedString("自定义用户气泡颜色", comment: ""), get: { draft.profile.userBubble.isEnabled }, set: { draft.profile.userBubble.isEnabled = $0 }),
            .string("user_bubble_hex", label: NSLocalizedString("用户气泡", comment: ""), get: { draft.profile.userBubble.hex }, set: { draft.profile.userBubble.hex = $0 }),
            .bool("assistant_bubble_enabled", label: NSLocalizedString("自定义助手气泡颜色（含 Tool）", comment: ""), get: { draft.profile.assistantBubble.isEnabled }, set: { draft.profile.assistantBubble.isEnabled = $0 }),
            .string("assistant_bubble_hex", label: NSLocalizedString("助手气泡", comment: ""), get: { draft.profile.assistantBubble.hex }, set: { draft.profile.assistantBubble.hex = $0 }),
            .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) }),
            .readOnly("text_styles_require_navigation", label: NSLocalizedString("文字颜色", comment: ""), value: { .bool(true) })
        ]
    }
}

struct MacAppearanceColorField: View {
    @Binding var slot: ChatAppearanceColorSlot
    @StateObject private var draft = MacAppearanceColorDraft()
    var body: some View {
        Group {
            Toggle(NSLocalizedString("自定义颜色", comment: ""), isOn: $slot.isEnabled)
            if slot.isEnabled {
                ColorPicker(NSLocalizedString("颜色", comment: ""), selection: Binding(get: { draft.color }, set: {
                    if let hex = ChatAppearanceColorCodec.hexRGBA(from: $0) { slot.hex = hex }
                }), supportsOpacity: true)
                TextField(NSLocalizedString("十六进制颜色", comment: ""), text: $slot.hex)
            }
        }
        .onAppear { draft.update(slot.hex) }.onDisappear { draft.cancel() }
        .onChange(of: slot.hex) { _, value in draft.update(value) }
    }
}

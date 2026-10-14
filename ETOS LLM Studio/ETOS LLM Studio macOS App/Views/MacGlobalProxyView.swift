import ETOSCore
import SwiftUI

struct MacGlobalProxyView: View {
    @ObservedObject var model: MacGlobalProxyModel
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var visible = false
    @State private var showsPassword = false
    @State private var confirmsReload = false
    private var available: Bool { isActive && workspace.canManageLocalModels && !model.isSuspended && appLock.state != .locked }
    private var active: Bool { available && visible && model.canEdit && !confirmsReload }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "global-proxy", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 代理设置使用说明", comment: ""), documentID: "network-proxy", isActive: available)
            }
            if model.isLoaded {
                Section {
                    MacProxyFields(configuration: $model.draft, showsPassword: $showsPassword)
                } header: { Text(NSLocalizedString("全局代理", comment: "")) } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(!model.canEdit || !available)
            }
            if model.isLoading || model.isSaving { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("全局代理设置", comment: ""))
        .toolbar {
            Button(NSLocalizedString("重新载入", comment: "")) { confirmsReload = true }
                .disabled(!available || model.isLoading || model.isSaving)
            Button(NSLocalizedString("保存", comment: "")) { model.save() }
                .disabled(!available || !model.canEdit)
        }
        .confirmationDialog(NSLocalizedString("重新载入会丢弃当前草稿。", comment: ""), isPresented: $confirmsReload, titleVisibility: .visible) {
            Button(NSLocalizedString("重新载入", comment: ""), role: .destructive) { if available { model.reload() } }
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-global-proxy-\(model.epoch)-\(model.draft.type.rawValue)"),
            title: NSLocalizedString("全局代理设置", comment: ""),
            documents: [GuideDocumentReference(id: "network-proxy", title: "Network Proxy")], isActive: active,
            settings: MacProxyGuideSettings.fields($model.draft, showsPassword: showsPassword)
        )
        .onAppear { visible = true; if available && !model.isLoaded { model.reload() } }
        .onDisappear { visible = false; showsPassword = false; confirmsReload = false }
        .onChange(of: available) { _, available in
            if available && visible && !model.isLoaded { model.reload() }
            if !available { showsPassword = false; confirmsReload = false }
        }
        .onChange(of: model.epoch) { _, _ in showsPassword = false; confirmsReload = false }
    }
}

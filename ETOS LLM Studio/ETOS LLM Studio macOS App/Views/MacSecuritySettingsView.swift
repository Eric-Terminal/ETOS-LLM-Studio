import ETOSCore
import SwiftUI

@MainActor
struct MacSecuritySettingsView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var visible = false

    var body: some View {
        List {
            NavigationLink(NSLocalizedString("应用锁", comment: "")) {
                AppLockSettingsView()
                    .guidePageContext(descriptor: GuidePageDescriptor(id: "mac-app-lock",
                        title: NSLocalizedString("应用锁", comment: ""), documents: [GuideDocumentReference(id: "app-lock", title: "App Lock")]),
                        isFallback: true, isActive: isActive,
                        snapshot: { GuidePageSnapshot(fields: [
                            "password": GuideSnapshotField(label: NSLocalizedString("密码", comment: ""),
                                value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly)
                        ]) })
            }
            NavigationLink(NSLocalizedString("Connection Exceptions", comment: "")) {
                MacConnectionSecurityView(isActive: isActive, model: workspace.connectionSecurity)
            }
        }
        .navigationTitle(NSLocalizedString("安全", comment: ""))
        .disabled(!workspace.canManageLocalModels)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(id: "mac-security", title: NSLocalizedString("安全", comment: ""),
            documents: [GuideDocumentReference(id: "app-lock", title: "App Lock")] + MacConnectionSecurityView.documents,
            isActive: isActive && visible && workspace.canManageLocalModels, settings: [
                .readOnly("app_lock_requires_navigation", label: NSLocalizedString("应用锁", comment: ""), value: { .bool(true) }),
                .readOnly("connection_exceptions_require_navigation", label: NSLocalizedString("Connection Exceptions", comment: ""), value: { .bool(true) })
            ])
    }
}

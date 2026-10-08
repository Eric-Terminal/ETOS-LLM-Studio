import ETOSCore
import SwiftUI

@MainActor
struct MacExtendedFeaturesView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "extended-features", title: NSLocalizedString("拓展功能", comment: ""),
                    details: NSLocalizedString("Mac 拓展功能入口说明", comment: ""), documentID: "chat-quick-actions", isActive: available)
            }
            Section {
                NavigationLink { MacSlashCommandSettingsView(isActive: available, model: workspace.slashCommands) }
                    label: { Label(NSLocalizedString("快速指令", comment: ""), systemImage: "command") }
                NavigationLink { MacLocalModelLibraryView(isActive: available, library: workspace.localModels) }
                    label: { Label(NSLocalizedString("本地模型", comment: ""), systemImage: "cpu") }
                NavigationLink { MacLinuxView(isActive: available, model: workspace.linux) }
                    label: { Label(NSLocalizedString("本地 Linux", comment: ""), systemImage: "terminal") }
            }
            Section(NSLocalizedString("数据管理", comment: "")) {
                NavigationLink { MacStorageManagementView(isActive: available) }
                    label: { Label(NSLocalizedString("存储管理", comment: ""), systemImage: "internaldrive") }
                NavigationLink { MacBackupRestoreView() }
                    label: { Label(NSLocalizedString("快照备份", comment: ""), systemImage: "externaldrive") }
                NavigationLink { MacCloudSyncView() }
                    label: { Label(NSLocalizedString("iCloud 漫游同步", comment: ""), systemImage: "icloud") }
                NavigationLink { MacDataImportView(isActive: available) }
                    label: { Label(NSLocalizedString("导入数据", comment: ""), systemImage: "square.and.arrow.down") }
            }
            Section(NSLocalizedString("安全", comment: "")) {
                NavigationLink { AppLockSettingsView() }
                    label: { Label(NSLocalizedString("应用锁", comment: ""), systemImage: "lock.shield") }
                NavigationLink { MacConnectionSecurityView(isActive: isActive, model: workspace.connectionSecurity) }
                    label: { Label(NSLocalizedString("Connection Exceptions", comment: ""), systemImage: "network") }
            }
        }
        .navigationTitle(NSLocalizedString("拓展功能", comment: ""))
        .disabled(!available)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .guideSettingsPageContext(id: "mac-extended-features", title: NSLocalizedString("拓展功能", comment: ""),
            documents: [GuideDocumentReference(id: "chat-quick-actions", title: "Chat Quick Actions"),
                GuideDocumentReference(id: "slash-commands", title: "Quick Commands"),
                GuideDocumentReference(id: "data-import", title: "Data Import"),
                GuideDocumentReference(id: "storage-management", title: "Storage Management"),
                GuideDocumentReference(id: "network-connection-exceptions", title: NSLocalizedString("Connection Exceptions", comment: "")),
                GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")], isActive: available && visible,
            settings: [
                .readOnly("slash_commands_require_navigation", label: NSLocalizedString("快速指令", comment: ""), value: { .bool(true) }),
                .readOnly("local_models_require_navigation", label: NSLocalizedString("本地模型", comment: ""), value: { .bool(true) }),
                .readOnly("linux_requires_navigation", label: NSLocalizedString("本地 Linux", comment: ""), value: { .bool(true) }),
                .readOnly("backup_requires_navigation", label: NSLocalizedString("快照备份", comment: ""), value: { .bool(true) }),
                .readOnly("sync_requires_navigation", label: NSLocalizedString("iCloud 漫游同步", comment: ""), value: { .bool(true) }),
                .readOnly("import_requires_navigation", label: NSLocalizedString("导入数据", comment: ""), value: { .bool(true) }),
                .readOnly("storage_requires_navigation", label: NSLocalizedString("存储管理", comment: ""), value: { .bool(true) }),
                .readOnly("connection_exceptions_require_navigation", label: NSLocalizedString("Connection Exceptions", comment: ""), value: { .bool(true) }),
                .readOnly("security_requires_navigation", label: NSLocalizedString("应用锁", comment: ""), value: { .bool(true) })
            ])
    }
}

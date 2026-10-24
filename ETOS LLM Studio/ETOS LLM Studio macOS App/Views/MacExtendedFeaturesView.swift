import ETOSCore
import SwiftUI

@MainActor
struct MacExtendedFeaturesView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var visible = false
    @StateObject private var achievements = MacAchievementModel()
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "extended-features", title: NSLocalizedString("拓展功能", comment: ""),
                    details: NSLocalizedString("Mac 拓展功能入口说明", comment: "")
                        + "\n\n" + NSLocalizedString("batch.entry.description", value: "Open Batch Tasks to send independent requests together and retrieve results later. The provider must support the Batch API.", comment: "批量任务入口说明"),
                    documentID: "settings-extended", isActive: available)
            }
            if !achievements.entries.isEmpty {
                Section {
                    NavigationLink { MacAchievementJournalView(isActive: available) }
                        label: { Label(NSLocalizedString("成就日记", comment: ""), systemImage: "book.closed") }
                }
            }
            Section {
                NavigationLink { MacFeedbackCenterView(isActive: available) }
                    label: { Label(NSLocalizedString("反馈助手", comment: ""), systemImage: "bubble.left.and.text.bubble.right") }
                NavigationLink { MacSlashCommandSettingsView(isActive: available, model: workspace.slashCommands) }
                    label: { Label(NSLocalizedString("快速指令", comment: ""), systemImage: "command") }
                NavigationLink { BatchTasksView(isActive: available) }
                    label: { Label(NSLocalizedString("batch.title", value: "Batch Tasks", comment: "批量任务入口"), systemImage: "tray.full") }
                    .accessibilityIdentifier("batch.tasks.entry")
                NavigationLink { MacLocalModelLibraryView(isActive: available, library: workspace.localModels) }
                    label: { Label(NSLocalizedString("本地模型", comment: ""), systemImage: "cpu") }
                NavigationLink { MacShellView(isActive: available, model: workspace.linux) }
                    label: { Label(NSLocalizedString("mac.shell.title", value: "Local Shell", comment: ""), systemImage: "terminal") }
            }
            Section(NSLocalizedString("数据管理", comment: "")) {
                NavigationLink { MacImageGalleryView(isActive: available) }
                    label: { Label(NSLocalizedString("图片相册", comment: ""), systemImage: "photo.on.rectangle") }
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
                NavigationLink { MacRemoteAccessView(isActive: isActive, model: workspace.remoteAccess) }
                    label: { Label(NSLocalizedString("远程文件访问", comment: ""), systemImage: "network") }
            }
        }
        .navigationTitle(NSLocalizedString("拓展功能", comment: ""))
        .disabled(!available)
        .onAppear { visible = true; achievements.reload() }
        .onDisappear { visible = false }
        .guideSettingsPageContext(id: "mac-extended-features", title: NSLocalizedString("拓展功能", comment: ""),
            documents: [GuideDocumentReference(id: "settings-extended", title: "Extended Features"),
                GuideDocumentReference(id: "batch-tasks", title: "Batch Tasks"),
                GuideDocumentReference(id: "chat-quick-actions", title: "Chat Quick Actions"),
                GuideDocumentReference(id: "slash-commands", title: "Quick Commands"),
                GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: "")),
                GuideDocumentReference(id: "mac-image-gallery", title: NSLocalizedString("图片相册", comment: "")),
                GuideDocumentReference(id: "data-import", title: "Data Import"),
                GuideDocumentReference(id: "storage-management", title: "Storage Management"),
                GuideDocumentReference(id: "remote-file-access", title: NSLocalizedString("远程文件访问", comment: "")),
                GuideDocumentReference(id: "network-connection-exceptions", title: NSLocalizedString("Connection Exceptions", comment: "")),
                GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")], isActive: available && visible,
            settings: [
                .readOnly("feedback_requires_navigation", label: NSLocalizedString("反馈助手", comment: ""), value: { .bool(true) }),
                .readOnly("gallery_requires_navigation", label: NSLocalizedString("图片相册", comment: ""), value: { .bool(true) }),
                .readOnly("slash_commands_require_navigation", label: NSLocalizedString("快速指令", comment: ""), value: { .bool(true) }),
                .readOnly("batch_tasks_require_navigation", label: NSLocalizedString("batch.title", value: "Batch Tasks", comment: "批量任务入口"), value: { .bool(true) }),
                .readOnly("local_models_require_navigation", label: NSLocalizedString("本地模型", comment: ""), value: { .bool(true) }),
                .readOnly("shell_requires_navigation", label: NSLocalizedString("mac.shell.title", value: "Local Shell", comment: ""), value: { .bool(true) }),
                .readOnly("backup_requires_navigation", label: NSLocalizedString("快照备份", comment: ""), value: { .bool(true) }),
                .readOnly("sync_requires_navigation", label: NSLocalizedString("iCloud 漫游同步", comment: ""), value: { .bool(true) }),
                .readOnly("import_requires_navigation", label: NSLocalizedString("导入数据", comment: ""), value: { .bool(true) }),
                .readOnly("storage_requires_navigation", label: NSLocalizedString("存储管理", comment: ""), value: { .bool(true) }),
                .readOnly("connection_exceptions_require_navigation", label: NSLocalizedString("Connection Exceptions", comment: ""), value: { .bool(true) }),
                .readOnly("remote_access_requires_navigation", label: NSLocalizedString("远程文件访问", comment: ""), value: { .bool(true) }),
                .readOnly("security_requires_navigation", label: NSLocalizedString("应用锁", comment: ""), value: { .bool(true) })
            ])
    }
}

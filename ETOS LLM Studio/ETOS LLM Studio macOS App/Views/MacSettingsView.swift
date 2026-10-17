import ETOSCore
import SwiftUI

/// 设置沿用移动端的功能名称；桌面用稳定的侧栏定位，详情页各自拥有导航栈。
struct MacSettingsView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var selection: MacSettingsDestination? = .models
    @State private var showsGuide = false
    @State private var visible = false
    private var available: Bool { visible && workspace.canManageLocalModels && appLock.state != .locked }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    rows([.models, .conversation, .prompts, .output, .display, .sync])
                }
                Section(NSLocalizedString("拓展能力", comment: "")) {
                    rows([.tools, .pulse, .usage, .batch, .memory, .mcp, .skills, .shortcuts,
                          .roleplay, .worldbook, .speech, .tts, .browser, .extended])
                }
                Section(NSLocalizedString("设置", comment: "")) {
                    rows([.general, .security, .guide, .about])
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(NSLocalizedString("设置", comment: ""))
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            Group {
                if selection == .pulse {
                    MacDailyPulseView(model: workspace.dailyPulse, isEmbeddedInSettings: true)
                } else {
                    NavigationStack { destination(selection ?? .models) }
                }
            }
            // 切换分类销毁旧导航与草稿上下文，向导不能继续执行上一页的提案。
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        .disabled(workspace.isRestoringData)
        .frame(minWidth: 820, minHeight: 620)
        .toolbar {
            if selection != .pulse {
                Button { showsGuide.toggle() } label: {
                    Label(NSLocalizedString("页面向导", comment: ""), systemImage: "sparkles")
                }
            }
        }
        .inspector(isPresented: $showsGuide) {
            MacGuideView().inspectorColumnWidth(min: 300, ideal: 360, max: 500)
        }
        .overlay { if appLock.state == .locked { AppLockOverlayView() } }
        .networkConnectionApprovalHost(isEnabled: available)
        .modifier(MacSettingsAchievementTriggers())
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: selection) { _, _ in showsGuide = false }
        .onChange(of: configuration.appLanguage) { _, language in AppLanguageRuntime.apply(rawValue: language) }
    }

    private func rows(_ destinations: [MacSettingsDestination]) -> some View {
        ForEach(destinations) { destination in
            Label(destination.title, systemImage: destination.symbol).tag(destination)
        }
    }

    @ViewBuilder
    private func destination(_ destination: MacSettingsDestination) -> some View {
        switch destination {
        case .models: MacProviderListView(isActive: available)
        case .conversation: MacCoreSettingsView(page: .conversation, isActive: available)
        case .prompts: MacCoreSettingsView(page: .prompts, isActive: available)
        case .output: MacCoreSettingsView(page: .output, isActive: available)
        case .display: MacDisplaySettingsView(isActive: available)
        case .sync: syncSettings
        case .tools: MacToolCenterView(isActive: available)
        case .pulse: MacDailyPulseView(model: workspace.dailyPulse, isEmbeddedInSettings: true)
        case .usage: MacUsageAnalyticsView(isActive: available)
        case .batch: BatchTasksView(isActive: available)
        case .memory: MacMemorySystemView(isActive: available)
        case .mcp: MacMCPListView(isActive: available)
        case .skills: MacSkillsView(isActive: available, model: workspace.skills)
        case .shortcuts: MacShortcutToolsView(isActive: available, model: workspace.shortcutTools)
        case .roleplay: MacRoleplayLibraryView(model: workspace.roleplayModel)
        case .worldbook: MacWorldbookListView(model: workspace.worldbookModel)
        case .speech: MacSpeechInputSettingsView(model: workspace.speechInput, isActive: available)
        case .tts: MacTTSSettingsView(model: workspace.tts, isActive: available)
        case .browser:
            MacBrowserView(sessionID: workspace.currentSession?.id, isTemporary: workspace.temporaryChatMemoryMode != nil,
                           isActive: available, model: workspace.browser)
        case .extended: MacExtendedFeaturesView(isActive: available)
        case .general: generalSettings
        case .security: MacSecuritySettingsView(isActive: available)
        case .guide: guideSettings
        case .about: MacAboutView(isActive: available)
        }
    }

    private var generalSettings: some View {
        Form {
            Section {
                Picker(NSLocalizedString("语言", comment: ""), selection: $configuration.appLanguage) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        Text(language.nativeDisplayName).tag(language.rawValue)
                    }
                }
                NavigationLink(NSLocalizedString("全局代理设置", comment: "")) {
                    MacGlobalProxyView(model: workspace.globalProxy, isActive: available)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("通用", comment: ""))
        .guideSettingsPageContext(id: "mac-general", title: NSLocalizedString("通用", comment: ""),
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: available,
            settings: [
                .readOnly("proxy_requires_navigation", label: NSLocalizedString("全局代理设置", comment: ""), value: { .bool(true) }),
                .string("language", label: NSLocalizedString("语言", comment: ""), allowedValues: AppLanguagePreference.allCases.map(\.rawValue), get: { configuration.appLanguage }, set: { configuration.appLanguage = $0 })
            ])
    }

    private var syncSettings: some View {
        Form {
            Section {
                NavigationLink(NSLocalizedString("快照备份", comment: "")) { MacBackupRestoreView() }
                NavigationLink(NSLocalizedString("iCloud 漫游同步", comment: "")) { MacCloudSyncView() }
            }
            Section {
                NavigationLink(NSLocalizedString("导入数据", comment: "")) { MacDataImportView(isActive: available) }
                NavigationLink(NSLocalizedString("存储管理", comment: "")) { MacStorageManagementView(isActive: available) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("同步与备份", comment: ""))
        .guideSettingsPageContext(id: "mac-data", title: NSLocalizedString("同步与备份", comment: ""),
            documents: SnapshotBackupGuideSupport.documents + [GuideDocumentReference(id: "settings-sync", title: "Sync Settings"),
                GuideDocumentReference(id: "storage-management", title: "Storage Management"), GuideDocumentReference(id: "data-import", title: "Data Import")],
            isActive: available,
            settings: [
                .readOnly("restoring", label: NSLocalizedString("正在恢复快照…", comment: ""), value: { .bool(workspace.isRestoringData) }),
                .readOnly("import_requires_navigation", label: NSLocalizedString("导入数据", comment: ""), value: { .bool(true) }),
                .readOnly("storage_requires_navigation", label: NSLocalizedString("存储管理", comment: ""), value: { .bool(true) })
            ])
    }

    private var guideSettings: some View {
        Form { Text(NSLocalizedString("guide.privacy.details", comment: "")).textSelection(.enabled) }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("页面向导与隐私", comment: ""))
            .guideSettingsPageContext(id: "mac-guide-privacy", title: NSLocalizedString("页面向导与隐私", comment: ""),
                documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")], isActive: available,
                settings: [.readOnly("read_only", label: NSLocalizedString("使用说明", comment: ""), value: { .bool(true) })])
    }
}

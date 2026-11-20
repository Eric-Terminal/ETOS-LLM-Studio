import ETOSCore
import SwiftUI

/// 设置沿用移动端的功能名称；桌面用稳定的侧栏定位，详情页各自拥有导航栈。
struct MacSettingsView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var guideSession = MacGuideSession.shared
    @State private var detailPath: [GuideNavigationDestination] = []
    @State private var routeID = UUID()
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
                    rows([.tools, .pulse, .usage, .memory, .mcp, .skills, .shortcuts,
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
                    NavigationStack(path: $detailPath) {
                        destination(selection ?? .models)
                            .navigationDestination(for: GuideNavigationDestination.self, destination: guideDetail)
                    }
                }
            }
            // 切换分类销毁旧导航与草稿上下文，向导不能继续执行上一页的提案。
            .id(selection)
            .id(routeID)
        }
        .environment(\.isGuideSettingsWindow, true)
        .environment(\.feedbackGuidePresentation, $showsGuide)
        .navigationSplitViewStyle(.balanced)
        .disabled(workspace.isRestoringData)
        .frame(minWidth: 820, minHeight: 620)
        .toolbar {
            if configuration.guideOverlayEnabled || showsGuide {
                Button { showsGuide.toggle() } label: {
                    Label(NSLocalizedString("使用助手", value: "App Guide", comment: ""), systemImage: "sparkles")
                }
            }
        }
        .inspector(isPresented: $showsGuide) {
            MacGuideView().inspectorColumnWidth(min: 300, ideal: 360, max: 500)
        }
        .overlay { if appLock.state == .locked { AppLockOverlayView() } }
        .networkConnectionApprovalHost(isEnabled: available)
        .modifier(MacSettingsAchievementTriggers())
        .onAppear {
            visible = true
            guideSession.attach(openSettings)
            applyGuideRequest()
        }
        .onChange(of: guideSession.pending) { _, _ in if visible { applyGuideRequest() } }
        .onDisappear { visible = false }
        .onChange(of: selection) { _, section in
            guideSession.controller.discardPendingProposalForNavigation()
            if detailPath.first?.macSettingsSection != section { detailPath = [] }
        }
        .onChange(of: configuration.guideOverlayEnabled) { _, enabled in
            if !enabled { showsGuide = false }
        }
        .onChange(of: configuration.appLanguage) { _, language in AppLanguageRuntime.apply(rawValue: language) }
    }

    private func applyGuideRequest() {
        guard let target = guideSession.consume(), let section = target.macSettingsSection else { return }
        selection = section
        switch target {
        case .dataImport, .networkProxy, .connectionExceptions, .feedbackCenter, .feedbackCompose: detailPath = [target]
        default: detailPath = []
        }
        routeID = UUID()
        showsGuide = true
    }

    @ViewBuilder
    private func guideDetail(_ target: GuideNavigationDestination) -> some View {
        switch target {
        case .dataImport: MacDataImportView(isActive: available)
        case .networkProxy: MacGlobalProxyView(model: workspace.globalProxy, isActive: available)
        case .connectionExceptions: MacConnectionSecurityView(isActive: available, model: workspace.connectionSecurity)
        case .feedbackCenter: MacFeedbackCenterView(isActive: available)
        case .feedbackCompose: MacFeedbackComposeView(isActive: available, service: MacAppInformationModel.shared.feedback)
        default: EmptyView()
        }
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
        Form {
            Toggle(NSLocalizedString("在设置页面显示使用助手", value: "Show App Guide in Settings", comment: "设置助手入口开关"), isOn: $configuration.guideOverlayEnabled)
            Text(NSLocalizedString("guide.privacy.details", comment: "")).textSelection(.enabled)
                .font(.footnote).foregroundStyle(.secondary)
        }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("使用助手与隐私", value: "App Guide and Privacy", comment: ""))
            .guideSettingsPageContext(id: "mac-guide-privacy", title: NSLocalizedString("使用助手与隐私", value: "App Guide and Privacy", comment: ""),
                documents: [GuideDocumentReference(id: "guide-overview", title: "Guide Overview")], isActive: available,
                settings: [.bool("guide_overlay_enabled", label: NSLocalizedString("在设置页面显示使用助手", value: "Show App Guide in Settings", comment: "设置助手入口开关"), get: { configuration.guideOverlayEnabled }, set: { configuration.guideOverlayEnabled = $0 })])
    }
}

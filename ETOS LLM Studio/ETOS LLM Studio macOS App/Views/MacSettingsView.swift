import ETOSCore
import SwiftUI

struct MacSettingsView: View {
    private enum Tab: Hashable { case general, providers, mcp, context, data, security }
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var selectedTab = Tab.general
    @State private var showsGuide = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { MacGeneralSettingsView(isActive: selectedTab == .general) }
                .tabItem { Label(NSLocalizedString("通用", comment: ""), systemImage: "slider.horizontal.3") }
                .tag(Tab.general)
            NavigationStack { MacProviderListView(isActive: selectedTab == .providers) }
                .tabItem { Label(NSLocalizedString("模型管理", comment: ""), systemImage: "shippingbox") }
                .tag(Tab.providers)
            NavigationStack { MacMCPListView(isActive: selectedTab == .mcp) }
                .tabItem { Label(NSLocalizedString("MCP 工具", comment: ""), systemImage: "puzzlepiece.extension") }
                .tag(Tab.mcp)
            NavigationStack {
                List {
                    NavigationLink(NSLocalizedString("记忆", comment: "")) { MacMemorySettingsView(model: workspace.memoryModel) }
                }
                .navigationTitle(NSLocalizedString("上下文", comment: ""))
                .guideSettingsPageContext(
                    id: "mac-context", title: NSLocalizedString("上下文", comment: ""),
                    documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")], isActive: selectedTab == .context,
                    settings: [.readOnly("requires_navigation", label: NSLocalizedString("记忆", comment: ""), value: { .bool(true) })]
                )
            }
            .tabItem { Label(NSLocalizedString("上下文", comment: ""), systemImage: "brain.head.profile") }
            .tag(Tab.context)
            NavigationStack {
                List {
                    NavigationLink(NSLocalizedString("快照备份", comment: "")) { MacBackupRestoreView() }
                    NavigationLink(NSLocalizedString("iCloud 漫游同步", comment: "")) { MacCloudSyncView() }
                }
                .navigationTitle(NSLocalizedString("数据管理", comment: ""))
                .guideSettingsPageContext(
                    id: "mac-data", title: NSLocalizedString("数据管理", comment: ""),
                    documents: SnapshotBackupGuideSupport.documents + [GuideDocumentReference(id: "settings-sync", title: "Sync Settings")], isActive: selectedTab == .data,
                    settings: [.readOnly("restoring", label: NSLocalizedString("正在恢复快照…", comment: ""), value: { .bool(workspace.isRestoringData) })]
                )
            }
            .tabItem { Label(NSLocalizedString("数据管理", comment: ""), systemImage: "externaldrive") }
            .tag(Tab.data)
            NavigationStack {
                AppLockSettingsView()
                    .guidePageContext(
                        descriptor: GuidePageDescriptor(
                            id: "mac-security", title: NSLocalizedString("安全", comment: ""),
                            documents: [GuideDocumentReference(id: "app-lock", title: "App Lock")]
                        ),
                        isFallback: true, isActive: selectedTab == .security,
                        snapshot: { GuidePageSnapshot(fields: [
                            "password": GuideSnapshotField(label: NSLocalizedString("密码", comment: ""), value: .string(GuideSnapshotField.hiddenValue), access: .writeOnly)
                        ]) }
                    )
            }
            .tabItem { Label(NSLocalizedString("安全", comment: ""), systemImage: "lock.shield") }
            .tag(Tab.security)
        }
        .disabled(workspace.isRestoringData)
        .frame(minWidth: 680, minHeight: 580)
        .toolbar {
            Button { showsGuide.toggle() } label: {
                Label(NSLocalizedString("页面向导", comment: ""), systemImage: "sparkles")
            }
        }
        .inspector(isPresented: $showsGuide) {
            MacGuideView().inspectorColumnWidth(min: 300, ideal: 360, max: 500)
        }
        .overlay { if appLock.state == .locked { AppLockOverlayView() } }
        .onChange(of: configuration.appLanguage) { _, language in
            AppLanguageRuntime.apply(rawValue: language)
        }
    }
}

private struct MacGeneralSettingsView: View {
    let isActive: Bool
    @ObservedObject private var configuration = AppConfigStore.shared

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "general", title: NSLocalizedString("使用说明", comment: ""), details: NSLocalizedString("Mac 使用相同的会话和模型配置格式。先在模型管理中添加提供商并启用模型，再回到聊天窗口发送消息。使用 ⌘N 新建对话，⌘Return 发送。", comment: ""), documentID: "macos-workspace")
                Picker(NSLocalizedString("语言", comment: ""), selection: $configuration.appLanguage) {
                    ForEach(AppLanguagePreference.allCases) { language in
                        Text(language.nativeDisplayName).tag(language.rawValue)
                    }
                }
            }
            Section {
                Toggle(NSLocalizedString("流式输出", comment: ""), isOn: $configuration.enableStreaming)
                Toggle(NSLocalizedString("Markdown 渲染", comment: ""), isOn: $configuration.enableMarkdown)
                Toggle(NSLocalizedString("自动命名会话", comment: ""), isOn: $configuration.enableAutoSessionNaming)
                Stepper(value: $configuration.maxChatHistory, in: 0...1000) {
                    Text(String(format: NSLocalizedString("历史消息数：%d", comment: ""), configuration.maxChatHistory))
                }
            } header: { Text(NSLocalizedString("聊天", comment: "")) }
            Section {
                Toggle(NSLocalizedString("启用温度参数", comment: ""), isOn: $configuration.aiTemperatureEnabled)
                Slider(value: $configuration.aiTemperature, in: 0...2) {
                    Text(NSLocalizedString("温度", comment: ""))
                }
                .disabled(!configuration.aiTemperatureEnabled)
                Toggle(NSLocalizedString("启用 Top P", comment: ""), isOn: $configuration.aiTopPEnabled)
                Slider(value: $configuration.aiTopP, in: 0...1) { Text(NSLocalizedString("Top P", comment: "")) }
                    .disabled(!configuration.aiTopPEnabled)
                TextField(NSLocalizedString("系统提示词", comment: ""), text: $configuration.systemPrompt, axis: .vertical)
                    .lineLimit(3...10)
            } header: { Text(NSLocalizedString("生成参数", comment: "")) }
            Section {
                Toggle(NSLocalizedString("启用记忆", comment: ""), isOn: $configuration.enableMemory)
                Toggle(NSLocalizedString("允许写入记忆", comment: ""), isOn: $configuration.enableMemoryWrite)
                Toggle(NSLocalizedString("主动检索记忆", comment: ""), isOn: $configuration.enableMemoryActiveRetrieval)
                Toggle(NSLocalizedString("在提示词中包含系统时间", comment: ""), isOn: $configuration.includeSystemTimeInPrompt)
            } header: { Text(NSLocalizedString("上下文", comment: "")) }
        }
        .formStyle(.grouped)
        .navigationTitle(NSLocalizedString("通用", comment: ""))
        .guideSettingsPageContext(
            id: "mac-general", title: NSLocalizedString("通用", comment: ""),
            documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: isActive,
            settings: [
                .string("language", label: NSLocalizedString("语言", comment: ""), allowedValues: AppLanguagePreference.allCases.map(\.rawValue), get: { configuration.appLanguage }, set: { configuration.appLanguage = $0 }),
                .bool("streaming", label: NSLocalizedString("流式输出", comment: ""), get: { configuration.enableStreaming }, set: { configuration.enableStreaming = $0 }),
                .bool("markdown", label: NSLocalizedString("Markdown 渲染", comment: ""), get: { configuration.enableMarkdown }, set: { configuration.enableMarkdown = $0 }),
                .bool("auto_title", label: NSLocalizedString("自动命名会话", comment: ""), get: { configuration.enableAutoSessionNaming }, set: { configuration.enableAutoSessionNaming = $0 }),
                .integer("history_limit", label: NSLocalizedString("历史消息数", comment: ""), range: 0...1000, get: { configuration.maxChatHistory }, set: { configuration.maxChatHistory = $0 }),
                .bool("temperature_enabled", label: NSLocalizedString("启用温度参数", comment: ""), get: { configuration.aiTemperatureEnabled }, set: { configuration.aiTemperatureEnabled = $0 }),
                .double("temperature", label: NSLocalizedString("温度", comment: ""), range: 0...2, get: { configuration.aiTemperature }, set: { configuration.aiTemperature = $0 }),
                .bool("top_p_enabled", label: NSLocalizedString("启用 Top P", comment: ""), get: { configuration.aiTopPEnabled }, set: { configuration.aiTopPEnabled = $0 }),
                .double("top_p", label: NSLocalizedString("Top P", comment: ""), range: 0...1, get: { configuration.aiTopP }, set: { configuration.aiTopP = $0 }),
                .string("system_prompt", label: NSLocalizedString("系统提示词", comment: ""), get: { configuration.systemPrompt }, set: { configuration.systemPrompt = $0 }),
                .bool("memory", label: NSLocalizedString("启用记忆", comment: ""), get: { configuration.enableMemory }, set: { configuration.enableMemory = $0 }),
                .bool("memory_write", label: NSLocalizedString("允许写入记忆", comment: ""), get: { configuration.enableMemoryWrite }, set: { configuration.enableMemoryWrite = $0 }),
                .bool("memory_retrieval", label: NSLocalizedString("主动检索记忆", comment: ""), get: { configuration.enableMemoryActiveRetrieval }, set: { configuration.enableMemoryActiveRetrieval = $0 }),
                .bool("system_time", label: NSLocalizedString("在提示词中包含系统时间", comment: ""), get: { configuration.includeSystemTimeInPrompt }, set: { configuration.includeSystemTimeInPrompt = $0 })
            ]
        )
    }
}

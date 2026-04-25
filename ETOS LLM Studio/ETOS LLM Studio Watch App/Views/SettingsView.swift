// ============================================================================
// SettingsView.swift
// ============================================================================
// ETOS LLM Studio Watch App 设置主视图
//
// 功能特性:
// - 组合所有设置项的入口
// - 包括模型设置、对话管理、显示设置等
// ============================================================================

import SwiftUI
import Foundation
import Shared

enum WatchSettingsNavigationDestination: Hashable, Identifiable {
    case dailyPulse
    case feedbackCenter
    case feedbackIssue(issueNumber: Int)
    case achievementJournal

    var id: String {
        switch self {
        case .dailyPulse:
            return "dailyPulse"
        case .feedbackCenter:
            return "feedbackCenter"
        case .feedbackIssue(let issueNumber):
            return "feedbackIssue-\(issueNumber)"
        case .achievementJournal:
            return "achievementJournal"
        }
    }
}

private enum SettingsHomeExperiment {
    static let storageKey = "ui.betaSettingsHomeEnabled"
}

/// 设置视图
struct SettingsView: View {
    
    // MARK: - 视图模型
    
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var pulseManager = DailyPulseManager.shared
    @ObservedObject private var deliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @ObservedObject private var achievementCenter = AchievementCenter.shared
    
    // MARK: - 公告管理器
    
    @ObservedObject var announcementManager = AnnouncementManager.shared

    // MARK: - 环境
    
    @Environment(\.dismiss) var dismiss
    @Binding private var requestedDestination: WatchSettingsNavigationDestination?
    @AppStorage(ChatNavigationMode.storageKey) private var chatNavigationModeRawValue: String = ChatNavigationMode.defaultMode.rawValue
    @AppStorage(SettingsHomeExperiment.storageKey) private var useBetaSettingsHome = false
    @State private var settingsResearchTask: Task<Void, Never>?

    init(
        viewModel: ChatViewModel,
        requestedDestination: Binding<WatchSettingsNavigationDestination?> = .constant(nil)
    ) {
        self.viewModel = viewModel
        self._requestedDestination = requestedDestination
    }
    
    // MARK: - 视图主体
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    let options = viewModel.activatedModels
                    if options.isEmpty {
                        Text("暂无可用模型，请先在“提供商与模型管理”中启用。")
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        NavigationLink {
                            ModelSelectionView(
                                models: options,
                                selectedModel: selectedModelBinding
                            )
                        } label: {
                            HStack(spacing: 8) {
                                if usesNativeSettingsIcons {
                                    SettingsListIconView(icon: .currentModel)
                                }
                                Text("当前模型")
                                MarqueeText(
                                    content: selectedModelLabel(in: options),
                                    uiFont: .preferredFont(forTextStyle: .footnote)
                                )
                                    .foregroundStyle(.secondary)
                                    .allowsHitTesting(false)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }

                    Button {
                        viewModel.createNewSession()
                        dismiss()
                    } label: {
                        settingsNavigationLabel("开启新对话", icon: .newConversation)
                    }
                } header: {
                    Text("当前模型")
                }

                if useBetaSettingsHome && canUseBetaSettingsHome {
                    betaSettingsHomeSections
                } else {
                    Section {
                    NavigationLink(destination: SessionListView(
                        sessions: $viewModel.chatSessions,
                        folders: $viewModel.sessionFolders,
                        currentSession: $viewModel.currentSession,
                        runningSessionIDs: viewModel.runningSessionIDs,
                        deleteSessionAction: { session in
                            viewModel.deleteSessions([session])
                        },
                        branchAction: { session, copyMessages in
                            let newSession = viewModel.branchSession(from: session, copyMessages: copyMessages)
                            return newSession
                        },
                        deleteLastMessageAction: { session in
                            viewModel.deleteLastMessage(for: session)
                        },
                        sendSessionToCompanionAction: { session in
                            WatchSyncManager.shared.sendSessionToCompanion(sessionID: session.id)
                        },
                        onSessionSelected: { selectedSession, messageOrdinal in
                            if let messageOrdinal {
                                viewModel.requestMessageJump(
                                    sessionID: selectedSession.id,
                                    messageOrdinal: messageOrdinal
                                )
                            } else {
                                viewModel.clearPendingMessageJumpTarget()
                            }
                            ChatService.shared.setCurrentSession(selectedSession)
                            dismiss()
                        },
                        updateSessionAction: { session in
                            viewModel.updateSession(session)
                        },
                        createFolderAction: { name, parentID in
                            viewModel.createSessionFolder(name: name, parentID: parentID)
                        },
                        renameFolderAction: { folder, newName in
                            viewModel.renameSessionFolder(folder, newName: newName)
                        },
                        deleteFolderAction: { folder in
                            viewModel.deleteSessionFolder(folder)
                        },
                        moveSessionToFolderAction: { session, folderID in
                            viewModel.moveSession(session, toFolderID: folderID)
                        }
                    )) {
                        settingsNavigationLabel("历史会话管理", icon: .sessionHistory)
                    }

                    NavigationLink(destination: ProviderListView().environmentObject(viewModel)) {
                        settingsNavigationLabel("提供商与模型管理", icon: .providerManagement)
                    }
                    
                    NavigationLink(destination: ModelAdvancedSettingsView(
                        aiTemperature: $viewModel.aiTemperature,
                        aiTopP: $viewModel.aiTopP,
                        globalSystemPromptEntries: $viewModel.globalSystemPromptEntries,
                        selectedGlobalSystemPromptEntryID: $viewModel.selectedGlobalSystemPromptEntryID,
                        maxChatHistory: $viewModel.maxChatHistory,
                        lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
                        enableStreaming: $viewModel.enableStreaming,
                        enableResponseSpeedMetrics: $viewModel.enableResponseSpeedMetrics,
                        enableOpenAIStreamIncludeUsage: $viewModel.enableOpenAIStreamIncludeUsage,
                        enableAutoSessionNaming: $viewModel.enableAutoSessionNaming, // 传递新增的绑定
                        enableReasoningSummary: $viewModel.enableReasoningSummary,
                        currentSession: $viewModel.currentSession,
                        includeSystemTimeInPrompt: $viewModel.includeSystemTimeInPrompt,
                        enablePeriodicTimeLandmark: $viewModel.enablePeriodicTimeLandmark,
                        periodicTimeLandmarkIntervalMinutes: $viewModel.periodicTimeLandmarkIntervalMinutes,
                        addGlobalSystemPromptEntry: viewModel.addGlobalSystemPromptEntry,
                        selectGlobalSystemPromptEntry: viewModel.selectGlobalSystemPromptEntry,
                        updateSelectedGlobalSystemPromptContent: viewModel.updateSelectedGlobalSystemPromptContent,
                        updateGlobalSystemPromptEntry: viewModel.updateGlobalSystemPromptEntry,
                        deleteGlobalSystemPromptEntry: { viewModel.deleteGlobalSystemPromptEntry(id: $0) }
                    )) {
                        settingsNavigationLabel("偏好设置", icon: .modelAdvanced)
                    }

                    NavigationLink(destination: DailyPulseView(viewModel: viewModel)) {
                        settingsStatusLabel(
                            "每日脉冲",
                            icon: .dailyPulse,
                            status: dailyPulseEntryStatusText,
                            statusColor: pulseManager.hasUnviewedTodayRun ? .blue : .secondary
                        )
                    }

                    NavigationLink(destination: UsageAnalyticsView()) {
                        settingsNavigationLabel("用量统计", icon: .usageAnalytics)
                    }

                    NavigationLink(destination: ExtendedFeaturesView().environmentObject(viewModel)) {
                        settingsNavigationLabel("拓展功能", icon: .extendedFeatures)
                    }

                    NavigationLink(destination: DisplaySettingsView(
                        enableMarkdown: $viewModel.enableMarkdown,
                        enableBackground: $viewModel.enableBackground,
                        backgroundBlur: $viewModel.backgroundBlur,
                        backgroundOpacity: $viewModel.backgroundOpacity,
                        enableAutoRotateBackground: $viewModel.enableAutoRotateBackground,
                        currentBackgroundImage: $viewModel.currentBackgroundImage,
                        backgroundContentMode: $viewModel.backgroundContentMode,
                        enableLiquidGlass: $viewModel.enableLiquidGlass,
                        enableAdvancedRenderer: $viewModel.enableAdvancedRenderer,
                        enableAutoReasoningPreview: $viewModel.enableAutoReasoningPreview,
                        enableNoBubbleUI: $viewModel.enableNoBubbleUI,
                        allBackgrounds: viewModel.backgroundImages
                    )) {
                        settingsNavigationLabel("显示与外观", icon: .display)
                    }
                    
                    NavigationLink(destination: DeviceSyncSettingsView()) {
                        settingsNavigationLabel("同步与备份", icon: .sync)
                    }
                    
                    NavigationLink(destination: AboutView()) {
                        settingsNavigationLabel("关于", icon: .about)
                    }
                }
                }
                
                // MARK: - 公告通知 Section
                if announcementManager.shouldShowInSettings {
                    Section {
                        ForEach(announcementManager.currentAnnouncements, id: \.uniqueKey) { announcement in
                            NavigationLink(destination: AnnouncementDetailView(
                                announcement: announcement,
                                announcementManager: announcementManager
                            )) {
                                HStack {
                                    announcementIcon(for: announcement.type)
                                    Text(announcement.title)
                                        .lineLimit(2)
                                }
                            }
                        }
                    } header: {
                        Text("系统公告")
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear {
                ensureSelectedModel(in: viewModel.activatedModels)
                disableBetaSettingsHomeIfNeeded()
                scheduleSettingsResearchAchievementIfNeeded()
            }
            .onDisappear {
                cancelSettingsResearchAchievementTask()
            }
            .onChange(of: viewModel.activatedModels.map(\.id)) { _, _ in
                ensureSelectedModel(in: viewModel.activatedModels)
            }
            .onChange(of: chatNavigationModeRawValue) { _, _ in
                disableBetaSettingsHomeIfNeeded()
            }
            .navigationDestination(item: $requestedDestination) { destination in
                switch destination {
                case .dailyPulse:
                    DailyPulseView(viewModel: viewModel)
                case .feedbackCenter:
                    FeedbackCenterView()
                case .feedbackIssue(let issueNumber):
                    WatchFeedbackDetailView(issueNumber: issueNumber)
                case .achievementJournal:
                    AchievementJournalView()
                }
            }
        }
    }
    
    // MARK: - 辅助方法

    private var canUseBetaSettingsHome: Bool {
        usesNativeSettingsIcons
    }

    private var usesNativeSettingsIcons: Bool {
        ChatNavigationMode.resolvedMode(rawValue: chatNavigationModeRawValue) == .nativeNavigation
    }

    @ViewBuilder
    private var betaSettingsHomeSections: some View {
        Section {
            NavigationLink {
                SettingsCategoryList(title: "对话与模型") {
                    conversationAndModelSettingsSection
                }
            } label: {
                settingsNavigationLabel("对话与模型", icon: .conversationAndModels)
            }

            NavigationLink {
                SettingsCategoryList(title: "AI 能力") {
                    aiCapabilitySettingsSection
                }
            } label: {
                settingsNavigationLabel("AI 能力", icon: .aiCapabilities)
            }

            NavigationLink {
                SettingsCategoryList(title: "工具与自动化") {
                    toolAutomationSettingsSection
                }
            } label: {
                settingsNavigationLabel("工具与自动化", icon: .toolAutomation)
            }

            NavigationLink {
                SettingsCategoryList(title: "语音与媒体") {
                    voiceAndMediaSettingsSection
                }
            } label: {
                settingsNavigationLabel("语音与媒体", icon: .voiceAndMedia)
            }
        }

        Section {
            NavigationLink {
                SettingsCategoryList(title: "显示与外观") {
                    displayAppearanceSettingsSection
                }
            } label: {
                settingsNavigationLabel("显示与外观", icon: .display)
            }

            NavigationLink {
                SettingsCategoryList(title: "数据与维护") {
                    dataMaintenanceSettingsSection
                }
            } label: {
                settingsNavigationLabel("数据与维护", icon: .dataMaintenance)
            }

            NavigationLink {
                SettingsCategoryList(title: "支持与关于") {
                    supportAboutSettingsSection
                }
            } label: {
                settingsNavigationLabel("支持与关于", icon: .supportAbout)
            }
        }
    }

    @ViewBuilder
    private var conversationAndModelSettingsSection: some View {
        Section {
            NavigationLink(destination: sessionListDestination) {
                settingsNavigationLabel("历史会话管理", icon: .sessionHistory)
            }

            NavigationLink(destination: ProviderListView().environmentObject(viewModel)) {
                settingsNavigationLabel("提供商与模型管理", icon: .providerManagement)
            }

            NavigationLink(destination: modelAdvancedSettingsDestination) {
                settingsNavigationLabel("偏好设置", icon: .modelAdvanced)
            }

            NavigationLink(destination: UsageAnalyticsView()) {
                settingsNavigationLabel("用量统计", icon: .usageAnalytics)
            }
        }
    }

    @ViewBuilder
    private var aiCapabilitySettingsSection: some View {
        Section {
            NavigationLink {
                LongTermMemoryFeatureView()
                    .environmentObject(viewModel)
            } label: {
                settingsNavigationLabel("记忆系统", icon: .memory)
            }

            NavigationLink {
                WorldbookSettingsView(viewModel: viewModel)
            } label: {
                settingsNavigationLabel("世界书", icon: .worldbook)
            }

            NavigationLink {
                AgentSkillsView()
            } label: {
                settingsNavigationLabel("Agent Skills", icon: .agentSkills)
            }

            NavigationLink(destination: DailyPulseView(viewModel: viewModel)) {
                settingsStatusLabel(
                    "每日脉冲",
                    icon: .dailyPulse,
                    status: dailyPulseEntryStatusText,
                    statusColor: pulseManager.hasUnviewedTodayRun ? .blue : .secondary
                )
            }
        }
    }

    @ViewBuilder
    private var toolAutomationSettingsSection: some View {
        Section {
            NavigationLink {
                ToolCenterView()
                    .environmentObject(viewModel)
            } label: {
                settingsNavigationLabel("工具中心", icon: .toolCenter)
            }

            NavigationLink {
                MCPIntegrationView()
            } label: {
                settingsNavigationLabel("MCP 工具集成", icon: .mcp)
            }

            NavigationLink {
                ShortcutIntegrationView()
            } label: {
                settingsNavigationLabel("快捷指令工具集成", icon: .shortcuts)
            }
        }
    }

    @ViewBuilder
    private var voiceAndMediaSettingsSection: some View {
        Section {
            NavigationLink {
                speechInputSettingsDestination
            } label: {
                settingsNavigationLabel("语音输入", icon: .speechInput)
            }

            NavigationLink {
                TTSSettingsView()
                    .environmentObject(viewModel)
            } label: {
                settingsNavigationLabel("语音朗读（TTS）", icon: .tts)
            }

            NavigationLink {
                ImageGenerationFeatureView()
                    .environmentObject(viewModel)
            } label: {
                settingsNavigationLabel("图片生成", icon: .imageGeneration)
            }
        }
    }

    @ViewBuilder
    private var displayAppearanceSettingsSection: some View {
        Section {
            NavigationLink(destination: displaySettingsDestination) {
                settingsNavigationLabel("显示与外观", icon: .display)
            }
        }
    }

    @ViewBuilder
    private var dataMaintenanceSettingsSection: some View {
        Section {
            NavigationLink(destination: DeviceSyncSettingsView()) {
                settingsNavigationLabel("同步与备份", icon: .sync)
            }

            NavigationLink {
                StorageManagementView()
            } label: {
                settingsNavigationLabel("存储管理", icon: .storage)
            }

            NavigationLink {
                ThirdPartyImportWatchHintView()
            } label: {
                settingsNavigationLabel("导入数据", icon: .importData)
            }

            NavigationLink {
                LocalDebugView()
            } label: {
                settingsNavigationLabel("远程文件访问", icon: .remoteFiles)
            }
        }
    }

    @ViewBuilder
    private var supportAboutSettingsSection: some View {
        Section {
            NavigationLink {
                FeedbackCenterView()
            } label: {
                settingsNavigationLabel("反馈助手", icon: .feedback)
            }

            if achievementCenter.hasUnlockedAchievements {
                NavigationLink {
                    AchievementJournalView()
                } label: {
                    settingsNavigationLabel("成就日记", icon: .achievementJournal)
                }
            }

            NavigationLink(destination: SettingsLaboratoryView(canUseBetaSettingsHome: canUseBetaSettingsHome)) {
                settingsNavigationLabel("设置实验室", icon: .settingsLaboratory)
            }

            NavigationLink(destination: AboutView()) {
                settingsNavigationLabel("关于", icon: .about)
            }
        }
    }

    private var sessionListDestination: some View {
        SessionListView(
            sessions: $viewModel.chatSessions,
            folders: $viewModel.sessionFolders,
            currentSession: $viewModel.currentSession,
            runningSessionIDs: viewModel.runningSessionIDs,
            deleteSessionAction: { session in
                viewModel.deleteSessions([session])
            },
            branchAction: { session, copyMessages in
                let newSession = viewModel.branchSession(from: session, copyMessages: copyMessages)
                return newSession
            },
            deleteLastMessageAction: { session in
                viewModel.deleteLastMessage(for: session)
            },
            sendSessionToCompanionAction: { session in
                WatchSyncManager.shared.sendSessionToCompanion(sessionID: session.id)
            },
            onSessionSelected: { selectedSession, messageOrdinal in
                if let messageOrdinal {
                    viewModel.requestMessageJump(
                        sessionID: selectedSession.id,
                        messageOrdinal: messageOrdinal
                    )
                } else {
                    viewModel.clearPendingMessageJumpTarget()
                }
                ChatService.shared.setCurrentSession(selectedSession)
                dismiss()
            },
            updateSessionAction: { session in
                viewModel.updateSession(session)
            },
            createFolderAction: { name, parentID in
                viewModel.createSessionFolder(name: name, parentID: parentID)
            },
            renameFolderAction: { folder, newName in
                viewModel.renameSessionFolder(folder, newName: newName)
            },
            deleteFolderAction: { folder in
                viewModel.deleteSessionFolder(folder)
            },
            moveSessionToFolderAction: { session, folderID in
                viewModel.moveSession(session, toFolderID: folderID)
            }
        )
    }

    private var modelAdvancedSettingsDestination: some View {
        ModelAdvancedSettingsView(
            aiTemperature: $viewModel.aiTemperature,
            aiTopP: $viewModel.aiTopP,
            globalSystemPromptEntries: $viewModel.globalSystemPromptEntries,
            selectedGlobalSystemPromptEntryID: $viewModel.selectedGlobalSystemPromptEntryID,
            maxChatHistory: $viewModel.maxChatHistory,
            lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
            enableStreaming: $viewModel.enableStreaming,
            enableResponseSpeedMetrics: $viewModel.enableResponseSpeedMetrics,
            enableOpenAIStreamIncludeUsage: $viewModel.enableOpenAIStreamIncludeUsage,
            enableAutoSessionNaming: $viewModel.enableAutoSessionNaming,
            enableReasoningSummary: $viewModel.enableReasoningSummary,
            currentSession: $viewModel.currentSession,
            includeSystemTimeInPrompt: $viewModel.includeSystemTimeInPrompt,
            enablePeriodicTimeLandmark: $viewModel.enablePeriodicTimeLandmark,
            periodicTimeLandmarkIntervalMinutes: $viewModel.periodicTimeLandmarkIntervalMinutes,
            addGlobalSystemPromptEntry: viewModel.addGlobalSystemPromptEntry,
            selectGlobalSystemPromptEntry: viewModel.selectGlobalSystemPromptEntry,
            updateSelectedGlobalSystemPromptContent: viewModel.updateSelectedGlobalSystemPromptContent,
            updateGlobalSystemPromptEntry: viewModel.updateGlobalSystemPromptEntry,
            deleteGlobalSystemPromptEntry: { viewModel.deleteGlobalSystemPromptEntry(id: $0) }
        )
    }

    private var displaySettingsDestination: some View {
        DisplaySettingsView(
            enableMarkdown: $viewModel.enableMarkdown,
            enableBackground: $viewModel.enableBackground,
            backgroundBlur: $viewModel.backgroundBlur,
            backgroundOpacity: $viewModel.backgroundOpacity,
            enableAutoRotateBackground: $viewModel.enableAutoRotateBackground,
            currentBackgroundImage: $viewModel.currentBackgroundImage,
            backgroundContentMode: $viewModel.backgroundContentMode,
            enableLiquidGlass: $viewModel.enableLiquidGlass,
            enableAdvancedRenderer: $viewModel.enableAdvancedRenderer,
            enableAutoReasoningPreview: $viewModel.enableAutoReasoningPreview,
            enableNoBubbleUI: $viewModel.enableNoBubbleUI,
            allBackgrounds: viewModel.backgroundImages
        )
    }

    private var speechInputSettingsDestination: some View {
        SpeechInputSettingsView(
            enableSpeechInput: $viewModel.enableSpeechInput,
            selectedSpeechModel: speechModelBinding,
            sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
            audioRecordingFormat: $viewModel.audioRecordingFormat,
            speechModels: viewModel.speechModels
        )
    }

    @ViewBuilder
    private func settingsNavigationLabel(_ title: LocalizedStringKey, icon: SettingsListIcon) -> some View {
        if usesNativeSettingsIcons {
            SettingsListIconLabel(title, icon: icon)
        } else {
            Label(title, systemImage: icon.legacySystemName)
        }
    }

    private func settingsStatusLabel(
        _ title: LocalizedStringKey,
        icon: SettingsListIcon,
        status: String?,
        statusColor: Color
    ) -> some View {
        HStack(spacing: 8) {
            if usesNativeSettingsIcons {
                SettingsListIconView(icon: icon)
                Text(title)
            } else {
                Label(title, systemImage: icon.legacySystemName)
            }
            Spacer()
            if let status {
                Text(status)
                    .etFont(.caption2)
                    .foregroundStyle(statusColor)
            }
        }
    }

    /// 根据公告类型返回对应图标
    @ViewBuilder
    private func announcementIcon(for type: AnnouncementType) -> some View {
        switch type {
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundColor(.blue)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .blocking:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
        @unknown default:
            Image(systemName: "bell.fill")
                .foregroundColor(.gray)
        }
    }

    private func ensureSelectedModel(in options: [RunnableModel]) {
        guard let first = options.first else { return }
        guard let selectedID = viewModel.selectedModel?.id,
              options.contains(where: { $0.id == selectedID }) else {
            viewModel.selectedModel = first
            ChatService.shared.setSelectedModel(first)
            return
        }
    }

    private func scheduleSettingsResearchAchievementIfNeeded() {
        cancelSettingsResearchAchievementTask()
        guard !AchievementCenter.shared.hasUnlocked(id: .settingsResearcher) else { return }

        let delay = UInt64(AchievementTriggerEvaluator.settingsResearchDuration * 1_000_000_000)
        settingsResearchTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            guard AchievementTriggerEvaluator.shouldUnlockSettingsResearcher(
                elapsedTime: AchievementTriggerEvaluator.settingsResearchDuration
            ) else { return }
            let hasUnlocked = AchievementCenter.shared.hasUnlocked(id: .settingsResearcher)
            guard !hasUnlocked else { return }
            await AchievementCenter.shared.unlock(id: .settingsResearcher)
        }
    }

    private func cancelSettingsResearchAchievementTask() {
        settingsResearchTask?.cancel()
        settingsResearchTask = nil
    }

    private func disableBetaSettingsHomeIfNeeded() {
        if !canUseBetaSettingsHome {
            useBetaSettingsHome = false
        }
    }

    private var selectedModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedModel },
            set: { model in
                viewModel.selectedModel = model
                ChatService.shared.setSelectedModel(model)
            }
        )
    }

    private var speechModelBinding: Binding<RunnableModel?> {
        Binding(
            get: { viewModel.selectedSpeechModel },
            set: { viewModel.setSelectedSpeechModel($0) }
        )
    }

    private func selectedModelLabel(in options: [RunnableModel]) -> String {
        if let selected = viewModel.selectedModel,
           options.contains(where: { $0.id == selected.id }) {
            return "\(selected.model.displayName) | \(selected.provider.name)"
        }
        guard let first = options.first else { return "" }
        return "\(first.model.displayName) | \(first.provider.name)"
    }

    private var dailyPulseEntryStatusText: String? {
        if pulseManager.isPreparingTodayPulse {
            return "准备中"
        }
        if pulseManager.hasUnviewedTodayRun {
            return "待查看"
        }
        if pulseManager.todayRun != nil {
            return "已生成"
        }
        if deliveryCoordinator.reminderEnabled {
            return deliveryCoordinator.reminderTimeText
        }
        return nil
    }
}

struct SettingsListIcon {
    let systemName: String
    let backgroundColor: Color
    let legacySystemName: String

    init(systemName: String, backgroundColor: Color, legacySystemName: String? = nil) {
        self.systemName = systemName
        self.backgroundColor = backgroundColor
        self.legacySystemName = legacySystemName ?? systemName
    }
}

extension SettingsListIcon {
    static let currentModel = SettingsListIcon(systemName: "cpu", backgroundColor: .blue)
    static let newConversation = SettingsListIcon(systemName: "plus", backgroundColor: .green, legacySystemName: "plus.message")
    static let sessionHistory = SettingsListIcon(
        systemName: "clock",
        backgroundColor: .indigo,
        legacySystemName: "list.bullet.rectangle"
    )
    static let providerManagement = SettingsListIcon(
        systemName: "cube",
        backgroundColor: .orange,
        legacySystemName: "list.bullet.rectangle.portrait"
    )
    static let modelAdvanced = SettingsListIcon(systemName: "gearshape", backgroundColor: .purple, legacySystemName: "brain.head.profile")
    static let tts = SettingsListIcon(systemName: "speaker", backgroundColor: .pink, legacySystemName: "speaker.wave.2")
    static let toolCenter = SettingsListIcon(systemName: "wrench", backgroundColor: .teal, legacySystemName: "slider.horizontal.3")
    static let dailyPulse = SettingsListIcon(systemName: "sparkles", backgroundColor: .yellow, legacySystemName: "sparkles.rectangle.stack")
    static let usageAnalytics = SettingsListIcon(systemName: "chart.bar", backgroundColor: .cyan, legacySystemName: "calendar.badge.clock")
    static let memory = SettingsListIcon(systemName: "brain", backgroundColor: .mint, legacySystemName: "brain.head.profile")
    static let mcp = SettingsListIcon(systemName: "network", backgroundColor: .blue)
    static let agentSkills = SettingsListIcon(systemName: "star", backgroundColor: .purple, legacySystemName: "sparkles.square.filled.on.square")
    static let shortcuts = SettingsListIcon(systemName: "bolt", backgroundColor: .orange, legacySystemName: "bolt.horizontal.circle")
    static let imageGeneration = SettingsListIcon(systemName: "photo", backgroundColor: .pink, legacySystemName: "photo.on.rectangle.angled")
    static let worldbook = SettingsListIcon(systemName: "book", backgroundColor: .brown, legacySystemName: "book.pages")
    static let speechInput = SettingsListIcon(systemName: "mic", backgroundColor: .red)
    static let extendedFeatures = SettingsListIcon(systemName: "ellipsis", backgroundColor: .indigo, legacySystemName: "puzzlepiece.extension")
    static let display = SettingsListIcon(systemName: "sun.max", backgroundColor: .purple, legacySystemName: "photo.on.rectangle")
    static let sync = SettingsListIcon(systemName: "arrow.clockwise", backgroundColor: .green, legacySystemName: "arrow.triangle.2.circlepath")
    static let about = SettingsListIcon(systemName: "info.circle", backgroundColor: .gray)
    static let achievementJournal = SettingsListIcon(systemName: "star", backgroundColor: .yellow, legacySystemName: "rosette")
    static let feedback = SettingsListIcon(systemName: "bubble", backgroundColor: .blue, legacySystemName: "text.bubble")
    static let remoteFiles = SettingsListIcon(systemName: "folder", backgroundColor: .gray, legacySystemName: "terminal")
    static let storage = SettingsListIcon(systemName: "archivebox", backgroundColor: .teal, legacySystemName: "internaldrive")
    static let importData = SettingsListIcon(
        systemName: "arrow.down",
        backgroundColor: .green,
        legacySystemName: "square.and.arrow.down.on.square"
    )
    static let conversationMemory = SettingsListIcon(systemName: "person", backgroundColor: .mint, legacySystemName: "person.text.rectangle")
    static let memoryLibrary = SettingsListIcon(systemName: "folder", backgroundColor: .orange, legacySystemName: "folder.badge.gearshape")
    static let settingsLaboratory = SettingsListIcon(systemName: "hammer", backgroundColor: .blue)
    static let conversationAndModels = SettingsListIcon(systemName: "bubble", backgroundColor: .blue)
    static let aiCapabilities = SettingsListIcon(systemName: "brain", backgroundColor: .purple, legacySystemName: "brain.head.profile")
    static let toolAutomation = SettingsListIcon(systemName: "wrench", backgroundColor: .teal, legacySystemName: "slider.horizontal.3")
    static let voiceAndMedia = SettingsListIcon(systemName: "waveform", backgroundColor: .pink)
    static let dataMaintenance = SettingsListIcon(systemName: "externaldrive", backgroundColor: .green, legacySystemName: "internaldrive")
    static let supportAbout = SettingsListIcon(systemName: "questionmark.bubble", backgroundColor: .gray)
}

struct SettingsListIconLabel: View {
    let title: LocalizedStringKey
    let icon: SettingsListIcon

    init(_ title: LocalizedStringKey, icon: SettingsListIcon) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 8) {
            SettingsListIconView(icon: icon)
            Text(title)
        }
    }
}

struct SettingsListIconView: View {
    let icon: SettingsListIcon

    var body: some View {
        Circle()
            .fill(icon.backgroundColor)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: icon.systemName)
                    .symbolVariant(.fill)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

private struct SettingsCategoryList<Content: View>: View {
    let title: LocalizedStringKey
    let content: () -> Content

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        List {
            content()
        }
        .navigationTitle(title)
    }
}

struct SettingsLaboratoryView: View {
    @AppStorage(SettingsHomeExperiment.storageKey) private var useBetaSettingsHome = false
    let canUseBetaSettingsHome: Bool

    init(canUseBetaSettingsHome: Bool) {
        self.canUseBetaSettingsHome = canUseBetaSettingsHome
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: betaSettingsHomeBinding) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("新版设置首页")
                            SettingsBetaBadge()
                        }

                        Text("开启后，设置首页会切换为分类收纳版；关闭后会立即恢复当前设置首页。")
                            .etFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!canUseBetaSettingsHome)
            } footer: {
                Text(footerText)
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置实验室")
        .onAppear {
            if !canUseBetaSettingsHome {
                useBetaSettingsHome = false
            }
        }
    }

    private var betaSettingsHomeBinding: Binding<Bool> {
        Binding(
            get: { canUseBetaSettingsHome && useBetaSettingsHome },
            set: { newValue in
                if canUseBetaSettingsHome {
                    useBetaSettingsHome = newValue
                }
            }
        )
    }

    private var footerText: LocalizedStringKey {
        if canUseBetaSettingsHome {
            return "这是仍在验证中的设置界面实验，默认关闭。"
        }
        return "watchOS 需要先在“显示与外观”里将界面架构切换为“原生导航”，沉浸浮层模式不会启用新版设置首页。"
    }
}

private struct SettingsBetaBadge: View {
    var body: some View {
        Text(verbatim: "Beta")
            .etFont(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                Capsule()
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
            }
            .accessibilityLabel("Beta")
    }
}

private struct ModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?

    var body: some View {
        List {
            ForEach(models) { model in
                Button {
                    select(model)
                } label: {
                    selectionRow(
                        title: model.model.displayName,
                        subtitle: "\(model.provider.name) · \(model.model.modelName)",
                        isSelected: selectedModel?.id == model.id
                    )
                }
            }
        }
        .navigationTitle("当前模型")
    }

    private func select(_ model: RunnableModel) {
        selectedModel = model
        dismiss()
    }

    @ViewBuilder
    private func selectionRow(title: String, subtitle: String? = nil, isSelected: Bool) -> some View {
        MarqueeTitleSubtitleSelectionRow(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            subtitleUIFont: .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                weight: .regular
            )
        )
    }
}

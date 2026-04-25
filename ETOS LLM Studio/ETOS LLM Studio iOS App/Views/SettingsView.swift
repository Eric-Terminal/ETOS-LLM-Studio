// ============================================================================
// SettingsView.swift
// ============================================================================
// SettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import Shared

enum SettingsNavigationDestination: Hashable, Identifiable {
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

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var announcementManager = AnnouncementManager.shared
    @ObservedObject private var pulseManager = DailyPulseManager.shared
    @ObservedObject private var deliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @ObservedObject private var achievementCenter = AchievementCenter.shared
    @Binding private var requestedDestination: SettingsNavigationDestination?
    @AppStorage(SettingsHomeExperiment.storageKey) private var useBetaSettingsHome = false
    @State private var settingsResearchTask: Task<Void, Never>?

    init(requestedDestination: Binding<SettingsNavigationDestination?> = .constant(nil)) {
        self._requestedDestination = requestedDestination
    }
    
    var body: some View {
        List {
            Section("当前模型") {
                let options = viewModel.activatedModels
                if options.isEmpty {
                    Text("暂无可用模型，请先在“提供商与模型管理”中启用。")
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        CurrentModelSelectionView(
                            models: options,
                            selectedModel: selectedModelBinding
                        )
                    } label: {
                        HStack(spacing: 8) {
                            SettingsListIconView(icon: .currentModel)
                            Text("模型")
                            Text(selectedModelLabel(in: options))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                
                Button {
                    viewModel.createNewSession()
                    dismiss()
                    NotificationCenter.default.post(name: .requestSwitchToChatTab, object: nil)
                } label: {
                    SettingsListIconLabel("开启新对话", icon: .newConversation)
                }
            }
            
            if useBetaSettingsHome {
                betaSettingsHomeSections
            } else {
                Section("对话行为") {
                NavigationLink {
                    SessionListView().environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("历史会话管理", icon: .sessionHistory)
                }

                NavigationLink {
                    ProviderListView().environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("提供商与模型管理", icon: .providerManagement)
                }
                
                NavigationLink {
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
                } label: {
                    SettingsListIconLabel("偏好设置", icon: .modelAdvanced)
                }

                NavigationLink {
                    TTSSettingsView()
                        .environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("语音朗读（TTS）", icon: .tts)
                }
            }

            Section("拓展能力") {
                let speechModelBinding = Binding<RunnableModel?>(
                    get: { viewModel.selectedSpeechModel },
                    set: { viewModel.setSelectedSpeechModel($0) }
                )
                NavigationLink {
                    ToolCenterView()
                        .environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("工具中心", icon: .toolCenter)
                }

                NavigationLink {
                    DailyPulseView()
                        .environmentObject(viewModel)
                } label: {
                    HStack(spacing: 8) {
                        SettingsListIconView(icon: .dailyPulse)
                        Text("每日脉冲")
                        Spacer()
                        if let status = dailyPulseEntryStatusText {
                            Text(status)
                                .etFont(.caption)
                                .foregroundStyle(pulseManager.hasUnviewedTodayRun ? .blue : .secondary)
                        }
                    }
                }

                NavigationLink {
                    UsageAnalyticsView()
                } label: {
                    SettingsListIconLabel("用量统计", icon: .usageAnalytics)
                }

                NavigationLink {
                    LongTermMemoryFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("记忆系统", icon: .memory)
                }

                NavigationLink {
                    MCPIntegrationView()
                } label: {
                    SettingsListIconLabel("MCP 工具集成", icon: .mcp)
                }

                NavigationLink {
                    AgentSkillsView()
                } label: {
                    SettingsListIconLabel("Agent Skills", icon: .agentSkills)
                }

                NavigationLink {
                    ShortcutIntegrationView()
                } label: {
                    SettingsListIconLabel("快捷指令工具集成", icon: .shortcuts)
                }

                NavigationLink {
                    ImageGenerationFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("图片生成", icon: .imageGeneration)
                }

                NavigationLink {
                    WorldbookSettingsView().environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("世界书", icon: .worldbook)
                }

                NavigationLink {
                    SpeechInputSettingsView(
                        enableSpeechInput: $viewModel.enableSpeechInput,
                        selectedSpeechModel: speechModelBinding,
                        sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
                        audioRecordingFormat: Binding(
                            get: { viewModel.audioRecordingFormat },
                            set: { viewModel.audioRecordingFormat = $0 }
                        ),
                        speechModels: viewModel.speechModels
                    )
                } label: {
                    SettingsListIconLabel("语音输入", icon: .speechInput)
                }

                NavigationLink {
                    ExtendedFeaturesView()
                } label: {
                    SettingsListIconLabel("拓展功能", icon: .extendedFeatures)
                }
            }
            
            Section("显示与体验") {
                NavigationLink {
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
                } label: {
                    SettingsListIconLabel("背景与视觉", icon: .display)
                }
                
                NavigationLink {
                    DeviceSyncSettingsView()
                } label: {
                    SettingsListIconLabel("同步与备份", icon: .sync)
                }
                
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsListIconLabel("关于 ETOS LLM Studio", icon: .about)
                }
            }
            }

            // MARK: - 公告通知 Section
            if announcementManager.shouldShowInSettings {
                Section("系统公告") {
                    ForEach(announcementManager.currentAnnouncements, id: \.uniqueKey) { announcement in
                        NavigationLink {
                            AnnouncementDetailView(
                                announcement: announcement,
                                announcementManager: announcementManager
                            )
                        } label: {
                            HStack {
                                announcementIcon(for: announcement.type)
                                Text(announcement.title)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("设置")
        .onAppear {
            ensureSelectedModel(in: viewModel.activatedModels)
            scheduleSettingsResearchAchievementIfNeeded()
        }
        .onDisappear {
            cancelSettingsResearchAchievementTask()
        }
        .onChange(of: viewModel.activatedModels.map(\.id)) { _, _ in
            ensureSelectedModel(in: viewModel.activatedModels)
        }
        .onChange(of: viewModel.enableMarkdown) { _, isEnabled in
            if !isEnabled, viewModel.enableAdvancedRenderer {
                viewModel.enableAdvancedRenderer = false
            }
        }
        .navigationDestination(item: $requestedDestination) { destination in
            switch destination {
            case .dailyPulse:
                DailyPulseView()
                    .environmentObject(viewModel)
            case .feedbackCenter:
                FeedbackCenterView()
            case .feedbackIssue(let issueNumber):
                FeedbackDetailView(issueNumber: issueNumber)
            case .achievementJournal:
                AchievementJournalView()
            }
        }
    }
    
    // MARK: - 辅助方法

    @ViewBuilder
    private var betaSettingsHomeSections: some View {
        Section {
            NavigationLink {
                SettingsCategoryList(title: "对话与模型") {
                    conversationAndModelSettingsSection
                }
            } label: {
                SettingsListIconLabel("对话与模型", icon: .conversationAndModels)
            }

            NavigationLink {
                SettingsCategoryList(title: "AI 能力") {
                    aiCapabilitySettingsSection
                }
            } label: {
                SettingsListIconLabel("AI 能力", icon: .aiCapabilities)
            }

            NavigationLink {
                SettingsCategoryList(title: "工具与自动化") {
                    toolAutomationSettingsSection
                }
            } label: {
                SettingsListIconLabel("工具与自动化", icon: .toolAutomation)
            }

            NavigationLink {
                SettingsCategoryList(title: "语音与媒体") {
                    voiceAndMediaSettingsSection
                }
            } label: {
                SettingsListIconLabel("语音与媒体", icon: .voiceAndMedia)
            }
        }

        Section {
            NavigationLink {
                SettingsCategoryList(title: "显示与外观") {
                    displayAppearanceSettingsSection
                }
            } label: {
                SettingsListIconLabel("显示与外观", icon: .display)
            }

            NavigationLink {
                SettingsCategoryList(title: "数据与维护") {
                    dataMaintenanceSettingsSection
                }
            } label: {
                SettingsListIconLabel("数据与维护", icon: .dataMaintenance)
            }

            NavigationLink {
                SettingsCategoryList(title: "支持与关于") {
                    supportAboutSettingsSection
                }
            } label: {
                SettingsListIconLabel("支持与关于", icon: .supportAbout)
            }
        }
    }

    @ViewBuilder
    private var conversationAndModelSettingsSection: some View {
        Section {
            NavigationLink {
                SessionListView().environmentObject(viewModel)
            } label: {
                SettingsListIconLabel("历史会话管理", icon: .sessionHistory)
            }

            NavigationLink {
                ProviderListView().environmentObject(viewModel)
            } label: {
                SettingsListIconLabel("提供商与模型管理", icon: .providerManagement)
            }

            NavigationLink {
                modelAdvancedSettingsDestination
            } label: {
                SettingsListIconLabel("偏好设置", icon: .modelAdvanced)
            }

            NavigationLink {
                UsageAnalyticsView()
            } label: {
                SettingsListIconLabel("用量统计", icon: .usageAnalytics)
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
                SettingsListIconLabel("记忆系统", icon: .memory)
            }

            NavigationLink {
                WorldbookSettingsView().environmentObject(viewModel)
            } label: {
                SettingsListIconLabel("世界书", icon: .worldbook)
            }

            NavigationLink {
                AgentSkillsView()
            } label: {
                SettingsListIconLabel("Agent Skills", icon: .agentSkills)
            }

            NavigationLink {
                DailyPulseView()
                    .environmentObject(viewModel)
            } label: {
                dailyPulseSettingsLabel
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
                SettingsListIconLabel("工具中心", icon: .toolCenter)
            }

            NavigationLink {
                MCPIntegrationView()
            } label: {
                SettingsListIconLabel("MCP 工具集成", icon: .mcp)
            }

            NavigationLink {
                ShortcutIntegrationView()
            } label: {
                SettingsListIconLabel("快捷指令工具集成", icon: .shortcuts)
            }
        }
    }

    @ViewBuilder
    private var voiceAndMediaSettingsSection: some View {
        Section {
            NavigationLink {
                speechInputSettingsDestination
            } label: {
                SettingsListIconLabel("语音输入", icon: .speechInput)
            }

            NavigationLink {
                TTSSettingsView()
                    .environmentObject(viewModel)
            } label: {
                SettingsListIconLabel("语音朗读（TTS）", icon: .tts)
            }

            NavigationLink {
                ImageGenerationFeatureView()
                    .environmentObject(viewModel)
            } label: {
                SettingsListIconLabel("图片生成", icon: .imageGeneration)
            }
        }
    }

    @ViewBuilder
    private var displayAppearanceSettingsSection: some View {
        Section {
            NavigationLink {
                displaySettingsDestination
            } label: {
                SettingsListIconLabel("背景与视觉", icon: .display)
            }
        }
    }

    @ViewBuilder
    private var dataMaintenanceSettingsSection: some View {
        Section {
            NavigationLink {
                DeviceSyncSettingsView()
            } label: {
                SettingsListIconLabel("同步与备份", icon: .sync)
            }

            NavigationLink {
                StorageManagementView()
            } label: {
                SettingsListIconLabel("存储管理", icon: .storage)
            }

            NavigationLink {
                ThirdPartyImportView()
            } label: {
                SettingsListIconLabel("导入数据", icon: .importData)
            }

            NavigationLink {
                LocalDebugView()
            } label: {
                SettingsListIconLabel("远程文件访问", icon: .remoteFiles)
            }
        }
    }

    @ViewBuilder
    private var supportAboutSettingsSection: some View {
        Section {
            NavigationLink {
                FeedbackCenterView()
            } label: {
                SettingsListIconLabel("反馈助手", icon: .feedback)
            }

            if achievementCenter.hasUnlockedAchievements {
                NavigationLink {
                    AchievementJournalView()
                } label: {
                    SettingsListIconLabel("成就日记", icon: .achievementJournal)
                }
            }

            NavigationLink {
                SettingsLaboratoryView()
            } label: {
                SettingsListIconLabel("设置实验室", icon: .settingsLaboratory)
            }

            NavigationLink {
                AboutView()
            } label: {
                SettingsListIconLabel("关于 ETOS LLM Studio", icon: .about)
            }
        }
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
            audioRecordingFormat: Binding(
                get: { viewModel.audioRecordingFormat },
                set: { viewModel.audioRecordingFormat = $0 }
            ),
            speechModels: viewModel.speechModels
        )
    }

    private var dailyPulseSettingsLabel: some View {
        HStack(spacing: 8) {
            SettingsListIconView(icon: .dailyPulse)
            Text("每日脉冲")
            Spacer()
            if let status = dailyPulseEntryStatusText {
                Text(status)
                    .etFont(.caption)
                    .foregroundStyle(pulseManager.hasUnviewedTodayRun ? .blue : .secondary)
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

    private var dailyPulseEntryStatusText: String? {
        if pulseManager.isPreparingTodayPulse {
            return "准备中"
        }
        if pulseManager.hasUnviewedTodayRun {
            return "今日待查看"
        }
        if pulseManager.todayRun != nil {
            return "今日已生成"
        }
        if deliveryCoordinator.reminderEnabled {
            return "明早 \(deliveryCoordinator.reminderTimeText)"
        }
        return nil
    }

    private func selectedModelLabel(in options: [RunnableModel]) -> String {
        if let selected = viewModel.selectedModel,
           options.contains(where: { $0.id == selected.id }) {
            return "\(selected.model.displayName) | \(selected.provider.name)"
        }

        guard let first = options.first else { return "" }
        return "\(first.model.displayName) | \(first.provider.name)"
    }
}

struct SettingsListIcon {
    let systemName: String
    let backgroundColor: Color
}

extension SettingsListIcon {
    static let currentModel = SettingsListIcon(systemName: "cpu", backgroundColor: .blue)
    static let newConversation = SettingsListIcon(systemName: "plus", backgroundColor: .green)
    static let sessionHistory = SettingsListIcon(systemName: "clock", backgroundColor: .indigo)
    static let providerManagement = SettingsListIcon(systemName: "cube", backgroundColor: .orange)
    static let modelAdvanced = SettingsListIcon(systemName: "gearshape", backgroundColor: .purple)
    static let tts = SettingsListIcon(systemName: "speaker", backgroundColor: .pink)
    static let toolCenter = SettingsListIcon(systemName: "wrench", backgroundColor: .teal)
    static let dailyPulse = SettingsListIcon(systemName: "sparkles", backgroundColor: .yellow)
    static let usageAnalytics = SettingsListIcon(systemName: "chart.bar", backgroundColor: .cyan)
    static let memory = SettingsListIcon(systemName: "brain", backgroundColor: .mint)
    static let mcp = SettingsListIcon(systemName: "network", backgroundColor: .blue)
    static let agentSkills = SettingsListIcon(systemName: "star", backgroundColor: .purple)
    static let shortcuts = SettingsListIcon(systemName: "bolt", backgroundColor: .orange)
    static let imageGeneration = SettingsListIcon(systemName: "photo", backgroundColor: .pink)
    static let worldbook = SettingsListIcon(systemName: "book", backgroundColor: .brown)
    static let speechInput = SettingsListIcon(systemName: "mic", backgroundColor: .red)
    static let extendedFeatures = SettingsListIcon(systemName: "ellipsis", backgroundColor: .indigo)
    static let display = SettingsListIcon(systemName: "sun.max", backgroundColor: .purple)
    static let sync = SettingsListIcon(systemName: "arrow.clockwise", backgroundColor: .green)
    static let about = SettingsListIcon(systemName: "info.circle", backgroundColor: .gray)
    static let achievementJournal = SettingsListIcon(systemName: "star", backgroundColor: .yellow)
    static let feedback = SettingsListIcon(systemName: "bubble", backgroundColor: .blue)
    static let remoteFiles = SettingsListIcon(systemName: "folder", backgroundColor: .gray)
    static let storage = SettingsListIcon(systemName: "archivebox", backgroundColor: .teal)
    static let importData = SettingsListIcon(systemName: "arrow.down", backgroundColor: .green)
    static let conversationMemory = SettingsListIcon(systemName: "person", backgroundColor: .mint)
    static let memoryLibrary = SettingsListIcon(systemName: "folder", backgroundColor: .orange)
    static let settingsLaboratory = SettingsListIcon(systemName: "hammer", backgroundColor: .blue)
    static let conversationAndModels = SettingsListIcon(systemName: "bubble", backgroundColor: .blue)
    static let aiCapabilities = SettingsListIcon(systemName: "brain", backgroundColor: .purple)
    static let toolAutomation = SettingsListIcon(systemName: "wrench", backgroundColor: .teal)
    static let voiceAndMedia = SettingsListIcon(systemName: "waveform", backgroundColor: .pink)
    static let dataMaintenance = SettingsListIcon(systemName: "externaldrive", backgroundColor: .green)
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

    init() {}

    var body: some View {
        List {
            Section {
                Toggle(isOn: $useBetaSettingsHome) {
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
            } footer: {
                Text("这是仍在验证中的设置界面实验，默认关闭。")
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置实验室")
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

private struct CurrentModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?

    var body: some View {
        List {
            ForEach(models) { model in
                Button {
                    select(model)
                } label: {
                    MarqueeTitleSubtitleSelectionRow(
                        title: model.model.displayName,
                        subtitle: "\(model.provider.name) · \(model.model.modelName)",
                        isSelected: selectedModel?.id == model.id,
                        subtitleUIFont: .monospacedSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                            weight: .regular
                        )
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
}

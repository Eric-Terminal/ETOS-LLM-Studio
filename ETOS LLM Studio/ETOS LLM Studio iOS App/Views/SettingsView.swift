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

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var announcementManager = AnnouncementManager.shared
    @ObservedObject private var pulseManager = DailyPulseManager.shared
    @ObservedObject private var deliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @Binding private var requestedDestination: SettingsNavigationDestination?
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
                    SettingsListIconLabel("高级模型设置", icon: .modelAdvanced)
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
                    SettingsListIconLabel(NSLocalizedString("工具中心", comment: "Tool center title"), icon: .toolCenter)
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
                    SettingsListIconLabel(NSLocalizedString("图片生成", comment: "Image generation feature entry title"), icon: .imageGeneration)
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
                            HStack(spacing: 8) {
                                SettingsListIconView(icon: announcementIcon(for: announcement.type))
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
    
    private func announcementIcon(for type: AnnouncementType) -> SettingsListIcon {
        switch type {
        case .info:
            return .announcementInfo
        case .warning:
            return .announcementWarning
        case .blocking:
            return .announcementBlocking
        @unknown default:
            return .announcementInfo
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
    static let announcementInfo = SettingsListIcon(systemName: "info.circle", backgroundColor: .blue)
    static let announcementWarning = SettingsListIcon(systemName: "exclamationmark.triangle", backgroundColor: .orange)
    static let announcementBlocking = SettingsListIcon(systemName: "exclamationmark.octagon", backgroundColor: .red)
}

struct SettingsListIconLabel: View {
    let title: String
    let icon: SettingsListIcon

    init(_ title: String, icon: SettingsListIcon) {
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
                    .font(.system(size: 3, weight: .regular))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
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

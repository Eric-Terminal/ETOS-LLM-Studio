// ============================================================================
// SettingsView.swift
// ============================================================================
// SettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

enum SettingsNavigationDestination: Hashable, Identifiable {
    case dailyPulse
    case dailyPulseCard(runID: UUID, cardID: UUID)
    case feedbackCenter
    case feedbackIssue(issueNumber: Int)
    case achievementJournal
    case updateTimeline

    var id: String {
        switch self {
        case .dailyPulse:
            return "dailyPulse"
        case .dailyPulseCard(let runID, let cardID):
            return "dailyPulseCard-\(runID.uuidString)-\(cardID.uuidString)"
        case .feedbackCenter:
            return "feedbackCenter"
        case .feedbackIssue(let issueNumber):
            return "feedbackIssue-\(issueNumber)"
        case .achievementJournal:
            return "achievementJournal"
        case .updateTimeline:
            return "updateTimeline"
        }
    }
}

private enum CoreSettingsNavigationDestination: Hashable {
    case modelManagement
    case conversation
    case prompts
    case output
    case display
    case sync
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var announcementManager = AnnouncementManager.shared
    @ObservedObject private var pulseManager = DailyPulseManager.shared
    @ObservedObject private var deliveryCoordinator = DailyPulseDeliveryCoordinator.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @Binding private var requestedDestination: SettingsNavigationDestination?
    @State private var coreSettingsDestination: CoreSettingsNavigationDestination?
    @State private var settingsResearchTask: Task<Void, Never>?

    init(requestedDestination: Binding<SettingsNavigationDestination?> = .constant(nil)) {
        self._requestedDestination = requestedDestination
    }
    
    var body: some View {
        List {
            Section {
                Grid {
                    GridRow {
                        Button {
                            coreSettingsDestination = .modelManagement
                        } label: {
                            SettingsCategoryCard("模型管理", icon: .providerManagement)
                        }
                        .buttonStyle(.plain)

                        Button {
                            coreSettingsDestination = .conversation
                        } label: {
                            SettingsCategoryCard("会话", icon: .conversationSettings)
                        }
                        .buttonStyle(.plain)
                    }

                    GridRow {
                        Button {
                            coreSettingsDestination = .prompts
                        } label: {
                            SettingsCategoryCard("提示词", icon: .promptSettings)
                        }
                        .buttonStyle(.plain)

                        Button {
                            coreSettingsDestination = .output
                        } label: {
                            SettingsCategoryCard("输出", icon: .outputSettings)
                        }
                        .buttonStyle(.plain)
                    }

                    GridRow {
                        Button {
                            coreSettingsDestination = .display
                        } label: {
                            SettingsCategoryCard("背景与视觉", icon: .display)
                        }
                        .buttonStyle(.plain)

                        Button {
                            coreSettingsDestination = .sync
                        } label: {
                            SettingsCategoryCard("同步与备份", icon: .sync)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section(NSLocalizedString("拓展能力", comment: "设置拓展能力分组")) {
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
                        settingsListIcon(.dailyPulse)
                        Text(NSLocalizedString("每日脉冲", comment: "每日脉冲入口标题"))
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
                    RoleplaySettingsView().environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("角色扮演与酒馆兼容", icon: .roleplay)
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
                        .environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("拓展功能", icon: .extendedFeatures)
                }
            }
            // MARK: - 公告通知 Section
            if announcementManager.shouldShowInSettings {
                Section(NSLocalizedString("系统公告", comment: "系统公告分组")) {
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

            Section(NSLocalizedString("关于", comment: "设置关于分组")) {
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsListIconLabel("关于 ETOS LLM Studio", icon: .about)
                }
            }
        }
        .navigationTitle(NSLocalizedString("设置", comment: "设置页标题"))
        .onAppear {
            scheduleSettingsResearchAchievementIfNeeded()
        }
        .onDisappear {
            cancelSettingsResearchAchievementTask()
        }
        .onChange(of: viewModel.enableMarkdown) { _, isEnabled in
            if !isEnabled, viewModel.enableAdvancedRenderer {
                viewModel.enableAdvancedRenderer = false
            }
        }
        .navigationDestination(item: $coreSettingsDestination) { destination in
            switch destination {
            case .modelManagement:
                ProviderListView()
                    .environmentObject(viewModel)
            case .conversation:
                advancedSettingsView(destination: .conversation)
            case .prompts:
                advancedSettingsView(destination: .prompts)
            case .output:
                advancedSettingsView(destination: .output)
            case .display:
                DisplaySettingsView(
                    enableMarkdown: $viewModel.enableMarkdown,
                    enableBackground: $viewModel.enableBackground,
                    backgroundBlur: $viewModel.backgroundBlur,
                    backgroundOpacity: $viewModel.backgroundOpacity,
                    enableAutoRotateBackground: $viewModel.enableAutoRotateBackground,
                    currentBackgroundImage: $viewModel.currentBackgroundImage,
                    backgroundContentMode: $viewModel.backgroundContentMode,
                    enableLiquidGlass: $viewModel.enableLiquidGlass,
                    enableChatTopBlurFade: $viewModel.enableChatTopBlurFade,
                    enableAdvancedRenderer: $viewModel.enableAdvancedRenderer,
                    enableAutoReasoningPreview: $viewModel.enableAutoReasoningPreview,
                    enableNoBubbleUI: $viewModel.enableNoBubbleUI,
                    allBackgrounds: viewModel.backgroundImages
                )
            case .sync:
                DeviceSyncSettingsView()
            }
        }
        .navigationDestination(item: $requestedDestination) { destination in
            switch destination {
            case .dailyPulse:
                DailyPulseView()
                    .environmentObject(viewModel)
            case .dailyPulseCard(let runID, let cardID):
                DailyPulseView(initialRunID: runID, initialCardID: cardID)
                    .environmentObject(viewModel)
            case .feedbackCenter:
                FeedbackCenterView()
            case .feedbackIssue(let issueNumber):
                FeedbackDetailView(issueNumber: issueNumber)
            case .achievementJournal:
                AchievementJournalView()
            case .updateTimeline:
                UpdateTimelineView()
            }
        }
    }

    // MARK: - 辅助方法

    @ViewBuilder
    private func settingsListIcon(_ icon: SettingsListIcon) -> some View {
        if appConfig.settingsColorfulIconsEnabled {
            SettingsListIconView(icon: icon)
        } else {
            SettingsListPlainIconView(icon: icon)
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

    private var dailyPulseEntryStatusText: String? {
        if pulseManager.isPreparingTodayPulse {
            return NSLocalizedString("准备中", comment: "每日脉冲准备中状态")
        }
        if pulseManager.hasUnviewedTodayRun {
            return NSLocalizedString("今日待查看", comment: "每日脉冲今日未查看状态")
        }
        if pulseManager.todayRun != nil {
            return NSLocalizedString("今日已生成", comment: "每日脉冲今日已生成状态")
        }
        if pulseManager.tomorrowRun != nil {
            return NSLocalizedString("明日已准备", comment: "每日脉冲明日已准备状态")
        }
        if deliveryCoordinator.reminderEnabled {
            return deliveryCoordinator.deliveryTimes.count == 1
                ? deliveryCoordinator.reminderTimeText
                : String(
                    format: NSLocalizedString("%d 个时间点", comment: "Daily Pulse delivery time count"),
                    deliveryCoordinator.deliveryTimes.count
                )
        }
        return nil
    }

    private func advancedSettingsView(
        destination: ModelAdvancedSettingsDestination
    ) -> ModelAdvancedSettingsView {
        ModelAdvancedSettingsView(
            aiTemperature: $viewModel.aiTemperature,
            aiTopP: $viewModel.aiTopP,
            aiTemperatureEnabled: $viewModel.aiTemperatureEnabled,
            aiTopPEnabled: $viewModel.aiTopPEnabled,
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
            systemTimeInjectionPosition: $viewModel.systemTimeInjectionPosition,
            enablePeriodicTimeLandmark: $viewModel.enablePeriodicTimeLandmark,
            periodicTimeLandmarkIntervalMinutes: $viewModel.periodicTimeLandmarkIntervalMinutes,
            addGlobalSystemPromptEntry: viewModel.addGlobalSystemPromptEntry,
            selectGlobalSystemPromptEntry: viewModel.selectGlobalSystemPromptEntry,
            updateSelectedGlobalSystemPromptContent: viewModel.updateSelectedGlobalSystemPromptContent,
            updateGlobalSystemPromptEntry: viewModel.updateGlobalSystemPromptEntry,
            deleteGlobalSystemPromptEntry: { viewModel.deleteGlobalSystemPromptEntry(id: $0) },
            destination: destination
        )
    }
}

struct SettingsListIcon {
    let systemName: String
    let backgroundColor: Color
}

extension SettingsListIcon {
    static let chatQuickAction = SettingsListIcon(systemName: "ellipsis.circle", backgroundColor: .indigo)
    static let slashCommands = SettingsListIcon(systemName: "terminal", backgroundColor: .indigo)
    static let providerManagement = SettingsListIcon(systemName: "cube", backgroundColor: .orange)
    static let conversationSettings = SettingsListIcon(systemName: "bubble.left.and.bubble.right", backgroundColor: .indigo)
    static let promptSettings = SettingsListIcon(systemName: "text.quote", backgroundColor: .purple)
    static let outputSettings = SettingsListIcon(systemName: "waveform", backgroundColor: .blue)
    static let toolCenter = SettingsListIcon(systemName: "wrench", backgroundColor: .teal)
    static let dailyPulse = SettingsListIcon(systemName: "sparkles", backgroundColor: .yellow)
    static let usageAnalytics = SettingsListIcon(systemName: "chart.bar", backgroundColor: .cyan)
    static let memory = SettingsListIcon(systemName: "brain", backgroundColor: .mint)
    static let mcp = SettingsListIcon(systemName: "network", backgroundColor: .blue)
    static let agentSkills = SettingsListIcon(systemName: "star", backgroundColor: .purple)
    static let shortcuts = SettingsListIcon(systemName: "bolt", backgroundColor: .orange)
    static let imageGeneration = SettingsListIcon(systemName: "photo", backgroundColor: .pink)
    static let worldbook = SettingsListIcon(systemName: "book", backgroundColor: .brown)
    static let roleplay = SettingsListIcon(systemName: "theatermasks", backgroundColor: .purple)
    static let speechInput = SettingsListIcon(systemName: "mic", backgroundColor: .red)
    static let extendedFeatures = SettingsListIcon(systemName: "ellipsis", backgroundColor: .indigo)
    static let backgroundGeneration = SettingsListIcon(systemName: "location", backgroundColor: .green)
    static let localModels = SettingsListIcon(systemName: "cpu", backgroundColor: .blue)
    static let display = SettingsListIcon(systemName: "sun.max", backgroundColor: .purple)
    static let sync = SettingsListIcon(systemName: "arrow.clockwise", backgroundColor: .green)
    static let security = SettingsListIcon(systemName: "lock", backgroundColor: .red)
    static let about = SettingsListIcon(systemName: "info.circle", backgroundColor: .gray)
    static let achievementJournal = SettingsListIcon(systemName: "star", backgroundColor: .yellow)
    static let feedback = SettingsListIcon(systemName: "bubble", backgroundColor: .blue)
    static let remoteFiles = SettingsListIcon(systemName: "folder", backgroundColor: .gray)
    static let storage = SettingsListIcon(systemName: "archivebox", backgroundColor: .teal)
    static let importData = SettingsListIcon(systemName: "arrow.down", backgroundColor: .green)
    static let conversationMemory = SettingsListIcon(systemName: "person", backgroundColor: .mint)
    static let memoryLibrary = SettingsListIcon(systemName: "folder", backgroundColor: .orange)
}

struct SettingsListIconLabel: View {
    let title: String
    let icon: SettingsListIcon
    @ObservedObject private var appConfig = AppConfigStore.shared

    init(_ titleKey: String, icon: SettingsListIcon) {
        self.title = NSLocalizedString(titleKey, comment: "设置列表入口标题")
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 8) {
            if appConfig.settingsColorfulIconsEnabled {
                SettingsListIconView(icon: icon)
            } else {
                SettingsListPlainIconView(icon: icon)
            }
            Text(title)
        }
    }
}

private struct SettingsCategoryCard: View {
    let title: String
    let icon: SettingsListIcon
    @ObservedObject private var appConfig = AppConfigStore.shared

    init(_ titleKey: String, icon: SettingsListIcon) {
        self.title = NSLocalizedString(titleKey, comment: "核心设置分类入口标题")
        self.icon = icon
    }

    var body: some View {
        VStack(alignment: .leading) {
            categoryIcon
            Spacer()
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .aspectRatio(2, contentMode: .fit)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var categoryIcon: some View {
        if appConfig.settingsColorfulIconsEnabled {
            Image(systemName: icon.systemName)
                .symbolVariant(.fill)
                .font(.title2.weight(.semibold))
                .foregroundStyle(icon.backgroundColor)
                .accessibilityHidden(true)
        } else {
            Image(systemName: icon.systemName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
        }
    }
}

struct SettingsListPlainIconView: View {
    let icon: SettingsListIcon

    var body: some View {
        Image(systemName: icon.systemName)
            .font(.system(size: 17, weight: .regular))
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
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

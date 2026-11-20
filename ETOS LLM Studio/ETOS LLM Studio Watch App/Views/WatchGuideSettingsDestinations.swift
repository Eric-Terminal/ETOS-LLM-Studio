import ETOSCore
import SwiftUI

extension SettingsView {
    @ViewBuilder
    func guidePage(_ target: GuideNavigationDestination) -> some View {
        switch target {
        case .providerManagement: ProviderListView()
        case .conversationSettings: advancedSettingsView(destination: .conversation)
        case .promptSettings: advancedSettingsView(destination: .prompts)
        case .outputSettings: advancedSettingsView(destination: .output)
        case .appearanceSettings: displayPage
        case .syncAndBackup: DeviceSyncSettingsView()
        case .dataImport: ThirdPartyImportWatchHintView()
        case .roleplayAndTavern: RoleplaySettingsView(viewModel: viewModel)
        case .worldbook: WorldbookSettingsView(viewModel: viewModel)
        case .memorySystem: LongTermMemoryFeatureView()
        case .dailyPulse: DailyPulseView(viewModel: viewModel)
        case .toolCenter: ToolCenterView()
        case .mcpTools: MCPIntegrationView()
        case .shortcutTools: ShortcutIntegrationView()
        case .agentSkills: AgentSkillsView()
        case .speechInput:
            SpeechInputSettingsView(
                enableSpeechInput: $viewModel.enableSpeechInput,
                selectedSpeechModel: Binding(get: { viewModel.selectedSpeechModel }, set: { viewModel.setSelectedSpeechModel($0) }),
                sendSpeechAsAudio: $viewModel.sendSpeechAsAudio,
                audioRecordingFormat: $viewModel.audioRecordingFormat,
                speechModels: viewModel.speechModels
            )
        case .ttsSettings: TTSSettingsView()
        case .localLinux: LocalLinuxWatchFeatureView(sessionID: viewModel.currentSession?.id)
        case .networkProxy: GlobalProxySettingsView()
        case .connectionExceptions: NetworkConnectionSecuritySettingsView { AnyView($0.watchGuideEntry()) }
        case .feedbackCenter: FeedbackCenterView()
        case .feedbackCompose: WatchFeedbackComposeView()
        case .aboutAndLogs: AboutView()
        }
    }
}

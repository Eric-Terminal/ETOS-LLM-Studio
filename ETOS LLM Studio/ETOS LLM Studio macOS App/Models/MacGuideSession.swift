import Combine
import ETOSCore
import SwiftUI

@MainActor
final class MacGuideSession: ObservableObject {
    static let shared = MacGuideSession()
    let controller = GuideConversationController(historyStore: .contextualHelp)

    struct Request: Equatable {
        let id = UUID()
        let target: GuideNavigationDestination
    }

    @Published private(set) var pending: Request?
    private var openSettings: OpenSettingsAction?
    private var subscription: AnyCancellable?

    private init() {
        subscription = GuideNavigationCoordinator.shared.navigationRequests.sink { [weak self] target in
            guard let self else { return }
            controller.discardPendingProposalForNavigation()
            pending = Request(target: target)
            openSettings?()
        }
    }

    // Settings 场景可能尚未被创建。保存这一次点击，待窗口挂载后消费。
    func attach(_ action: OpenSettingsAction) { openSettings = action }

    func consume() -> GuideNavigationDestination? {
        guard let pending else { return nil }
        self.pending = nil
        return pending.target
    }
}

extension GuideNavigationDestination {
    var macSettingsSection: MacSettingsDestination? {
        switch self {
        case .providerManagement: .models
        case .conversationSettings: .conversation
        case .promptSettings: .prompts
        case .outputSettings: .output
        case .appearanceSettings: .display
        case .syncAndBackup, .dataImport: .sync
        case .roleplayAndTavern: .roleplay
        case .worldbook: .worldbook
        case .memorySystem: .memory
        case .dailyPulse: .pulse
        case .toolCenter: .tools
        case .mcpTools: .mcp
        case .shortcutTools: .shortcuts
        case .agentSkills: .skills
        case .speechInput: .speech
        case .ttsSettings: .tts
        case .localLinux: nil
        case .networkProxy: .general
        case .connectionExceptions: .security
        case .feedbackCenter, .feedbackCompose: .extended
        case .aboutAndLogs: .about
        }
    }
}

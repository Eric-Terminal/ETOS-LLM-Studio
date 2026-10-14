import ETOSCore
import SwiftUI

struct MacSettingsAchievementTriggers: ViewModifier {
    @Environment(\.controlActiveState) private var windowActivity
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    private var active: Bool { workspace.canManageLocalModels && windowActivity == .key }

    func body(content: Content) -> some View {
        content
            .task(id: active) {
                guard active else { return }
                do { try await Task.sleep(for: .seconds(AchievementTriggerEvaluator.settingsResearchDuration)) } catch { return }
                guard !Task.isCancelled, active else { return }
                await AchievementCenter.shared.unlock(id: .settingsResearcher)
            }
            .onChange(of: configuration.aiTemperature) { old, value in
                guard active, old != value else { return }
                if value == 0 { Task { await AchievementCenter.shared.unlock(id: .absoluteReason) } }
                if value == 2 { Task { await AchievementCenter.shared.unlock(id: .wildTemperature) } }
            }
    }
}

struct MacSessionAchievementTriggers: ViewModifier {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    func body(content: Content) -> some View {
        content.task(id: workspace.currentSession?.id) {
            guard workspace.canManageLocalModels, let session = workspace.currentSession else { return }
            let sessions = workspace.sessions
            let unlock = await Task.detached(priority: .utility) {
                AchievementTriggerEvaluator.shouldUnlockConversationArchaeologist(selectedSession: session, sessions: sessions)
            }.value
            if !Task.isCancelled, unlock, workspace.canManageLocalModels { await AchievementCenter.shared.unlock(id: .conversationArchaeologist) }
        }
    }
}

import ETOSCore
import SwiftUI

/// 通知仅请求导航；工作区锁定或恢复期间不读取工单与记录。
struct MacFeedbackNotificationHost: ViewModifier {
    private enum Destination: String, Identifiable { case feedback, journal, updates, announcements; var id: String { rawValue } }
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var notifications = AppLocalNotificationCenter.shared
    @ObservedObject private var announcements = AnnouncementManager.shared
    @State private var destination: Destination?
    @State private var issueNumber: Int?

    func body(content: Content) -> some View {
        content
            .onChange(of: notifications.pendingRoute) { _, _ in receive() }
            .onChange(of: announcements.shouldShowAlert) { _, _ in receive() }
            .onChange(of: workspace.canManageLocalModels) { _, available in
                if available { receive() } else { destination = nil }
            }
            .onAppear { receive() }
            .sheet(item: $destination) { page in
                NavigationStack {
                    Group {
                        switch page {
                        case .feedback: MacFeedbackCenterView(isActive: workspace.canManageLocalModels, initialIssueNumber: issueNumber)
                        case .journal: MacAchievementJournalView(isActive: workspace.canManageLocalModels)
                        case .updates: MacUpdateTimelineView(isActive: workspace.canManageLocalModels)
                        case .announcements: MacAnnouncementsView(isActive: workspace.canManageLocalModels)
                        }
                    }
                    .toolbar {
                        Button(NSLocalizedString("完成", comment: "")) { destination = nil }
                    }
                }
                .frame(minWidth: 560, minHeight: 500)
                .modifier(MacGuideInspector())
            }
    }

    private func receive() {
        guard workspace.canManageLocalModels else { return }
        switch notifications.pendingRoute {
        case .feedback:
            issueNumber = notifications.consumePendingFeedbackIssueNumber()
            _ = notifications.consumePendingRoute()
            destination = .feedback
        case .achievementJournal:
            _ = notifications.consumePendingRoute()
            destination = .journal
        case .updateTimeline:
            _ = notifications.consumePendingRoute()
            destination = .updates
        default:
            if announcements.shouldShowAlert, destination == nil {
                announcements.dismissAlert()
                destination = .announcements
            }
        }
    }
}

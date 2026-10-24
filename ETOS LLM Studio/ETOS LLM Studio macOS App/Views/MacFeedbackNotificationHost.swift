import ETOSCore
import SwiftUI

/// 通知仅请求导航；工作区锁定或恢复期间不读取工单与记录。
struct MacFeedbackNotificationHost: ViewModifier {
    private enum Destination: String, Identifiable { case feedback, journal, updates, announcements, deviceMessage; var id: String { rawValue } }
    @ObservedObject var dailyPulse: MacDailyPulseModel
    var isBlocked = false
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var notifications = AppLocalNotificationCenter.shared
    @ObservedObject private var announcements = AnnouncementManager.shared
    @ObservedObject private var deviceMessages = DeviceMessageManager.shared
    @ObservedObject private var permissions = ToolPermissionCenter.shared
    @Environment(\.controlActiveState) private var windowActivity
    @State private var destination: Destination?
    @State private var issueNumber: Int?
    @State private var ownsDeviceMessage = false

    func body(content: Content) -> some View {
        content
            .onChange(of: notifications.pendingRoute) { _, _ in receive() }
            .onChange(of: announcements.shouldShowAlert) { _, _ in receive() }
            .onChange(of: workspace.canManageLocalModels) { _, available in
                if available { receive() } else { destination = nil }
            }
            .onChange(of: isBlocked) { _, blocked in if !blocked { receive() } }
            .onChange(of: dailyPulse.showsWindow) { _, shown in if !shown { receive() } }
            .onAppear { receive() }
            .task { await deviceMessages.checkMessages() }
            .task(id: canPresentDeviceMessage) {
                guard canPresentDeviceMessage else { return }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard canPresentDeviceMessage else { return }
                if deviceMessages.presentIfPossible() { ownsDeviceMessage = true }
                if ownsDeviceMessage, deviceMessages.currentMessage != nil { destination = .deviceMessage }
            }
            .onChange(of: deviceMessages.currentMessage) { _, message in
                if message == nil, destination == .deviceMessage { destination = nil }
            }
            .onChange(of: destination) { _, page in
                permissions.setAutoPresentationBlocked(page != nil, reason: "mac.feedback.presentation")
                if page == nil {
                    Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                        receive()
                    }
                }
            }
            .onDisappear { permissions.setAutoPresentationBlocked(false, reason: "mac.feedback.presentation") }
            .sheet(item: $destination) { page in
                NavigationStack {
                    Group {
                        switch page {
                        case .feedback: MacFeedbackCenterView(isActive: workspace.canManageLocalModels, initialIssueNumber: issueNumber)
                        case .journal: MacAchievementJournalView(isActive: workspace.canManageLocalModels)
                        case .updates: MacUpdateTimelineView(isActive: workspace.canManageLocalModels)
                        case .announcements: MacAnnouncementsView(isActive: workspace.canManageLocalModels)
                        case .deviceMessage:
                            if let message = deviceMessages.currentMessage {
                                DeviceMessageResponseView(message: message, manager: deviceMessages)
                            }
                        }
                    }
                    .toolbar {
                        if page != .deviceMessage {
                            Button(NSLocalizedString("完成", comment: "")) { destination = nil }
                        }
                    }
                }
                .frame(minWidth: 560, minHeight: 500)
                .modifier(MacGuideInspector())
            }
    }

    private var canPresentDeviceMessage: Bool {
        deviceMessages.hasPendingMessage && destination == nil && !isBlocked && !dailyPulse.showsWindow
            && workspace.canManageLocalModels && windowActivity == .key
            && !announcements.shouldShowAlert && permissions.activeRequest == nil
            && !permissions.hasAutoPresentationBlockers(excluding: ["mac.feedback.presentation"])
    }

    private func receive() {
        guard workspace.canManageLocalModels, destination == nil, !isBlocked, !dailyPulse.showsWindow else { return }
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

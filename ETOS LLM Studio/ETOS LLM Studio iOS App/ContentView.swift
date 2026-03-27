// ============================================================================
// ContentView.swift (iOS)
// ============================================================================
// 应用根视图:
// - 构建底部 TabView，包含聊天、会话、设置三个主要模块
// - 通过环境注入的 ChatViewModel 在各子视图间共享状态
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: ChatViewModel
    @StateObject private var announcementManager = AnnouncementManager.shared
    @ObservedObject private var notificationCenter = AppLocalNotificationCenter.shared
    @State private var selection: Tab = .chat
    @State private var settingsDestination: SettingsNavigationDestination?
    @State private var dailyPulsePreparationTask: Task<Void, Never>?
    
    enum Tab: Hashable {
        case chat
        case sessions
        case settings
    }
    
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                ChatView()
            }
            .tabItem {
                Label("聊天", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .tag(Tab.chat)
            
            NavigationStack {
                SessionListView()
            }
            .tabItem {
                Label("会话", systemImage: "list.bullet")
            }
            .tag(Tab.sessions)
            
            NavigationStack {
                SettingsView(requestedDestination: $settingsDestination)
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(Tab.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSwitchToChatTab)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = .chat
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenDailyPulse)) { _ in
            openDailyPulse()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestContinueDailyPulseChat)) { _ in
            Task { @MainActor in
                openDailyPulseContinuationIfNeeded()
            }
        }
        .alert("记忆系统需要更新", isPresented: $viewModel.showDimensionMismatchAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.dimensionMismatchMessage)
        }
        // MARK: - 公告弹窗
        .sheet(isPresented: $announcementManager.shouldShowAlert) {
            if let announcement = announcementManager.currentAnnouncement {
                AnnouncementAlertView(
                    announcement: announcement,
                    onDismiss: {
                        announcementManager.dismissAlert()
                    }
                )
            }
        }
        // 启动时检查公告
        .task {
            await announcementManager.checkAnnouncement()
            scheduleDailyPulsePreparation(after: 1_500_000_000)
            if openDailyPulseContinuationIfNeeded() {
                return
            }
            if notificationCenter.consumePendingRoute() == .dailyPulse {
                openDailyPulse()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                scheduleDailyPulsePreparation(after: 1_500_000_000)
            default:
                cancelDailyPulsePreparation()
            }
        }
    }

    private func openDailyPulse() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = .settings
        }
        settingsDestination = nil
        DispatchQueue.main.async {
            settingsDestination = .dailyPulse
        }
    }

    @discardableResult
    private func openDailyPulseContinuationIfNeeded() -> Bool {
        guard let continuation = notificationCenter.consumePendingDailyPulseContinuation() else {
            return false
        }
        viewModel.applyDailyPulseContinuation(
            sessionID: continuation.sessionID,
            prompt: continuation.prompt
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = .chat
        }
        return true
    }

    private func scheduleDailyPulsePreparation(after delayNanoseconds: UInt64) {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = Task(priority: .utility) {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let isSceneActive = await MainActor.run { scenePhase == .active }
            guard isSceneActive else { return }
            await viewModel.prepareDailyPulseIfNeeded()
            guard !Task.isCancelled else { return }
            await viewModel.prepareMorningDailyPulseDeliveryIfNeeded()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                dailyPulsePreparationTask = nil
            }
        }
    }

    private func cancelDailyPulsePreparation() {
        dailyPulsePreparationTask?.cancel()
        dailyPulsePreparationTask = nil
    }
}

enum ChatNavigationDestination: Hashable {
    case sessions
    case settings
}

extension Notification.Name {
    static let requestSwitchToChatTab = Notification.Name("ios.requestSwitchToChatTab")
}

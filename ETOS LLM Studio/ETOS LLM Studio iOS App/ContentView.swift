// ============================================================================
// ContentView.swift (iOS)
// ============================================================================
// 应用根视图:
// - 构建原生导航根视图，统一承接通知与页面跳转
// - 通过环境注入的 ChatViewModel 在各子视图间共享状态
// ============================================================================

import SwiftUI
import Foundation
import Shared
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText)
import CoreText
#endif

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var viewModel: ChatViewModel
    @StateObject private var announcementManager = AnnouncementManager.shared
    @StateObject private var legacyJSONMigrationManager = LegacyJSONMigrationManager.shared
    @ObservedObject private var notificationCenter = AppLocalNotificationCenter.shared
    @State private var settingsDestination: SettingsNavigationDestination?
    @State private var dailyPulsePreparationTask: Task<Void, Never>?
    @State private var launchRecoveryNoticeMessage: String?
    @State private var rootBodyFont: Font = .body
    @State private var legacyMigrationErrorMessage: String?
    @State private var isLegacyMigrationErrorPresented: Bool = false
    @EnvironmentObject private var appConfig: AppConfigStore
    @State private var isNativeChatPresented: Bool = true
    @State private var isNativeSettingsPresented: Bool = false
    
    var body: some View {
        contentWithMigrationOverlays
            // 启动时检查公告
            .task {
                await handleLaunchTasks()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    ChatAppearanceProfileManager.shared.handleAppBecameActive()
                    scheduleDailyPulsePreparation(after: 1_500_000_000)
                default:
                    cancelDailyPulsePreparation()
                }
            }
    }

    private var baseContent: some View {
        nativeNavigationContent
        .environment(\.font, rootBodyFont)
        .environment(\.locale, AppLanguagePreference.preferredLocale(rawValue: appConfig.appLanguage))
        .onAppear {
            normalizeChatNavigationModeIfNeeded()
            AppLanguageRuntime.apply(rawValue: appConfig.appLanguage)
            refreshRootBodyFont()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSwitchToChatTab)) { _ in
            pushNativeChatIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
            refreshRootBodyFont()
        }
        .onChange(of: appConfig.customFontEnabled) { _, isEnabled in
            _ = isEnabled
            FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
            refreshRootBodyFont()
        }
        .onChange(of: appConfig.fontScale) { _, newValue in
            let normalizedValue = FontLibrary.normalizedFontScale(newValue)
            if normalizedValue != newValue {
                appConfig.fontScale = normalizedValue
            }
            refreshRootBodyFont()
        }
        .onChange(of: appConfig.chatNavigationMode) { _, _ in
            normalizeChatNavigationModeIfNeeded()
            isNativeSettingsPresented = false
            isNativeChatPresented = true
        }
        .onChange(of: appConfig.appLanguage) { _, newValue in
            AppLanguageRuntime.apply(rawValue: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenDailyPulse)) { _ in
            openDailyPulse()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenFeedback)) { _ in
            openFeedbackFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenChatSession)) { _ in
            openChatSessionFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenAchievementJournal)) { _ in
            openAchievementJournalFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestContinueDailyPulseChat)) { _ in
            Task { @MainActor in
                openDailyPulseContinuationIfNeeded()
            }
        }
        .alert(NSLocalizedString("记忆系统需要更新", comment: ""), isPresented: $viewModel.showDimensionMismatchAlert) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: {
            Text(viewModel.dimensionMismatchMessage)
        }
        .alert(NSLocalizedString("数据库已自动恢复", comment: ""), isPresented: launchRecoveryNoticePresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {}
        } message: {
            Text(launchRecoveryNoticeMessage ?? "")
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
    }

    private var nativeNavigationContent: some View {
        NavigationStack {
            SessionListView(
                createConversationAction: {
                    viewModel.createNewSession()
                    pushNativeChatIfNeeded()
                }
            )
                .navigationTitle(NSLocalizedString("历史会话", comment: ""))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            pushNativeSettings(destination: nil)
                        } label: {
                            Image(systemName: "gearshape.fill")
                        }
                    }
                }
                .navigationDestination(isPresented: $isNativeChatPresented) {
                    ChatView()
                }
                .navigationDestination(isPresented: $isNativeSettingsPresented) {
                    SettingsView(requestedDestination: $settingsDestination)
                }
        }
    }

    private var contentWithMigrationOverlays: some View {
        baseContent
            .sheet(isPresented: $legacyJSONMigrationManager.isMigrationPromptPresented) {
                NavigationStack {
                    legacyJSONMigrationPromptSheet
                }
                .interactiveDismissDisabled(true)
            }
            .sheet(isPresented: migrationInProgressPresented) {
                NavigationStack {
                    legacyJSONMigrationProgressSheet
                }
                .interactiveDismissDisabled(true)
            }
            .alert(NSLocalizedString("是否清理旧版 JSON 文件？", comment: ""),
                isPresented: $legacyJSONMigrationManager.isCleanupPromptPresented
            ) {
                Button(NSLocalizedString("保留 JSON（稍后再说）", comment: ""), role: .cancel) {
                    legacyJSONMigrationManager.keepLegacyJSONForNow()
                }
                Button(NSLocalizedString("删除 JSON", comment: "")) {
                    legacyJSONMigrationManager.cleanupLegacyJSONArtifacts()
                }
            } message: {
                Text(NSLocalizedString("SQLite 迁移已完成。建议删除旧 JSON 文件释放空间，后续版本可能不再支持旧格式。", comment: ""))
            }
            .alert(NSLocalizedString("迁移失败", comment: ""), isPresented: $isLegacyMigrationErrorPresented) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                    legacyMigrationErrorMessage = nil
                }
            } message: {
                Text(legacyMigrationErrorMessage ?? "")
            }
            .onReceive(legacyJSONMigrationManager.$errorMessage) { message in
                guard let message, !message.isEmpty else { return }
                legacyMigrationErrorMessage = message
                isLegacyMigrationErrorPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .legacyJSONMigrationDidFinish)) { _ in
                viewModel.reloadPersistedDataAfterLegacyJSONMigration()
            }
    }

    private func openDailyPulse() {
        pushNativeSettings(destination: .dailyPulse)
    }

    private var launchRecoveryNoticePresented: Binding<Bool> {
        Binding(
            get: { launchRecoveryNoticeMessage != nil },
            set: { newValue in
                if !newValue {
                    launchRecoveryNoticeMessage = nil
                }
            }
        )
    }

    private var migrationInProgressPresented: Binding<Bool> {
        Binding(
            get: { legacyJSONMigrationManager.isMigrating },
            set: { _ in }
        )
    }

    private func openFeedbackFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
    }

    private func openChatSessionFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        guard let sessionID = notificationCenter.consumePendingChatSessionID() else { return }
        openChatSession(sessionID: sessionID)
    }

    private func openAchievementJournalFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openAchievementJournal()
    }

    private func openChatSession(sessionID: UUID) {
        guard viewModel.setCurrentSessionIfExists(sessionID: sessionID) else { return }
        pushNativeChatIfNeeded()
    }

    private func openFeedback(issueNumber: Int?) {
        let destination: SettingsNavigationDestination
        if let issueNumber,
           FeedbackService.shared.tickets.contains(where: { $0.issueNumber == issueNumber }) {
            destination = .feedbackIssue(issueNumber: issueNumber)
        } else {
            destination = .feedbackCenter
        }
        pushNativeSettings(destination: destination)
    }

    private func openAchievementJournal() {
        pushNativeSettings(destination: .achievementJournal)
    }

    private func handleLaunchTasks() async {
        launchRecoveryNoticeMessage = Persistence.consumeLaunchRecoveryNotice()
        legacyJSONMigrationManager.refreshStatus()
        await announcementManager.checkAnnouncement()
        scheduleDailyPulsePreparation(after: 1_500_000_000)
        if openDailyPulseContinuationIfNeeded() {
            return
        }
        if let pendingRoute = notificationCenter.consumePendingRoute() {
            switch pendingRoute {
            case .dailyPulse:
                openDailyPulse()
            case .feedback:
                openFeedback(issueNumber: notificationCenter.consumePendingFeedbackIssueNumber())
            case .chatSession:
                if let sessionID = notificationCenter.consumePendingChatSessionID() {
                    openChatSession(sessionID: sessionID)
                }
            case .achievementJournal:
                openAchievementJournal()
            }
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
        pushNativeChatIfNeeded()
        return true
    }

    private func pushNativeSettings(destination: SettingsNavigationDestination?) {
        settingsDestination = nil
        isNativeChatPresented = false
        isNativeSettingsPresented = true
        if let destination {
            DispatchQueue.main.async {
                settingsDestination = destination
            }
        }
    }

    private func pushNativeChatIfNeeded() {
        if isNativeChatPresented && !isNativeSettingsPresented {
            return
        }
        isNativeSettingsPresented = false
        isNativeChatPresented = true
    }

    private func normalizeChatNavigationModeIfNeeded() {
        guard appConfig.chatNavigationMode != ChatNavigationMode.legacyOverlay.rawValue else { return }
        appConfig.chatNavigationMode = ChatNavigationMode.legacyOverlay.rawValue
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

    private func refreshRootBodyFont() {
        rootBodyFont = AppFontAdapter.adaptedFont(
            from: .body,
            sampleText: "The quick brown fox 你好こんにちは"
        )
    }

    private var legacyJSONMigrationPromptSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("检测到旧版 JSON 聊天数据", comment: ""))
                .etFont(.title3.bold())
            Text(NSLocalizedString("为避免后续兼容风险，强烈建议现在迁移到 SQLite。迁移会在后台分批进行，不会阻塞当前界面。", comment: ""))
                .foregroundStyle(.secondary)

            if let status = legacyJSONMigrationManager.status {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: NSLocalizedString("预计会话数：%d", comment: ""), status.estimatedSessionCount))
                    Text(String(format: NSLocalizedString("预计数据量：%.1f MB", comment: ""), status.estimatedLegacyMegabytes))
                }
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 10) {
                Button(NSLocalizedString("立即迁移（推荐）", comment: "")) {
                    legacyJSONMigrationManager.startMigration()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

                Button(NSLocalizedString("稍后再说", comment: "")) {
                    legacyJSONMigrationManager.postponeMigrationPrompt()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(20)
        .navigationTitle(NSLocalizedString("数据迁移", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var legacyJSONMigrationProgressSheet: some View {
        VStack(spacing: 16) {
            Text(NSLocalizedString("正在迁移聊天数据", comment: ""))
                .etFont(.title3.bold())
            if let progress = legacyJSONMigrationManager.progress {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text(String(format: NSLocalizedString("已处理会话 %d/%d", comment: ""), progress.processedSessions, max(progress.totalSessions, progress.processedSessions)))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("已导入消息 %d", comment: ""), progress.importedMessages))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                let currentSessionName = progress.currentSessionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let currentSessionDisplayName = currentSessionName.isEmpty ? NSLocalizedString("正在整理会话…", comment: "") : currentSessionName
                Text(String(format: NSLocalizedString("当前：%@", comment: ""), currentSessionDisplayName))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ProgressView()
                Text(NSLocalizedString("当前：正在准备迁移…", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(NSLocalizedString("迁移完成后会再次询问是否删除旧 JSON 文件。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .navigationTitle(NSLocalizedString("迁移中", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

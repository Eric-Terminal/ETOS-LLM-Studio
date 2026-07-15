// ============================================================================
// ContentView.swift (iOS)
// ============================================================================
// 应用根视图:
// - 构建聊天根视图，统一承接通知与页面跳转
// - 通过环境注入的 ChatViewModel 在各子视图间共享状态
// ============================================================================

import SwiftUI
import Foundation
import Combine
import ETOSCore
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
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var appLockManager = AppLockManager.shared
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @State private var settingsDestination: SettingsNavigationDestination?
    @State private var dailyPulsePreparationTask: Task<Void, Never>?
    @State private var launchRecoveryNoticeMessage: String?
    @State private var launchRecoveryRequest: Persistence.LaunchRecoveryRequest?
    @State private var launchRecoveryErrorMessage: String?
    @State private var rootBodyFont: Font = .body
    @State private var legacyMigrationErrorMessage: String?
    @State private var isLegacyMigrationErrorPresented: Bool = false
    @State private var isNativeSettingsPresented: Bool = false
    @State private var incomingSnapshotRestorePayload: IncomingSnapshotRestorePayload?
    @State private var newAPIProviderImportNoticeMessage: String?
    @State private var newAPIProviderImportErrorMessage: String?
    @State private var didEnterBackgroundSinceLastActivation = false
    
    var body: some View {
        contentWithMigrationOverlays
            // 启动时检查公告
            .task {
                await handleLaunchTasks()
            }
            .onAppear {
                refreshRootToolPermissionAutoPresentationBlocker()
            }
            .onDisappear {
                setRootToolPermissionAutoPresentationBlocked(false)
            }
            .onChange(of: rootToolPermissionAutoPresentationBlocked) { _, _ in
                refreshRootToolPermissionAutoPresentationBlocker()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    appLockManager.handleSceneDidBecomeActive()
                    ChatAppearanceProfileManager.shared.handleAppBecameActive()
                    if didEnterBackgroundSinceLastActivation {
                        ChatService.shared.openNewSessionIfRestoreWindowExpired()
                        didEnterBackgroundSinceLastActivation = false
                    }
                    scheduleDailyPulsePreparation(after: 1_500_000_000)
                case .background:
                    appLockManager.handleSceneDidEnterBackground()
                    ChatService.recordAppDidEnterBackground()
                    didEnterBackgroundSinceLastActivation = true
                    Task {
                        await AppConfigStore.shared.flushPendingWrites()
                    }
                    cancelDailyPulsePreparation()
                default:
                    cancelDailyPulsePreparation()
                }
            }
    }

    private var baseContent: some View {
        notificationAwareContent
        .alert(NSLocalizedString("记忆系统需要更新", comment: ""), isPresented: $viewModel.showDimensionMismatchAlert) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {}
        } message: {
            Text(viewModel.dimensionMismatchMessage)
        }
        .alert(NSLocalizedString("数据库已恢复", comment: ""), isPresented: launchRecoveryNoticePresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {}
        } message: {
            Text(launchRecoveryNoticeMessage ?? "")
        }
        .alert(NSLocalizedString("检测到数据库损坏", comment: ""), isPresented: launchRecoveryRequestPresented) {
            Button(NSLocalizedString("稍后再说", comment: ""), role: .cancel) {
                Persistence.dismissPendingLaunchRecoveryRequest()
                launchRecoveryRequest = nil
            }
            Button(NSLocalizedString("从启动备份恢复", comment: "")) {
                restoreLaunchBackupFromPrompt()
            }
        } message: {
            Text(launchRecoveryRequest?.message ?? "")
        }
        .alert(NSLocalizedString("启动备份恢复失败", comment: ""), isPresented: launchRecoveryErrorPresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                launchRecoveryErrorMessage = nil
            }
        } message: {
            Text(launchRecoveryErrorMessage ?? "")
        }
        .alert(NSLocalizedString("导入失败", comment: ""), isPresented: externalDocumentImportErrorPresented) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                viewModel.externalDocumentImportErrorMessage = nil
            }
        } message: {
            Text(viewModel.externalDocumentImportErrorMessage ?? "")
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
        .sheet(item: $incomingSnapshotRestorePayload) { payload in
            NavigationStack {
                IncomingSnapshotRestoreView(fileURL: payload.fileURL) {
                    incomingSnapshotRestorePayload = nil
                }
            }
        }
    }

    private var notificationAwareContent: some View {
        appNavigationContent
        .environment(\.font, rootBodyFont)
        .environment(\.locale, AppLanguagePreference.preferredLocale(rawValue: appConfig.appLanguage))
        .onAppear {
            AppLanguageRuntime.apply(rawValue: appConfig.appLanguage)
            refreshRootBodyFont()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestSwitchToChatTab)) { _ in
            pushNativeChatIfNeeded()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .syncFontsUpdated)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshRootBodyFont()
        }
        .onChange(of: appConfig.fontUseCustomFonts) { _, isEnabled in
            _ = isEnabled
            FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
            refreshRootBodyFont()
        }
        .onChange(of: appConfig.fontCustomScale) { _, newValue in
            let normalizedValue = FontLibrary.normalizedFontScale(newValue)
            if normalizedValue != newValue {
                appConfig.fontCustomScale = normalizedValue
            }
            refreshRootBodyFont()
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
        .onReceive(NotificationCenter.default.publisher(for: .requestContextCompression)) { _ in
            openContextCompressionFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenAchievementJournal)) { _ in
            openAchievementJournalFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestOpenUpdateTimeline)) { _ in
            openUpdateTimelineFromNotification()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .requestIncomingSnapshotRestore),
            perform: handleIncomingSnapshotRestore
        )
        .onReceive(NotificationCenter.default.publisher(for: .requestContinueDailyPulseChat)) { _ in
            Task { @MainActor in
                openDailyPulseContinuationIfNeeded()
            }
        }
    }

    private func handleIncomingSnapshotRestore(_ notification: Notification) {
        guard let fileURL = notification.object as? URL else { return }
        incomingSnapshotRestorePayload = IncomingSnapshotRestorePayload(fileURL: fileURL)
    }

    private var appNavigationContent: some View {
        NavigationStack {
            ChatView()
                .navigationDestination(isPresented: $isNativeSettingsPresented) {
                    SettingsView(requestedDestination: $settingsDestination)
                }
        }
    }

    private var contentWithNewAPIImportAlerts: some View {
        baseContent
            .sheet(item: globalToolPermissionRequestBinding) { request in
                GlobalToolPermissionSheet(request: request) { decision in
                    toolPermissionCenter.resolveActiveRequest(with: decision)
                }
                .interactiveDismissDisabled(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .newAPIProviderImportDidFinish)) { notification in
                newAPIProviderImportNoticeMessage = notification.object as? String
                    ?? NSLocalizedString("已导入 New API 连接信息。", comment: "New API deeplink import fallback success message")
            }
            .onReceive(NotificationCenter.default.publisher(for: .newAPIProviderImportDidFail)) { notification in
                newAPIProviderImportErrorMessage = notification.object as? String
                    ?? NSLocalizedString("无法导入 New API 连接信息。", comment: "New API deeplink import fallback error message")
            }
            .alert(NSLocalizedString("连接信息已导入", comment: "New API deeplink import success title"), isPresented: newAPIProviderImportNoticePresented) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                    newAPIProviderImportNoticeMessage = nil
                }
            } message: {
                Text(newAPIProviderImportNoticeMessage ?? "")
            }
            .alert(NSLocalizedString("New API 导入失败", comment: "New API deeplink import failure title"), isPresented: newAPIProviderImportErrorPresented) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) {
                    newAPIProviderImportErrorMessage = nil
                }
            } message: {
                Text(newAPIProviderImportErrorMessage ?? "")
            }
    }

    private var contentWithMigrationOverlays: some View {
        contentWithNewAPIImportAlerts
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

    private var globalToolPermissionRequestBinding: Binding<ToolPermissionRequest?> {
        Binding(
            get: { globalToolPermissionRequest },
            set: { _ in }
        )
    }

    private var globalToolPermissionRequest: ToolPermissionRequest? {
        guard toolPermissionCenter.canAutoPresentRequestDetails,
              let request = toolPermissionCenter.activeRequest,
              let sourceSessionID = request.sourceSessionID,
              sourceSessionID != viewModel.currentSession?.id else {
            return nil
        }
        return request
    }

    private var rootToolPermissionAutoPresentationBlocked: Bool {
        isNativeSettingsPresented
            || announcementManager.shouldShowAlert
            || incomingSnapshotRestorePayload != nil
            || viewModel.showDimensionMismatchAlert
            || viewModel.externalDocumentImportErrorMessage != nil
            || launchRecoveryNoticeMessage != nil
            || launchRecoveryRequest != nil
            || launchRecoveryErrorMessage != nil
            || newAPIProviderImportNoticeMessage != nil
            || newAPIProviderImportErrorMessage != nil
            || legacyJSONMigrationManager.isMigrationPromptPresented
            || legacyJSONMigrationManager.isMigrating
            || legacyJSONMigrationManager.isCleanupPromptPresented
            || isLegacyMigrationErrorPresented
            || appLockManager.state == .locked
    }

    private func setRootToolPermissionAutoPresentationBlocked(_ blocked: Bool) {
        toolPermissionCenter.setAutoPresentationBlocked(blocked, reason: "ios.root.presentation")
    }

    private func refreshRootToolPermissionAutoPresentationBlocker() {
        setRootToolPermissionAutoPresentationBlocked(rootToolPermissionAutoPresentationBlocked)
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

    private var launchRecoveryRequestPresented: Binding<Bool> {
        Binding(
            get: { launchRecoveryRequest != nil },
            set: { newValue in
                if !newValue {
                    launchRecoveryRequest = nil
                }
            }
        )
    }

    private var launchRecoveryErrorPresented: Binding<Bool> {
        Binding(
            get: { launchRecoveryErrorMessage != nil },
            set: { newValue in
                if !newValue {
                    launchRecoveryErrorMessage = nil
                }
            }
        )
    }

    private var externalDocumentImportErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.externalDocumentImportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.externalDocumentImportErrorMessage = nil
                }
            }
        )
    }

    private var newAPIProviderImportNoticePresented: Binding<Bool> {
        Binding(
            get: { newAPIProviderImportNoticeMessage != nil },
            set: { isPresented in
                if !isPresented {
                    newAPIProviderImportNoticeMessage = nil
                }
            }
        )
    }

    private var newAPIProviderImportErrorPresented: Binding<Bool> {
        Binding(
            get: { newAPIProviderImportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    newAPIProviderImportErrorMessage = nil
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

    private func openContextCompressionFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        guard let sessionID = notificationCenter.pendingContextCompressionSessionID else { return }
        openChatSession(sessionID: sessionID)
    }

    private func openAchievementJournalFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openAchievementJournal()
    }

    private func openUpdateTimelineFromNotification() {
        _ = notificationCenter.consumePendingRoute()
        openUpdateTimeline()
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

    private func openUpdateTimeline() {
        pushNativeSettings(destination: .updateTimeline)
    }

    private func handleLaunchTasks() async {
        launchRecoveryRequest = Persistence.currentLaunchRecoveryRequest()
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
            case .contextCompression:
                if let sessionID = notificationCenter.pendingContextCompressionSessionID {
                    openChatSession(sessionID: sessionID)
                }
            case .achievementJournal:
                openAchievementJournal()
            case .updateTimeline:
                openUpdateTimeline()
            }
        }
    }

    private func restoreLaunchBackupFromPrompt() {
        launchRecoveryRequest = nil
        Task {
            do {
                let message = try await Task.detached(priority: .userInitiated) {
                    try Persistence.restorePendingLaunchBackupRequest()
                }.value
                viewModel.reloadAfterSnapshotRestore()
                _ = Persistence.consumeLaunchRecoveryNotice()
                launchRecoveryNoticeMessage = message
            } catch {
                _ = Persistence.consumeLaunchRecoveryNotice()
                launchRecoveryErrorMessage = error.localizedDescription
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
        isNativeSettingsPresented = true
        if let destination {
            DispatchQueue.main.async {
                settingsDestination = destination
            }
        }
    }

    private func pushNativeChatIfNeeded() {
        isNativeSettingsPresented = false
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

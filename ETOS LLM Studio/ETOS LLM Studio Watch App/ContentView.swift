// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio Watch App 主视图入口。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase

    @Environment(\.colorScheme) var colorScheme
    @StateObject var viewModel = ChatViewModel()
    @StateObject var announcementManager = AnnouncementManager.shared
    @StateObject var legacyJSONMigrationManager = LegacyJSONMigrationManager.shared
    @ObservedObject var notificationCenter = AppLocalNotificationCenter.shared
    @ObservedObject var appConfig = AppConfigStore.shared
    @ObservedObject var appLockManager = AppLockManager.shared
    @ObservedObject var toolPermissionCenter = ToolPermissionCenter.shared
    @State var isAtBottom = true
    @State var showScrollToBottomButton = false
    @State var fullErrorContent: String?
    @State var isSettingsPresented = false
    @State var settingsDestination: WatchSettingsNavigationDestination?
    @State var isSessionListPresented = false
    @State var messageActionsTarget: WatchMessageActionsNavigationTarget?
    @State var messageRewriteTarget: WatchMessageRewriteNavigationTarget?
    @State var dailyPulsePreparationTask: Task<Void, Never>?
    @State var shouldForceScrollToBottom = false
    @State var shouldKeepBottomPinned = true
    @State var suppressAutoScrollOnce = false
    @State var pendingHistoryResetWorkItem: DispatchWorkItem?
    @State var pendingBottomSnapTask: Task<Void, Never>?
    @State var watchInputLayoutSettleTask: Task<Void, Never>?
    @State var needsImmediateBottomSnap = true
    @State var isWatchInputLayoutSettling = false
    @State var bottomAnchorVisibilityWorkItem: DispatchWorkItem?
    @State var shouldRestorePendingJumpOnAppear = false
    @State var pendingJumpRequest: MessageJumpRequest?
    @State var launchRecoveryNoticeMessage: String?
    @State var launchRecoveryRequest: Persistence.LaunchRecoveryRequest?
    @State var launchRecoveryErrorMessage: String?
    @State var rootBodyFont: Font = .body
    @State var legacyMigrationErrorMessage: String?
    @State var isRequestControlsPresented = false
    @State var isAttachmentImportPresented = false
    @State var attachmentSourceText: String = ""
    @State var importSourceHistory: [String] = []

    var effectiveFontScale: CGFloat {
        CGFloat(FontLibrary.effectiveFontScale(appConfig.fontCustomScale, isCustomFontEnabled: appConfig.fontUseCustomFonts))
    }

    var inputControlHeight: CGFloat {
        max(38, 38 * effectiveFontScale)
    }

    let inputBubbleVerticalPadding: CGFloat = 8
    let emptyStateSpacerHeight: CGFloat = 120
    let bottomAnchorID = "inputBubble"

    var isLiquidGlassEnabled: Bool {
        if #available(watchOS 26.0, *) {
            return viewModel.enableLiquidGlass
        } else {
            return false
        }
    }

    var body: some View {
        ZStack {
            chatBackgroundLayer
                .ignoresSafeArea()

            NavigationStack {
                legacyChatRootView
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
            .onReceive(NotificationCenter.default.publisher(for: .requestOpenUpdateTimeline)) { _ in
                openUpdateTimelineFromNotification()
            }
            .onReceive(NotificationCenter.default.publisher(for: .requestContinueDailyPulseChat)) { _ in
                Task { @MainActor in
                    applyDailyPulseContinuationIfNeeded()
                }
            }
            .onChange(of: viewModel.activeSheet) {
                if viewModel.activeSheet == nil {
                    viewModel.saveCurrentSessionDetails()
                }
            }

            if let notice = viewModel.memoryRetryStoppedNoticeMessage {
                VStack {
                    memoryRetryStoppedNoticeBanner(text: notice)
                        .padding(.top, 8)
                        .padding(.horizontal, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(20)
            }

            VStack {
                Spacer()
                TTSFloatingController()
            }

            if appLockManager.state == .locked {
                AppLockOverlayView()
                    .zIndex(1_000)
            }
        }
        .environment(\.font, rootBodyFont)
        .environment(\.locale, AppLanguagePreference.preferredLocale(rawValue: appConfig.appLanguage))
        .onAppear {
            AppLanguageRuntime.apply(rawValue: appConfig.appLanguage)
            refreshRootBodyFont()
            refreshAttachmentSourceHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
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
        .onChange(of: appConfig.watchAttachmentSourceHistory) { _, _ in
            refreshAttachmentSourceHistory()
        }
        .onChange(of: appConfig.watchAttachmentLastSource) { _, _ in
            refreshAttachmentSourceHistory()
        }
        .onDisappear {
            pendingHistoryResetWorkItem?.cancel()
            pendingHistoryResetWorkItem = nil
            pendingBottomSnapTask?.cancel()
            pendingBottomSnapTask = nil
            watchInputLayoutSettleTask?.cancel()
            watchInputLayoutSettleTask = nil
            bottomAnchorVisibilityWorkItem?.cancel()
            bottomAnchorVisibilityWorkItem = nil
        }
        .sheet(isPresented: $legacyJSONMigrationManager.isMigrationPromptPresented) {
            NavigationStack {
                legacyJSONMigrationPromptSheet
            }
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: Binding(
            get: { legacyJSONMigrationManager.isMigrating },
            set: { _ in }
        )) {
            NavigationStack {
                legacyJSONMigrationProgressSheet
            }
            .interactiveDismissDisabled(true)
        }
        .alert(NSLocalizedString("是否清理旧版 JSON 文件？", comment: ""),
            isPresented: $legacyJSONMigrationManager.isCleanupPromptPresented
        ) {
            Button(NSLocalizedString("保留", comment: ""), role: .cancel) {
                legacyJSONMigrationManager.keepLegacyJSONForNow()
            }
            Button(NSLocalizedString("删除", comment: "")) {
                legacyJSONMigrationManager.cleanupLegacyJSONArtifacts()
            }
        } message: {
            Text(NSLocalizedString("SQLite 迁移完成后，建议删除旧 JSON 释放空间。", comment: ""))
        }
        .alert(NSLocalizedString("迁移失败", comment: ""), isPresented: Binding(
            get: { legacyMigrationErrorMessage != nil },
            set: { if !$0 { legacyMigrationErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("好的", comment: ""), role: .cancel) {}
        } message: {
            Text(legacyMigrationErrorMessage ?? "")
        }
        .onReceive(legacyJSONMigrationManager.$errorMessage) { message in
            guard let message, !message.isEmpty else { return }
            legacyMigrationErrorMessage = message
        }
        .onReceive(NotificationCenter.default.publisher(for: .legacyJSONMigrationDidFinish)) { _ in
            viewModel.reloadPersistedDataAfterLegacyJSONMigration()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                appLockManager.handleSceneDidBecomeActive()
            case .background:
                appLockManager.handleSceneDidEnterBackground()
                Task {
                    await AppConfigStore.shared.flushPendingWrites()
                }
            default:
                break
            }
        }
        .task {
            legacyJSONMigrationManager.refreshStatus()
            appLockManager.refreshState()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.memoryRetryStoppedNoticeMessage)
    }
}

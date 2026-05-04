// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio Watch App 主视图入口。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase

    @Environment(\.colorScheme) var colorScheme
    @StateObject var viewModel = ChatViewModel()
    @StateObject var announcementManager = AnnouncementManager.shared
    @StateObject var legacyJSONMigrationManager = LegacyJSONMigrationManager.shared
    @ObservedObject var notificationCenter = AppLocalNotificationCenter.shared
    @ObservedObject var toolPermissionCenter = ToolPermissionCenter.shared
    @State var isAtBottom = true
    @State var showScrollToBottomButton = false
    @State var fullErrorContent: String?
    @State var isSettingsPresented = false
    @State var settingsDestination: WatchSettingsNavigationDestination?
    @State var isSessionListPresented = false
    @State var messageActionsTarget: WatchMessageActionsNavigationTarget?
    @State var dailyPulsePreparationTask: Task<Void, Never>?
    @State var shouldForceScrollToBottom = false
    @State var shouldKeepBottomPinned = true
    @State var suppressAutoScrollOnce = false
    @State var pendingBottomSnapTask: Task<Void, Never>?
    @State var needsImmediateBottomSnap = true
    @State var bottomAnchorVisibilityWorkItem: DispatchWorkItem?
    @State var pendingJumpRequest: MessageJumpRequest?
    @State var launchRecoveryNoticeMessage: String?
    @State var rootBodyFont: Font = .body
    @State var legacyMigrationErrorMessage: String?
    @State var nativeDestination: WatchNativeNavigationDestination? = .chat
    @State var isQuickModelSelectorPresented = false
    @State var isAttachmentImportPresented = false
    @State var attachmentSourceText: String = ""
    @State var importSourceHistory: [String] = []
    @AppStorage(FontLibrary.customFontEnabledStorageKey) var isCustomFontEnabled: Bool = true
    @AppStorage(FontLibrary.fontScaleStorageKey) var customFontScale: Double = FontLibrary.defaultFontScale
    @AppStorage(ChatNavigationMode.storageKey) var chatNavigationModeRawValue: String = ChatNavigationMode.defaultMode.rawValue
    @AppStorage(AppLanguagePreference.storageKey) var appLanguageRawValue: String = AppLanguagePreference.defaultLanguage.rawValue
    @AppStorage("watch.attachment.lastSource") var lastAttachmentSource: String = ""
    @AppStorage("watch.attachment.sourceHistory") var attachmentSourceHistoryRawValue: String = "[]"

    var effectiveFontScale: CGFloat {
        CGFloat(FontLibrary.effectiveFontScale(customFontScale, isCustomFontEnabled: isCustomFontEnabled))
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

    var isNativeNavigationEnabled: Bool {
        ChatNavigationMode.resolvedMode(rawValue: chatNavigationModeRawValue) == .nativeNavigation
    }

    var body: some View {
        ZStack {
            if !isNativeNavigationEnabled {
                chatBackgroundLayer
                    .ignoresSafeArea()
            }

            NavigationStack {
                if isNativeNavigationEnabled {
                    nativeSessionRootView
                        .navigationDestination(item: $nativeDestination) { destination in
                            switch destination {
                            case .chat:
                                legacyChatRootView
                            case .settings:
                                SettingsView(
                                    viewModel: viewModel,
                                    requestedDestination: $settingsDestination,
                                    embedsInNavigationStack: false
                                )
                            }
                        }
                } else {
                    legacyChatRootView
                        .navigationDestination(isPresented: $isSessionListPresented) {
                            sessionListView
                        }
                }
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
        }
        .environment(\.font, rootBodyFont)
        .environment(\.locale, AppLanguagePreference.preferredLocale(rawValue: appLanguageRawValue))
        .onAppear {
            AppLanguageRuntime.apply(rawValue: appLanguageRawValue)
            refreshRootBodyFont()
            refreshAttachmentSourceHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncFontsUpdated)) { _ in
            refreshRootBodyFont()
        }
        .onChange(of: isCustomFontEnabled) { _, isEnabled in
            _ = isEnabled
            FontLibrary.preloadRuntimeCacheAsync(forceReload: true)
            refreshRootBodyFont()
        }
        .onChange(of: customFontScale) { _, newValue in
            let normalizedValue = FontLibrary.normalizedFontScale(newValue)
            if normalizedValue != newValue {
                customFontScale = normalizedValue
            }
            refreshRootBodyFont()
        }
        .onChange(of: chatNavigationModeRawValue) { _, _ in
            if !isNativeNavigationEnabled {
                nativeDestination = nil
            } else {
                nativeDestination = .chat
                isSessionListPresented = false
                isSettingsPresented = false
            }
        }
        .onChange(of: appLanguageRawValue) { _, newValue in
            AppLanguageRuntime.apply(rawValue: newValue)
        }
        .onChange(of: attachmentSourceHistoryRawValue) { _, _ in
            refreshAttachmentSourceHistory()
        }
        .onChange(of: lastAttachmentSource) { _, _ in
            refreshAttachmentSourceHistory()
        }
        .onDisappear {
            pendingBottomSnapTask?.cancel()
            pendingBottomSnapTask = nil
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
        .task {
            legacyJSONMigrationManager.refreshStatus()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.memoryRetryStoppedNoticeMessage)
    }
}

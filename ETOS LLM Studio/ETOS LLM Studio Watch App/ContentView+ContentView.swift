// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio Watch App 主视图文件 
//
// 功能特性:
// - 应用的主界面，负责组合聊天列表和输入框
// - 连接 ChatViewModel 来驱动视图
// - 管理 Sheet 和导航
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText)
import CoreText
#endif


struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase
    
    // MARK: - 状态对象
    
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
    let inputBubbleVerticalPadding: CGFloat = 8
    let emptyStateSpacerHeight: CGFloat = 120
    let bottomAnchorID = "inputBubble"
}

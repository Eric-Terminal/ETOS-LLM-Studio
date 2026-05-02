// ============================================================================
// ChatView.swift
// ============================================================================
// 聊天主界面 (iOS) - Telegram 风格
// - Telegram 风格的顶部导航栏（标题 + 副标题）
// - Telegram 风格的底部输入栏（圆角输入框 + 附件 + 发送按钮）
// - 支持壁纸背景、消息气泡
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
import UIKit
import PhotosUI
import Photos
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Telegram 主题颜色

struct ChatView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @ObservedObject var toolPermissionCenter = ToolPermissionCenter.shared
    @ObservedObject var ttsManager = TTSManager.shared
    @State var showScrollToBottom = false
    @State var suppressAutoScrollOnce = false
    @State var navigationDestination: ChatNavigationDestination?
    @State var editingMessage: ChatMessage?
    @State var messageInfo: MessageInfoPayload?
    @State var showBranchOptions = false
    @State var messageToBranch: ChatMessage?
    @State var messageToDelete: ChatMessage?
    @State var messageVersionToDelete: ChatMessage?
    @State var messageActionSheetPayload: MessageActionSheetPayload?
    @State var fullErrorContent: FullErrorContentPayload?
    @State var showModelPickerPanel = false
    @State var showSessionPickerPanel = false
    @State var editingSessionID: UUID?
    @State var sessionDraftName: String = ""
    @State var sessionToDelete: ChatSession?
    @State var sessionInfo: SessionPickerInfoPayload?
    @State var showGhostSessionAlert = false
    @State var ghostSession: ChatSession?
    @State var sessionPickerSearchText: String = ""
    @State var sessionPickerSearchHits: [UUID: SessionHistorySearchHit] = [:]
    @State var isSessionPickerSearching: Bool = false
    @State var sessionPickerLatestSearchToken: Int = 0
    @State var sessionPickerPendingSearchWorkItem: DispatchWorkItem?
    @State var showSessionPickerSearchInput: Bool = false
    @State var sessionPickerPageIndex: Int = 0
    @State var sessionPickerSearchResultPageIndex: Int = 0
    @State var imageDownloadAlertMessage: String?
    @State var exportSharePayload: ChatExportSharePayload?
    @State var exportErrorMessage: String?
    @State var activeChatPickerSheet: ChatPickerSheet?
    @State var bottomSafeAreaInset: CGFloat = 0
    @State var keyboardHeight: CGFloat = 0
    @State var chatInputBarHeight: CGFloat = 0
    @State var scrollDistanceToBottom: CGFloat = 0
    @State var pendingHistoryResetWorkItem: DispatchWorkItem?
    @State var pendingBottomSnapTask: Task<Void, Never>?
    @State var needsImmediateBottomSnap: Bool = true
    @State var pendingJumpRequest: MessageJumpRequest?
    @FocusState var composerFocused: Bool
    @FocusState var sessionPickerSearchFocused: Bool
    @AppStorage("chat.composer.draft") var draftText: String = ""
    @AppStorage(ChatNavigationMode.storageKey) var chatNavigationModeRawValue: String = ChatNavigationMode.defaultMode.rawValue
    @AppStorage(ChatPickerPresentationStyle.storageKey) var chatPickerPresentationStyleRawValue: String = ChatPickerPresentationStyle.defaultStyle.rawValue
    @AppStorage(ChatMessageActionPresentationStyle.storageKey) var chatMessageActionPresentationStyleRawValue: String = ChatMessageActionPresentationStyle.defaultStyle.rawValue
    @Namespace var modelPickerNamespace
    @Namespace var sessionPickerNamespace
    
    let scrollBottomAnchorID = "chat-scroll-bottom"
    let navBarTitleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
    let navBarSubtitleFont = UIFont.systemFont(ofSize: 12)
    let navBarVerticalPadding: CGFloat = 8
    let navBarPillVerticalPadding: CGFloat = 6
    let navBarPillSpacing: CGFloat = 1
    let navBarBlurFadeMinHeight: CGFloat = 44
    let navBarBlurFadeMaxHeight: CGFloat = 96
    let navBarBlurFadeHeightRatio: CGFloat = 0.06
    let modelPickerHeightRatio: CGFloat = 0.4
    let modelPickerCornerRadius: CGFloat = 24
    let modelPickerAnimation = Animation.spring(response: 0.42, dampingFraction: 0.82)
    let scrollToBottomButtonAnimation = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.52)
    let longDistanceScrollAnimationThresholdScreens: CGFloat = 25
    let modelPickerMorphID = "modelPickerMorph"
    let sessionPickerMorphID = "sessionPickerMorph"
    let sessionPickerHeightRatio: CGFloat = 0.6
    let sessionPickerCornerRadius: CGFloat = 26
    let sessionPickerMaxSessionsPerPage = 100
    let transcriptExportService = ChatTranscriptExportService()
}

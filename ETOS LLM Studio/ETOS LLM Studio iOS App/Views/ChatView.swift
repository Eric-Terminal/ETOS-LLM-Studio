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
struct TelegramColors {
    // 导航栏颜色
    static let navBarText = Color.primary
    static let navBarSubtitle = Color.secondary
    
    // 输入栏颜色
    static let inputBackground = Color(uiColor: .systemBackground)
    static let inputFieldBackground = Color(uiColor: .secondarySystemBackground)
    static let inputBorder = Color(uiColor: .separator)
    static let attachButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    static let sendButtonColor = Color(red: 0.33, green: 0.47, blue: 0.65)
    
    // 滚动按钮
    static let scrollButtonBackground = Color(uiColor: .systemBackground)
    static let scrollButtonShadow = Color.black.opacity(0.15)
}


func resolvedFileMimeType(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext),
       let mimeType = type.preferredMIMEType {
        return mimeType
    }
    return "application/octet-stream"
}


struct ChatExportSharePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}


struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]?

    init(activityItems: [Any], applicationActivities: [UIActivity]? = nil) {
        self.activityItems = activityItems
        self.applicationActivities = applicationActivities
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}


extension View {
    @ViewBuilder
    func messageActionPresentation<MenuContent: View>(
        usesBottomSheet: Bool,
        onPresentSheet: @escaping () -> Void,
        @ViewBuilder contextMenuContent: @escaping () -> MenuContent
    ) -> some View {
        if usesBottomSheet {
            self.contentShape(Rectangle())
        } else {
            self.contextMenu {
                contextMenuContent()
            }
        }
    }
}


enum ChatPickerSheet: String, Identifiable {
    case session
    case model

    var id: String { rawValue }
}


struct MessageActionSheetPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
}


enum MessageActionExportScope: String, CaseIterable, Identifiable {
    case fullSession
    case upToMessage

    var id: String { rawValue }
}


struct SafeAreaBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


struct ChatInputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


struct ScrollDistanceToBottomObserver: UIViewRepresentable {
    let onDistanceChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDistanceChange: onDistanceChange)
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.onDistanceChange = onDistanceChange
        uiView.coordinator = context.coordinator
        DispatchQueue.main.async {
            uiView.attachToScrollViewIfNeeded()
        }
    }

    final class Coordinator {
        var onDistanceChange: (CGFloat) -> Void
        weak var scrollView: UIScrollView?
        var contentOffsetObservation: NSKeyValueObservation?
        var contentSizeObservation: NSKeyValueObservation?
        var boundsObservation: NSKeyValueObservation?

        init(onDistanceChange: @escaping (CGFloat) -> Void) {
            self.onDistanceChange = onDistanceChange
        }

        func attach(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else {
                notifyDistanceChange()
                return
            }

            self.scrollView = scrollView
            contentOffsetObservation = scrollView.observe(\.contentOffset, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyDistanceChange()
            }
            contentSizeObservation = scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyDistanceChange()
            }
            boundsObservation = scrollView.observe(\.bounds, options: [.initial, .new]) { [weak self] _, _ in
                self?.notifyDistanceChange()
            }
        }

        func notifyDistanceChange() {
            guard let scrollView else { return }
            let visibleMaxY = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
            let distanceToBottom = max(scrollView.contentSize.height - visibleMaxY, 0)
            onDistanceChange(distanceToBottom)
        }
    }

    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachToScrollViewIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            attachToScrollViewIfNeeded()
        }

        func attachToScrollViewIfNeeded() {
            guard let coordinator, let scrollView = enclosingScrollView() else { return }
            coordinator.attach(to: scrollView)
        }

        func enclosingScrollView() -> UIScrollView? {
            var currentSuperview = superview
            while let view = currentSuperview {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                currentSuperview = view.superview
            }
            return nil
        }
    }
}


// MARK: - Helpers

extension ChatView {
    func resolvePendingSearchJumpIfNeeded() {
        guard let target = viewModel.pendingSearchJumpTarget,
              viewModel.currentSession?.id == target.sessionID,
              !viewModel.allMessagesForSession.isEmpty else {
            return
        }
        guard jumpToMessage(displayIndex: target.messageOrdinal) else { return }
        viewModel.clearPendingMessageJumpTarget()
    }

    func jumpToMessage(displayIndex: Int) -> Bool {
        let targetZeroBasedIndex = displayIndex - 1
        guard targetZeroBasedIndex >= 0, targetZeroBasedIndex < viewModel.allMessagesForSession.count else {
            return false
        }

        let targetMessageID = viewModel.allMessagesForSession[targetZeroBasedIndex].id
        let isVisible = viewModel.displayMessages.contains(where: { $0.id == targetMessageID })
        if !isVisible {
            viewModel.loadEntireHistory()
        }

        DispatchQueue.main.async {
            pendingJumpRequest = MessageJumpRequest(messageID: targetMessageID)
        }
        return true
    }

    func shouldMergeTurnMessages(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard let message, let nextMessage else { return false }
        return ChatResponseAttemptSupport.shouldMergeAdjacentAssistantTurnMessages(message, nextMessage)
    }

    func shouldConnectTimeline(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard shouldMergeTurnMessages(message, with: nextMessage) else { return false }
        return hasTimelineLineContent(message) && hasTimelineLineContent(nextMessage)
    }

    func hasTimelineLineContent(_ message: ChatMessage?) -> Bool {
        guard let message, isAssistantTurnMessage(message) else { return false }
        let hasReasoning = !(message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasNonWidgetToolCall = (message.toolCalls ?? []).contains { call in
            call.toolName != AppToolKind.showWidget.toolName
        }
        return hasReasoning || hasNonWidgetToolCall
    }

    func isAssistantTurnMessage(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .assistant, .tool, .system:
            return true
        case .user, .error:
            return false
        @unknown default:
            return false
        }
    }

    func scrollToBottom(
        proxy: ScrollViewProxy,
        animated: Bool = true,
        animation: Animation = .easeOut(duration: 0.25)
    ) {
        let action = {
            proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation(animation) {
                action()
            }
        } else {
            action()
        }
    }

    func handleScrollToBottomButtonTap(proxy: ScrollViewProxy) {
        pendingHistoryResetWorkItem?.cancel()

        let shouldAnimate = shouldAnimateScrollToBottomButton
        let shouldResetHistoryWindow = viewModel.lazyLoadMessageCount > 0
        showScrollToBottom = false
        scrollToBottom(
            proxy: proxy,
            animated: shouldAnimate,
            animation: scrollToBottomButtonAnimation
        )

        guard shouldResetHistoryWindow else {
            pendingHistoryResetWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                viewModel.resetLazyLoadState()
            }
            scrollToBottom(proxy: proxy, animated: false)
            pendingHistoryResetWorkItem = nil
        }
        pendingHistoryResetWorkItem = workItem

        let delay = shouldAnimate ? 0.56 : 0.08
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func scheduleImmediateBottomSnap(proxy: ScrollViewProxy) {
        pendingBottomSnapTask?.cancel()
        pendingBottomSnapTask = Task { @MainActor in
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy: proxy, animated: false)
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            needsImmediateBottomSnap = false
            pendingBottomSnapTask = nil
        }
    }

    func updateScrollToBottomVisibility(distanceToBottom: CGFloat) {
        let normalizedDistance = max(distanceToBottom, 0)
        DispatchQueue.main.async {
            scrollDistanceToBottom = normalizedDistance
            guard !viewModel.displayMessages.isEmpty else {
                if showScrollToBottom {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showScrollToBottom = false
                    }
                }
                return
            }
            let shouldShow = normalizedDistance > 48
            if showScrollToBottom != shouldShow {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showScrollToBottom = shouldShow
                }
            }
        }
    }

    var shouldAnimateScrollToBottomButton: Bool {
        let screenHeight = max(UIScreen.main.bounds.height, 1)
        return scrollDistanceToBottom <= screenHeight * longDistanceScrollAnimationThresholdScreens
    }

}


struct MessageJumpRequest: Equatable {
    let token = UUID()
    let messageID: UUID
}


// MARK: - Telegram Default Background

struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}


/// Telegram 风格默认背景（浅色图案）
struct TelegramDefaultBackground: View {
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 基础渐变背景
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.1, green: 0.12, blue: 0.15), Color(red: 0.08, green: 0.1, blue: 0.12)]
                        : [Color(red: 0.85, green: 0.9, blue: 0.92), Color(red: 0.88, green: 0.92, blue: 0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                
                // 图案覆盖层（模拟 Telegram 的微妙图案）
                TelegramPatternView()
                    .opacity(colorScheme == .dark ? 0.03 : 0.05)
            }
        }
        .ignoresSafeArea()
    }
}


/// Telegram 风格背景图案
struct TelegramPatternView: View {
    var body: some View {
        Canvas { context, size in
            let patternSize: CGFloat = 60
            let iconSize: CGFloat = 16
            
            for row in stride(from: 0, to: size.height + patternSize, by: patternSize) {
                for col in stride(from: 0, to: size.width + patternSize, by: patternSize) {
                    let offset = Int(row / patternSize) % 2 == 0 ? 0 : patternSize / 2
                    let x = col + offset
                    let y = row
                    
                    // 随机选择不同的图标
                    let iconIndex = Int(x + y) % 4
                    let symbolName: String
                    switch iconIndex {
                    case 0: symbolName = "bubble.left.fill"
                    case 1: symbolName = "heart.fill"
                    case 2: symbolName = "star.fill"
                    default: symbolName = "paperplane.fill"
                    }
                    
                    if let symbol = context.resolveSymbol(id: symbolName) {
                        context.draw(symbol, at: CGPoint(x: x, y: y))
                    } else {
                        // 绘制简单的圆形作为后备
                        let rect = CGRect(x: x - iconSize/2, y: y - iconSize/2, width: iconSize, height: iconSize)
                        context.fill(Circle().path(in: rect), with: .color(.gray))
                    }
                }
            }
        } symbols: {
            Image(systemName: "bubble.left.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("bubble.left.fill")
            
            Image(systemName: "heart.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("heart.fill")
            
            Image(systemName: "star.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("star.fill")
            
            Image(systemName: "paperplane.fill")
                .etFont(.system(size: 12))
                .foregroundColor(.gray)
                .tag("paperplane.fill")
        }
    }
}


// MARK: - Telegram Message Composer

enum AudioRecorderEntryMode {
    case attachment
    case speechInput
}


struct AskUserInputQuestionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}


struct CameraImagePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = PortraitCameraImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraImagePicker

        init(_ parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            parent.onImagePicked(image)
            parent.isPresented = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.isPresented = false
        }
    }
}


// MARK: - Session Picker

/// 会话信息弹窗的数据载体，用于隔离 UI 与业务模型
struct SessionPickerInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
}


struct MessageActionSheet: View {
    let payload: MessageActionSheetPayload
    let hasDisplayVersions: Bool
    let displayVersionCount: Int
    let displayCurrentVersionIndex: Int
    let canRetry: Bool
    let allMessages: [ChatMessage]
    @ObservedObject var ttsManager: TTSManager
    let onEdit: (ChatMessage) -> Void
    let onRetry: (ChatMessage) -> Void
    let onShowFullError: (String) -> Void
    let onBranch: (ChatMessage) -> Void
    let onExport: (ChatTranscriptExportFormat, Bool, ChatMessage?) -> Void
    let onSpeak: (ChatMessage) -> Void
    let onSwitchVersion: (Int, ChatMessage) -> Void
    let onDeleteCurrentVersion: (ChatMessage) -> Void
    let onDelete: (ChatMessage) -> Void
    let onDownloadImages: ([String]) -> Void
    let onCopy: (ChatMessage) -> Void
    let onInfo: (ChatMessage, Int) -> Void

    @Environment(\.dismiss) var dismiss
    @State var includeReasoning = true

    var message: ChatMessage {
        payload.message
    }

    var hasAttachments: Bool {
        message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
    }

    var messageIndex: Int? {
        allMessages.firstIndex(where: { $0.id == message.id })
    }

    var isSpeakingThisMessage: Bool {
        ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !hasAttachments {
                        Button {
                            onEdit(message)
                        } label: {
                            Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
                        }
                    }

                    if canRetry {
                        Button {
                            onRetry(message)
                        } label: {
                            Label(NSLocalizedString("重试", comment: ""), systemImage: "arrow.clockwise")
                        }
                    }

                    if message.role == .error, let fullContent = message.fullErrorContent {
                        Button {
                            onShowFullError(fullContent)
                        } label: {
                            Label(NSLocalizedString("查看完整响应", comment: ""), systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    Button {
                        onBranch(message)
                    } label: {
                        Label(NSLocalizedString("从此处创建分支", comment: ""), systemImage: "arrow.triangle.branch")
                    }

                    if message.role == .assistant || message.role == .tool || message.role == .system {
                        Button {
                            onSpeak(message)
                        } label: {
                            Label(
                                isSpeakingThisMessage ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""),
                                systemImage: isSpeakingThisMessage ? "stop.circle" : "speaker.wave.2"
                            )
                        }
                    }
                }

                Section(NSLocalizedString("导出", comment: "")) {
                    Toggle(NSLocalizedString("包含思考", comment: ""), isOn: $includeReasoning)

                    ForEach(MessageActionExportScope.allCases) { scope in
                        Menu {
                            ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { format in
                                Button {
                                    onExport(format, includeReasoning, scope == .upToMessage ? message : nil)
                                } label: {
                                    Label(format.displayName, systemImage: iconName(for: format))
                                }
                            }
                        } label: {
                            Label(
                                exportScopeTitle(scope),
                                systemImage: scope == .upToMessage ? "arrow.up.doc" : "square.and.arrow.up"
                            )
                        }
                    }
                }

                if hasDisplayVersions {
                    Section(NSLocalizedString("版本管理", comment: "")) {
                        Picker(NSLocalizedString("选择版本", comment: ""), selection: versionSelection) {
                            ForEach(0..<displayVersionCount, id: \.self) { index in
                                Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                                    .tag(index)
                            }
                        }

                        if displayVersionCount > 1 {
                            Button(role: .destructive) {
                                onDeleteCurrentVersion(message)
                            } label: {
                                Label(NSLocalizedString("删除当前版本", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }

                Section {
                    if let imageFileNames = message.imageFileNames, !imageFileNames.isEmpty {
                        Button {
                            onDownloadImages(imageFileNames)
                        } label: {
                            Label(NSLocalizedString("下载", comment: "Download generated image"), systemImage: "square.and.arrow.down")
                        }
                    }

                    Button {
                        onCopy(message)
                    } label: {
                        Label(NSLocalizedString("复制内容", comment: ""), systemImage: "doc.on.doc")
                    }

                    if let messageIndex {
                        Button {
                            onInfo(message, messageIndex)
                        } label: {
                            Label(NSLocalizedString("查看消息信息", comment: ""), systemImage: "info.circle")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(message)
                    } label: {
                        Label(hasDisplayVersions ? NSLocalizedString("删除所有版本", comment: "") : NSLocalizedString("删除消息", comment: ""), systemImage: "trash.fill")
                    }
                }
            }
            .navigationTitle(NSLocalizedString("消息操作", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
    }

    var versionSelection: Binding<Int> {
        Binding(
            get: { displayCurrentVersionIndex },
            set: { onSwitchVersion($0, message) }
        )
    }

    func exportScopeTitle(_ scope: MessageActionExportScope) -> String {
        switch scope {
        case .fullSession:
            return NSLocalizedString("导出整个会话", comment: "")
        case .upToMessage:
            return NSLocalizedString("导出到此消息（含上文）", comment: "")
        }
    }

    func iconName(for format: ChatTranscriptExportFormat) -> String {
        switch format {
        case .pdf:
            return "doc.richtext"
        case .markdown:
            return "number.square"
        case .text:
            return "doc.plaintext"
        }
    }
}


// MARK: - Message Info

/// 用于承载消息信息弹窗的数据结构，避免直接暴露ChatMessage本身。
struct MessageInfoPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
    let displayIndex: Int
    let totalCount: Int
}

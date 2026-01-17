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
import AVFoundation

// MARK: - Telegram 主题颜色
private struct TelegramColors {
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

struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showScrollToBottom = false
    @State private var navigationDestination: ChatNavigationDestination?
    @State private var editingMessage: ChatMessage?
    @State private var editingContent: String = ""
    @State private var messageInfo: MessageInfoPayload?
    @State private var showBranchOptions = false
    @State private var messageToBranch: ChatMessage?
    @State private var messageToDelete: ChatMessage?
    @State private var messageVersionToDelete: ChatMessage?
    @State private var fullErrorContent: FullErrorContentPayload?
    @FocusState private var composerFocused: Bool
    @AppStorage("chat.composer.draft") private var draftText: String = ""
    
    private let scrollBottomAnchorID = "chat-scroll-bottom"
    private let navBarTitleFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
    private let navBarSubtitleFont = UIFont.systemFont(ofSize: 12)
    private let navBarPillVerticalPadding: CGFloat = 6
    private let navBarPillSpacing: CGFloat = 1
    private var navBarPillHeight: CGFloat {
        navBarTitleFont.lineHeight
            + navBarSubtitleFont.lineHeight
            + navBarPillSpacing
            + navBarPillVerticalPadding * 2
    }
    private var navBarIconSize: CGFloat {
        navBarPillHeight
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Z-Index 0: 背景壁纸层（穿透安全区）
                telegramBackgroundLayer
                    .ignoresSafeArea()
                
                // Z-Index 1: 消息列表
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                            // 顶部留白（为导航栏留出空间）
                            Color.clear.frame(height: 8)
                            
                            // 历史加载提示
                            historyBanner
                            
                            // 消息列表
                            ForEach(viewModel.messages) { message in
                                ChatBubble(
                                    message: message,
                                    isReasoningExpanded: Binding(
                                        get: { viewModel.reasoningExpandedState[message.id, default: false] },
                                        set: { viewModel.reasoningExpandedState[message.id] = $0 }
                                    ),
                                    isToolCallsExpanded: Binding(
                                        get: { viewModel.toolCallsExpandedState[message.id, default: false] },
                                        set: { viewModel.toolCallsExpandedState[message.id] = $0 }
                                    ),
                                    enableMarkdown: viewModel.enableMarkdown,
                                    enableBackground: viewModel.enableBackground
                                )
                                .id(message.id)
                                .contextMenu {
                                    contextMenu(for: message)
                                }
                                .onAppear {
                                    if message.id == viewModel.messages.last?.id {
                                        showScrollToBottom = false
                                    }
                                }
                                .onDisappear {
                                    if message.id == viewModel.messages.last?.id {
                                        showScrollToBottom = true
                                    }
                                }
                            }
                            
                            Color.clear
                                .frame(height: 8)
                                .id(scrollBottomAnchorID)
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollIndicators(.hidden)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            composerFocused = false
                        }
                    )
                    .onChange(of: viewModel.messages.count) { _, _ in
                        guard !viewModel.messages.isEmpty else { return }
                        scrollToBottom(proxy: proxy)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        // Telegram 风格的滚动到底部按钮
                        if showScrollToBottom {
                            telegramScrollToBottomButton {
                                viewModel.resetLazyLoadState()
                                scrollToBottom(proxy: proxy)
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 80)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    // Telegram 风格：顶部导航栏
                    .safeAreaInset(edge: .top) {
                        telegramNavBar
                    }
                    // Telegram 风格：底部输入栏
                    .safeAreaInset(edge: .bottom) {
                        telegramInputBar
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .navigationDestination(item: $navigationDestination) { destination in
                switch destination {
                case .sessions:
                    SessionListView()
                case .settings:
                    SettingsView()
                }
            }
            .sheet(item: $editingMessage) { message in
                NavigationStack {
                    EditMessageSheet(
                        originalMessage: message,
                        text: $editingContent
                    ) { newContent in
                        viewModel.commitEditedMessage(message, content: newContent)
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $messageInfo) { info in
                MessageInfoSheet(payload: info)
            }
            .sheet(item: $fullErrorContent) { payload in
                FullErrorContentSheet(payload: payload)
            }
            .confirmationDialog("创建分支选项", isPresented: $showBranchOptions, titleVisibility: .visible) {
                Button("仅复制消息历史") {
                    if let message = messageToBranch {
                        let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: false)
                        viewModel.setCurrentSession(newSession)
                    }
                    messageToBranch = nil
                }
                Button("复制消息历史和提示词") {
                    if let message = messageToBranch {
                        let newSession = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: true)
                        viewModel.setCurrentSession(newSession)
                    }
                    messageToBranch = nil
                }
                Button("取消", role: .cancel) {
                    messageToBranch = nil
                }
            } message: {
                if let message = messageToBranch, let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
                    Text(String(format: NSLocalizedString("将从第 %d 条消息处创建新的分支会话。", comment: ""), index + 1))
                }
            }
            .alert("确认删除消息", isPresented: Binding(
                get: { messageToDelete != nil },
                set: { if !$0 { messageToDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let message = messageToDelete {
                        viewModel.deleteMessage(message)
                    }
                    messageToDelete = nil
                }
                Button("取消", role: .cancel) {
                    messageToDelete = nil
                }
            } message: {
                Text(messageToDelete?.hasMultipleVersions == true
                     ? "删除后将无法恢复这条消息的所有版本。"
                     : "删除后无法恢复这条消息。")
            }
            .alert("确认删除当前版本", isPresented: Binding(
                get: { messageVersionToDelete != nil },
                set: { if !$0 { messageVersionToDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let message = messageVersionToDelete {
                        viewModel.deleteCurrentVersion(of: message)
                    }
                    messageVersionToDelete = nil
                }
                Button("取消", role: .cancel) {
                    messageVersionToDelete = nil
                }
            } message: {
                Text("删除后将无法恢复此版本的内容。")
            }
        }
    }
    
    // MARK: - Background
    
    /// Telegram 风格的背景层
    private var telegramBackgroundLayer: some View {
        GeometryReader { geometry in
            Group {
                if viewModel.enableBackground,
                   let image = viewModel.currentBackgroundImageUIImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: viewModel.backgroundBlur)
                        .opacity(viewModel.backgroundOpacity)
                } else {
                    // Telegram 默认背景 - 浅色图案背景
                    TelegramDefaultBackground()
                }
            }
        }
    }

// MARK: - Telegram Style Components

    /// Telegram 风格导航栏
    @ViewBuilder
    private var telegramNavBar: some View {
        HStack(spacing: 12) {
            navBarModelMenu

            Spacer(minLength: 12)

            Button {
                navigationDestination = .sessions
            } label: {
                navBarCenterPill
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Menu {
                Button {
                    viewModel.createNewSession()
                } label: {
                    Label("新建会话", systemImage: "square.and.pencil")
                }

                Button {
                    navigationDestination = .sessions
                } label: {
                    Label("会话列表", systemImage: "list.bullet")
                }

                Button {
                    navigationDestination = .settings
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            } label: {
                navBarIconLabel(systemName: "ellipsis", accessibilityLabel: "更多")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var navBarModelMenu: some View {
        Menu {
            if viewModel.activatedModels.isEmpty {
                Button("暂无可用模型") {}
                    .disabled(true)
            } else {
                ForEach(viewModel.activatedModels, id: \.id) { runnable in
                    Button {
                        viewModel.setSelectedModel(runnable)
                    } label: {
                        if runnable.id == viewModel.selectedModel?.id {
                            Label(
                                "\(runnable.model.displayName) · \(runnable.provider.name)",
                                systemImage: "checkmark"
                            )
                        } else {
                            Text("\(runnable.model.displayName) · \(runnable.provider.name)")
                        }
                    }
                }
            }
        } label: {
            navBarIconLabel(systemName: "cpu", accessibilityLabel: "切换模型")
        }
        .buttonStyle(.plain)
    }

    private func navBarIconLabel(systemName: String, accessibilityLabel: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(TelegramColors.navBarText)
            .frame(width: navBarIconSize, height: navBarIconSize)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
            )
            .contentShape(Circle())
            .accessibilityLabel(accessibilityLabel)
    }

    private var navBarCenterPill: some View {
        VStack(spacing: navBarPillSpacing) {
            MarqueeText(
                content: viewModel.currentSession?.name ?? "新的对话",
                uiFont: navBarTitleFont
            )
            .foregroundColor(TelegramColors.navBarText)
            .allowsHitTesting(false)

            if viewModel.activatedModels.isEmpty {
                MarqueeText(content: "选择模型以开始", uiFont: navBarSubtitleFont)
                    .foregroundColor(TelegramColors.navBarSubtitle)
                    .allowsHitTesting(false)
            } else {
                MarqueeText(content: modelSubtitle, uiFont: navBarSubtitleFont)
                    .foregroundColor(TelegramColors.navBarSubtitle)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, navBarPillVerticalPadding)
        .frame(height: navBarPillHeight)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
    }

    private var modelSubtitle: String {
        if let selectedModel = viewModel.selectedModel {
            return "\(selectedModel.model.displayName) · \(selectedModel.provider.name)"
        }
        return "选择模型"
    }

    /// Telegram 风格输入栏
    @ViewBuilder
    private var telegramInputBar: some View {
        TelegramMessageComposer(
            text: Binding(
                get: { draftText },
                set: { newValue in
                    draftText = newValue
                    viewModel.userInput = newValue
                }
            ),
            isSending: viewModel.isSendingMessage,
            sendAction: {
                guard viewModel.canSendMessage else { return }
                viewModel.sendMessage()
                draftText = ""
            },
            focus: $composerFocused
        )
        .onAppear {
            viewModel.userInput = draftText
        }
    }
    
    /// Telegram 风格滚动到底部按钮
    @ViewBuilder
    private func telegramScrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(TelegramColors.scrollButtonBackground)
                    .frame(width: 40, height: 40)
                    .shadow(color: TelegramColors.scrollButtonShadow, radius: 4, x: 0, y: 2)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(TelegramColors.attachButtonColor)
            }
        }
        .accessibilityLabel("滚动到底部")
    }
    
    /// Telegram 风格历史加载提示
    @ViewBuilder
    private var historyBanner: some View {
        let remaining = viewModel.allMessagesForSession.count - viewModel.messages.count
        if remaining > 0 && !viewModel.isHistoryFullyLoaded {
            let chunk = min(remaining, viewModel.historyLoadChunkSize)
            Button {
                withAnimation {
                    viewModel.loadMoreHistoryChunk()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 14))
                    Text(String(format: NSLocalizedString("加载更早的 %d 条消息", comment: ""), chunk))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(TelegramColors.attachButtonColor)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(
                    Capsule()
                        .fill(Color(uiColor: .systemBackground).opacity(0.9))
                        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func contextMenu(for message: ChatMessage) -> some View {
        // 有音频或图片附件的消息不显示编辑按钮
        let hasAttachments = message.audioFileName != nil || (message.imageFileNames?.isEmpty == false)
        
        if !hasAttachments {
            Button {
                editingMessage = message
                editingContent = message.content
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }
        
        if viewModel.canRetry(message: message) {
            Button {
                viewModel.retryMessage(message)
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
        }
        
        // 如果错误消息有完整内容（被截断），显示查看完整响应按钮
        if message.role == .error, let fullContent = message.fullErrorContent {
            Button {
                fullErrorContent = FullErrorContentPayload(content: fullContent)
            } label: {
                Label("查看完整响应", systemImage: "doc.text.magnifyingglass")
            }
        }
        
        Button {
            messageToBranch = message
            showBranchOptions = true
        } label: {
            Label("从此处创建分支", systemImage: "arrow.triangle.branch")
        }
        
        Divider()
        
        // 版本管理菜单项
        if message.hasMultipleVersions {
            Menu {
                ForEach(0..<message.getAllVersions().count, id: \.self) { index in
                    Button {
                        viewModel.switchToVersion(index, of: message)
                    } label: {
                        HStack {
                            Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                            if index == message.getCurrentVersionIndex() {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label(
                    String(
                        format: NSLocalizedString("切换版本 (%d/%d)", comment: ""),
                        message.getCurrentVersionIndex() + 1,
                        message.getAllVersions().count
                    ),
                    systemImage: "clock.arrow.circlepath"
                )
            }
            
            if message.getAllVersions().count > 1 {
                Button(role: .destructive) {
                    messageVersionToDelete = message
                } label: {
                    Label("删除当前版本", systemImage: "trash")
                }
            }
            
            Divider()
        }
        
        Button(role: .destructive) {
            messageToDelete = message
        } label: {
            Label(message.hasMultipleVersions ? "删除所有版本" : "删除消息", systemImage: "trash.fill")
        }
        
        Divider()
        
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("复制内容", systemImage: "doc.on.doc")
        }
        
        if let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
            Button {
                messageInfo = MessageInfoPayload(
                    message: message,
                    displayIndex: index + 1,
                    totalCount: viewModel.allMessagesForSession.count
                )
            } label: {
                Label("查看消息信息", systemImage: "info.circle")
            }
        }
    }
}

// MARK: - Helpers

private extension ChatView {
    func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo(scrollBottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                action()
            }
        } else {
            action()
        }
    }
}

// MARK: - Telegram Default Background

/// Telegram 风格默认背景（浅色图案）
private struct TelegramDefaultBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    
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
private struct TelegramPatternView: View {
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
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .tag("bubble.left.fill")
            
            Image(systemName: "heart.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .tag("heart.fill")
            
            Image(systemName: "star.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .tag("star.fill")
            
            Image(systemName: "paperplane.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .tag("paperplane.fill")
        }
    }
}

// MARK: - Telegram Message Composer

/// Telegram 风格的消息输入框
private struct TelegramMessageComposer: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State private var showAttachmentMenu = false
    @State private var showImagePicker = false
    @State private var showAudioRecorder = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // 分隔线
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 0.5)
            
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil {
                telegramAttachmentPreview
            }
            
            // 主输入栏
            HStack(alignment: .bottom, spacing: 8) {
                // 附件按钮
                Button {
                    showAttachmentMenu = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(TelegramColors.attachButtonColor)
                        .frame(width: 36, height: 36)
                }
                .confirmationDialog("添加附件", isPresented: $showAttachmentMenu) {
                    Button("选择图片") {
                        showImagePicker = true
                    }
                    Button("录制语音") {
                        showAudioRecorder = true
                    }
                    Button("取消", role: .cancel) {}
                }
                
                // 输入框容器
                HStack(alignment: .bottom, spacing: 8) {
                    // 文本输入框
                    TextField("消息", text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .textFieldStyle(.plain)
                        .focused(focus)
                        .font(.system(size: 16))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(TelegramColors.inputFieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(TelegramColors.inputBorder, lineWidth: 0.5)
                )
                
                // 发送按钮或麦克风按钮
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingImageAttachments.isEmpty && viewModel.pendingAudioAttachment == nil {
                    // 麦克风按钮（无内容时）
                    Button {
                        showAudioRecorder = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(TelegramColors.attachButtonColor)
                            .frame(width: 36, height: 36)
                    }
                } else {
                    // 发送按钮
                    Button {
                        sendAction()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(
                                    viewModel.canSendMessage
                                        ? TelegramColors.sendButtonColor
                                        : Color.gray.opacity(0.3)
                                )
                                .frame(width: 36, height: 36)
                            
                            if isSending {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .disabled(!viewModel.canSendMessage)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(TelegramColors.inputBackground)
        }
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            viewModel.addImageAttachment(image)
                        }
                    }
                }
                selectedPhotos = []
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(format: viewModel.audioRecordingFormat) { attachment in
                viewModel.setAudioAttachment(attachment)
            }
        }
    }
    
    /// Telegram 风格附件预览
    @ViewBuilder
    private var telegramAttachmentPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        
                        Button {
                            viewModel.removePendingImageAttachment(attachment)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.5))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                        .offset(x: 6, y: -6)
                    }
                }
                
                // 音频预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 18))
                            .foregroundColor(TelegramColors.attachButtonColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("语音消息")
                                .font(.system(size: 13, weight: .medium))
                            Text(audio.fileName)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(TelegramColors.inputBackground)
    }
}

// MARK: - Legacy Composer (kept for compatibility)

private struct MessageComposerView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    @State private var showAttachmentMenu = false
    @State private var showImagePicker = false
    @State private var showAudioRecorder = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    
    var body: some View {
        VStack(spacing: 8) {
            // 附件预览区域
            if !viewModel.pendingImageAttachments.isEmpty || viewModel.pendingAudioAttachment != nil {
                attachmentPreviewBar
                    .padding(.horizontal, 12)
            }
            
            HStack(alignment: .center, spacing: 12) {
                // 加号按钮（圆形）
                if #available(iOS 26.0, *) {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .confirmationDialog("添加附件", isPresented: $showAttachmentMenu) {
                        Button("选择图片") {
                            showImagePicker = true
                        }
                        Button("录制语音") {
                            showAudioRecorder = true
                        }
                    }
                } else {
                    Button {
                        showAttachmentMenu = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .confirmationDialog("添加附件", isPresented: $showAttachmentMenu) {
                        Button("选择图片") {
                            showImagePicker = true
                        }
                        Button("录制语音") {
                            showAudioRecorder = true
                        }
                    }
                }
                
                // 输入框（拉长的药丸型）
                if #available(iOS 26.0, *) {
                    HStack(spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .glassEffect(.clear, in: Capsule())
                } else {
                    HStack(spacing: 8) {
                        TextField("Message", text: $text, axis: .vertical)
                            .lineLimit(1...6)
                            .textFieldStyle(.plain)
                            .focused(focus)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .background(
                        Capsule()
                            .fill(Color(uiColor: .secondarySystemFill))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                }
                
                // 发送箭头（圆形）
                if #available(iOS 26.0, *) {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .glassEffect(.clear, in: Circle())
                    .disabled(!viewModel.canSendMessage)
                } else {
                    Button {
                        sendAction()
                    } label: {
                        Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!viewModel.canSendMessage)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .photosPicker(isPresented: $showImagePicker, selection: $selectedPhotos, maxSelectionCount: 4, matching: .images)
        .onChange(of: selectedPhotos) { _, newItems in
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            viewModel.addImageAttachment(image)
                        }
                    }
                }
                selectedPhotos = []
            }
        }
        .sheet(isPresented: $showAudioRecorder) {
            AudioRecorderSheet(format: viewModel.audioRecordingFormat) { attachment in
                viewModel.setAudioAttachment(attachment)
            }
        }
    }
    
    @ViewBuilder
    private var attachmentPreviewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 图片预览
                ForEach(viewModel.pendingImageAttachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let thumbnail = attachment.thumbnailImage {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            viewModel.removePendingImageAttachment(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
                
                // 音频预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 16))
                            .foregroundStyle(.tint)
                        
                        Text(audio.fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: 80)
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Audio Recorder Sheet

private struct AudioRecorderSheet: View {
    let format: AudioRecordingFormat
    let onComplete: (AudioAttachment) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var isRecording = false
    @State private var recordingDuration: TimeInterval = 0
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var timer: Timer?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                // 录音时长显示
                Text(formatDuration(recordingDuration))
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(isRecording ? .red : .primary)
                
                // 录音按钮
                Button {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isRecording ? Color.red : Color.accentColor)
                            .frame(width: 80, height: 80)
                        
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(isRecording ? .white : (colorScheme == .dark ? .black : .white))
                    }
                }
                
                if isRecording {
                    Text("正在录音...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("点击开始录音")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            .navigationTitle("录制语音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelRecording()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        finishRecording()
                    }
                    .disabled(recordingURL == nil || isRecording)
                }
            }
        }
        .onDisappear {
            cancelRecording()
        }
    }
    
    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(format.fileExtension)")
            
            let settings: [String: Any]
            switch format {
            case .aac:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            case .wav:
                settings = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            @unknown default:
                // 默认使用 AAC 格式
                settings = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000
                ]
            }
            
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            
            recordingURL = url
            isRecording = true
            recordingDuration = 0
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                recordingDuration += 0.1
            }
        } catch {
            // 录音启动失败
        }
    }
    
    private func stopRecording() {
        timer?.invalidate()
        timer = nil
        audioRecorder?.stop()
        isRecording = false
    }
    
    private func cancelRecording() {
        stopRecording()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
    }
    
    private func finishRecording() {
        stopRecording()
        guard let url = recordingURL,
              let data = try? Data(contentsOf: url) else {
            dismiss()
            return
        }
        
        let attachment = AudioAttachment(
            data: data,
            mimeType: format.mimeType,
            format: format.fileExtension,
            fileName: url.lastPathComponent
        )
        
        try? FileManager.default.removeItem(at: url)
        onComplete(attachment)
        dismiss()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let tenths = Int((duration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }
}

// MARK: - Edit Sheet

private struct EditMessageSheet: View {
    let originalMessage: ChatMessage
    @Binding var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Form {
            Section("原始内容") {
                Text(originalMessage.content)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            
            Section("编辑后") {
                TextEditor(text: $text)
                    .frame(minHeight: 160)
            }
        }
        .navigationTitle("编辑消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave(text)
                    dismiss()
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

// MARK: - Message Info

/// 用于承载消息信息弹窗的数据结构，避免直接暴露ChatMessage本身。
private struct MessageInfoPayload: Identifiable {
    let id = UUID()
    let message: ChatMessage
    let displayIndex: Int
    let totalCount: Int
}

/// 用于承载完整错误响应内容的数据结构
private struct FullErrorContentPayload: Identifiable {
    let id = UUID()
    let content: String
}

/// 完整错误响应内容弹窗
private struct FullErrorContentSheet: View {
    let payload: FullErrorContentPayload
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(payload.content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("完整响应")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = payload.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}

/// 消息详情弹窗，展示消息的唯一标识与位置索引。
private struct MessageInfoSheet: View {
    let payload: MessageInfoPayload
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    LabeledContent("角色") {
                        Text(roleDescription(payload.message.role))
                    }
                    LabeledContent("列表位置") {
                        Text(
                            String(
                                format: NSLocalizedString("第 %d / %d 条", comment: ""),
                                payload.displayIndex,
                                payload.totalCount
                            )
                        )
                    }
                }
                
                Section("唯一标识") {
                    Text(payload.message.id.uuidString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("消息信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
    
    /// 将消息角色转换为易读的中文描述
        private func roleDescription(_ role: MessageRole) -> String {
            switch role {
            case .system:
                return "系统"
            case .user:
                return "用户"
            case .assistant:
                return "助手"
            case .tool:
                return "工具"
            case .error:
                return "错误"
            @unknown default:
                return "未知"
            }
        }
    }

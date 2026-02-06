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

struct ContentView: View {
    
    // MARK: - 状态对象
    
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var announcementManager = AnnouncementManager.shared
    @ObservedObject private var toolPermissionCenter = ToolPermissionCenter.shared
    @State private var isAtBottom = true
    @State private var showScrollToBottomButton = false
    @State private var fullErrorContent: String?
    @State private var shouldForceScrollToBottom = false
    @State private var suppressAutoScrollOnce = false
    private let inputControlHeight: CGFloat = 38
    private let inputBubbleVerticalPadding: CGFloat = 8
    private let emptyStateSpacerHeight: CGFloat = 120
    private let bottomAnchorID = "inputBubble"
    
    private var isLiquidGlassEnabled: Bool {
        if #available(watchOS 26.0, *) {
            return viewModel.enableLiquidGlass
        } else {
            return false
        }
    }
    
    // MARK: - 视图主体
    
    var body: some View {
        ZStack {
            // 背景图
            if viewModel.enableBackground, let bgImage = viewModel.currentBackgroundImageBlurredUIImage {
                GeometryReader { proxy in
                    let size = proxy.size
                    ZStack {
                        if viewModel.backgroundContentMode == "fit" {
                            colorScheme == .dark ? Color.black : Color(white: 0.95)
                        }
                        
                        Image(uiImage: bgImage)
                            .resizable()
                            .aspectRatio(contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit)
                            .frame(width: size.width, height: size.height)
                            .position(x: size.width / 2, y: size.height / 2)
                            .clipped()
                            .opacity(viewModel.backgroundOpacity)
                    }
                    .frame(width: size.width, height: size.height)
                }
                .ignoresSafeArea()
            }
            
            // 主导航
            NavigationStack {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        chatList(proxy: proxy)

                        if showScrollToBottomButton {
                            scrollToBottomButton(proxy: proxy)
                        }
                    }
                }
                .navigationTitle(viewModel.currentSession?.name ?? "新对话")
                .sheet(item: $viewModel.activeSheet) { item in
                    sheetView(for: item)
                }
                .sheet(item: Binding(
                    get: { fullErrorContent.map { FullErrorContentWrapper(content: $0) } },
                    set: { _ in fullErrorContent = nil }
                )) { wrapper in
                    FullErrorContentView(content: wrapper.content)
                }
            }
            .onChange(of: viewModel.activeSheet) {
                if viewModel.activeSheet == nil {
                    viewModel.saveCurrentSessionDetails()
                }
            }
        }
    }
    
    // MARK: - 视图组件
    
    @ViewBuilder
    private func sheetView(for item: ActiveSheet) -> some View {
        // 修复: 增加 @unknown default 来处理未来可能的 case
        switch item {
        case .editMessage:
            // 修复: 将 var 改为 let，因为该变量未被修改
            if let messageToEdit = viewModel.messageToEdit {
                EditMessageView(message: messageToEdit, onSave: { updatedMessage in
                    viewModel.commitEditedMessage(updatedMessage)
                })
            }
        case .settings:
            SettingsView(viewModel: viewModel)
        @unknown default:
            Text("未知视图")
        }
    }
    
    private func chatList(proxy: ScrollViewProxy) -> some View {
        let displayedMessages = viewModel.displayMessages
        return List {
            if viewModel.messages.isEmpty {
                Spacer().frame(height: emptyStateSpacerHeight).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            
            let remainingCount = viewModel.remainingHistoryCount
            if !viewModel.isHistoryFullyLoaded && remainingCount > 0 {
                let chunk = viewModel.historyLoadChunkCount
                Button(action: {
                    suppressAutoScrollOnce = true
                    withAnimation {
                        viewModel.loadMoreHistoryChunk()
                    }
                }) {
                    Label(
                        String(format: NSLocalizedString("向上加载 %d 条记录", comment: ""), chunk),
                        systemImage: "arrow.up.circle"
                    )
                }
                .buttonStyle(.bordered)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
            }

            ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, state in
                let message = state.message
                let previousMessage = index > 0 ? displayedMessages[index - 1].message : nil
                let nextMessage = index + 1 < displayedMessages.count ? displayedMessages[index + 1].message : nil
                let mergeWithPrevious = shouldMergeTurnMessages(previousMessage, with: message)
                let mergeWithNext = shouldMergeTurnMessages(message, with: nextMessage)
                messageRow(
                    for: state,
                    proxy: proxy,
                    mergeWithPrevious: mergeWithPrevious,
                    mergeWithNext: mergeWithNext
                )
            }

            inputBubble
                .id(bottomAnchorID)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .onAppear { isAtBottom = true; showScrollToBottomButton = false }
                .onDisappear { isAtBottom = false; showScrollToBottomButton = true }
        }
        .listStyle(.plain)
        .background(Color.clear)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { viewModel.activeSheet = .settings }) {
                    Image(systemName: "gearshape.fill")
                }
            }
        }
        .onChange(of: viewModel.messages.count) {
            if suppressAutoScrollOnce {
                suppressAutoScrollOnce = false
                return
            }
            let shouldScroll = isAtBottom || shouldForceScrollToBottom
            shouldForceScrollToBottom = false
            guard shouldScroll else { return }
            scrollToBottom(proxy: proxy, animated: false)
        }
        .onChange(of: toolPermissionCenter.activeRequest?.id) { _, newValue in
            guard newValue != nil, isAtBottom else { return }
            scrollToBottom(proxy: proxy, animated: false)
        }
    }
    
    /// 辅助函数，用于构建单个消息行，以简化 chatList 的主体
    private func messageRow(for state: ChatMessageRenderState, proxy: ScrollViewProxy, mergeWithPrevious: Bool, mergeWithNext: Bool) -> some View {
        let message = state.message
        let isReasoningExpandedBinding = Binding<Bool>(
            get: { viewModel.reasoningExpandedState[message.id, default: false] },
            set: { viewModel.reasoningExpandedState[message.id] = $0 }
        )
        
        let isToolCallsExpandedBinding = Binding<Bool>(
            get: { viewModel.toolCallsExpandedState[message.id, default: false] },
            set: { viewModel.toolCallsExpandedState[message.id] = $0 }
        )
        
        return ChatBubble(
            messageState: state,
            isReasoningExpanded: isReasoningExpandedBinding,
            isToolCallsExpanded: isToolCallsExpandedBinding,
            enableMarkdown: viewModel.enableMarkdown,
            enableBackground: viewModel.enableBackground,
            enableLiquidGlass: isLiquidGlassEnabled,
            mergeWithPrevious: mergeWithPrevious,
            mergeWithNext: mergeWithNext
        )
        .environmentObject(viewModel)
        .id(state.id)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .swipeActions(edge: .leading) {
            NavigationLink {
                MessageActionsView(
                    message: message,
                    canRetry: viewModel.canRetry(message: message),
                    onEdit: {
                        viewModel.messageToEdit = message
                        viewModel.activeSheet = .editMessage
                    },
                    onRetry: { message in
                        viewModel.retryMessage(message)
                    },
                    onDelete: {
                        viewModel.deleteMessage(message)
                    },
                    onDeleteCurrentVersion: {
                        viewModel.deleteCurrentVersion(of: message)
                    },
                    onSwitchVersion: { index in
                        viewModel.switchToVersion(index, of: message)
                    },
                    onBranch: { copyPrompts in
                        _ = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: copyPrompts)
                    },
                    onShowFullError: { content in
                        fullErrorContent = content
                    },
                    messageIndex: viewModel.allMessagesForSession.firstIndex { $0.id == message.id },
                    totalMessages: viewModel.allMessagesForSession.count
                )
            } label: {
                Label("更多", systemImage: "ellipsis")
            }
            .tint(.gray)
        }
    }
    
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        let scrollAction = {
            // 点击回底按钮时，重置懒加载状态到初始数量
            viewModel.resetLazyLoadState()
            scrollToBottom(proxy: proxy, animated: true)
        }
        
        return Button(action: scrollAction) {
            let icon = Image(systemName: "arrow.down.circle")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 60, height: 60)
                .opacity(0.4)
                .contentShape(Circle())
            
            if isLiquidGlassEnabled {
                if #available(watchOS 26.0, *) {
                    icon
                } else {
                    icon
                }
            } else {
                icon
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .transition(.scale.combined(with: .opacity))
    }

    private func shouldMergeTurnMessages(_ message: ChatMessage?, with nextMessage: ChatMessage?) -> Bool {
        guard let message, let nextMessage else { return false }
        return isAssistantTurnMessage(message) && isAssistantTurnMessage(nextMessage)
    }

    private func isAssistantTurnMessage(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .assistant, .tool, .system:
            return true
        case .user, .error:
            return false
        @unknown default:
            return false
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
        if animated {
            withAnimation {
                action()
            }
        } else {
            action()
        }
    }

    private func sendMessage() {
        shouldForceScrollToBottom = true
        viewModel.sendMessage()
    }

    private func sendOrStopMessage() {
        if viewModel.isSendingMessage {
            viewModel.cancelSending()
        } else {
            sendMessage()
        }
    }

    private var inputFillColor: Color {
        viewModel.enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3)
    }

    private var inputStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.12)
    }
    
    private var transparentInputField: some View {
        ZStack(alignment: .leading) {
            Text(viewModel.userInput.isEmpty ? "输入..." : viewModel.userInput)
                .foregroundStyle(viewModel.userInput.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsHitTesting(false)
            TextField("", text: $viewModel.userInput.watchKeyboardNewlineBinding())
                .textFieldStyle(.plain)
                .opacity(0.01)
                .accessibilityLabel("输入...")
        }
        .font(.body)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: inputControlHeight, maxHeight: inputControlHeight, alignment: .leading)
        .layoutPriority(1)
    }
    
    private var inputBubble: some View {
        // 是否可以发送：有文字或有音频附件
        let canSend = !viewModel.userInput.isEmpty || viewModel.pendingAudioAttachment != nil
        
        let coreBubble = Group {
            VStack(spacing: 6) {
                // 音频附件预览
                if let audio = viewModel.pendingAudioAttachment {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                        
                        Text(audio.fileName)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Button {
                            viewModel.clearPendingAudioAttachment()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.2))
                    .cornerRadius(8)
                }
                
                if isLiquidGlassEnabled {
                    HStack(spacing: 10) {
                        if #available(watchOS 26.0, *) {
                            transparentInputField
                                .glassEffect(.clear, in: Capsule())

                            Button(action: sendOrStopMessage) {
                                Image(systemName: viewModel.isSendingMessage ? "stop.circle.fill" : "arrow.up")
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: inputControlHeight, height: inputControlHeight)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.clear, in: Circle())
                            .disabled(!viewModel.isSendingMessage && !canSend)
                        } else {
                            ZStack {
                                Capsule()
                                    .fill(inputFillColor)
                                    .overlay(
                                        Capsule()
                                            .stroke(inputStrokeColor, lineWidth: 0.6)
                                    )
                                transparentInputField
                            }

                            Button(action: sendOrStopMessage) {
                                Image(systemName: viewModel.isSendingMessage ? "stop.circle.fill" : "arrow.up")
                                    .font(.system(size: 18, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .overlay(
                                Circle()
                                    .stroke(inputStrokeColor, lineWidth: 0.8)
                            )
                            .disabled(!viewModel.isSendingMessage && !canSend)
                        }
                    }
                    .frame(height: inputControlHeight)
                } else {
                    HStack(spacing: 12) {
                        ZStack {
                            Capsule()
                                .fill(inputFillColor)
                                .overlay(
                                    Capsule()
                                        .stroke(inputStrokeColor, lineWidth: 0.6)
                                )
                            transparentInputField
                        }

                        Button(action: sendOrStopMessage) {
                            Image(systemName: viewModel.isSendingMessage ? "stop.circle.fill" : "arrow.up")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .frame(width: inputControlHeight, height: inputControlHeight)
                        .background(
                            Circle().fill(inputFillColor)
                        )
                        .overlay(
                            Circle()
                                .stroke(inputStrokeColor, lineWidth: 0.8)
                        )
                        .disabled(!viewModel.isSendingMessage && !canSend)
                    }
                    .frame(height: inputControlHeight)
                    .padding(.horizontal, 10)
                    .background(viewModel.enableBackground ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
                    .cornerRadius(12)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, inputBubbleVerticalPadding)
        
        let speechSheetBinding = Binding(
            get: { viewModel.isSpeechRecorderPresented },
            set: { viewModel.isSpeechRecorderPresented = $0 }
        )
        let speechErrorBinding = Binding(
            get: { viewModel.showSpeechErrorAlert },
            set: { viewModel.showSpeechErrorAlert = $0 }
        )
        
        return coreBubble
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !viewModel.userInput.isEmpty || viewModel.pendingAudioAttachment != nil {
                    Button(role: .destructive) {
                        viewModel.clearUserInput()
                        viewModel.clearPendingAudioAttachment()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .contentShape(Circle())
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("清空输入")
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if viewModel.enableSpeechInput {
                    Button {
                        viewModel.beginSpeechInputFlow()
                    } label: {
                        Image(systemName: viewModel.isRecordingSpeech ? "waveform.circle.fill" : "mic.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: inputControlHeight, height: inputControlHeight)
                            .contentShape(Circle())
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("语言输入")
                    .tint(.blue)
                    .disabled(viewModel.speechModels.isEmpty)
                }
            }
            .sheet(isPresented: speechSheetBinding) {
                SpeechRecorderView(viewModel: viewModel)
            }
            .alert("语音输入错误", isPresented: speechErrorBinding) {
                Button("好的", role: .cancel) { }
            } message: {
                Text(viewModel.speechErrorMessage ?? "发生未知错误，请稍后重试。")
            }
            .alert("记忆系统需要更新", isPresented: $viewModel.showDimensionMismatchAlert) {
                Button("好的", role: .cancel) { }
            } message: {
                Text(viewModel.dimensionMismatchMessage)
            }
            // MARK: - 公告弹窗
            .sheet(isPresented: $announcementManager.shouldShowAlert) {
                if let announcement = announcementManager.currentAnnouncement {
                    NavigationStack {
                        AnnouncementAlertView(
                            announcement: announcement,
                            onDismiss: {
                                announcementManager.dismissAlert()
                            }
                        )
                    }
                }
            }
            // 启动时检查公告
            .task {
                await announcementManager.checkAnnouncement()
            }
    }

}

// MARK: - 完整错误响应辅助类型

/// 用于包装完整错误内容的 Identifiable 结构
private struct FullErrorContentWrapper: Identifiable {
    let id = UUID()
    let content: String
}

/// 完整错误响应内容视图
private struct FullErrorContentView: View {
    let content: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("完整响应")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

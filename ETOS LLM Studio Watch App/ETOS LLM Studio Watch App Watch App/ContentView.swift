// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio Watch App 主视图文件 (已重构 v2)
//
// 功能特性:
// - 应用的主界面，负责组合聊天列表和输入框
// - 连接 ChatViewModel 来驱动视图
// - 管理 Sheet 和导航
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared

struct ContentView: View {
    
    // MARK: - 状态对象
    
    @StateObject private var viewModel = ChatViewModel()
    @State private var isAtBottom = true
    @State private var showScrollToBottomButton = false
    
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
            if viewModel.enableBackground, let bgImage = viewModel.currentBackgroundImageUIImage {
                // 适应模式时先铺黑底，再居中显示图片
                if viewModel.backgroundContentMode == "fit" {
                    Color.black
                        .edgesIgnoringSafeArea(.all)
                }
                
                Image(uiImage: bgImage)
                    .resizable()
                    .aspectRatio(contentMode: viewModel.backgroundContentMode == "fill" ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .edgesIgnoringSafeArea(.all)
                    .blur(radius: viewModel.backgroundBlur)
                    .opacity(viewModel.backgroundOpacity)
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
        List {
            if viewModel.messages.isEmpty {
                Spacer().frame(maxHeight: .infinity).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            
            let remainingCount = viewModel.allMessagesForSession.count - viewModel.messages.count
            if !viewModel.isHistoryFullyLoaded && remainingCount > 0 {
                let chunk = min(remainingCount, viewModel.historyLoadChunkSize)
                Button(action: {
                    withAnimation {
                        viewModel.loadMoreHistoryChunk()
                    }
                }) {
                    Label("向上加载 \(chunk) 条记录", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.bordered)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
            }

            ForEach(viewModel.messages) { message in
                // 修复: 将复杂内容提取到辅助函数中，避免编译器超时
                messageRow(for: message, proxy: proxy)
            }
            
            inputBubble
                .id("inputBubble")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .onAppear { isAtBottom = true; showScrollToBottomButton = false }
                // 修复: 修正拼写错误
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
            if isAtBottom {
                withAnimation {
                    proxy.scrollTo("inputBubble", anchor: .bottom)
                }
            }
        }
    }
    
    /// 辅助函数，用于构建单个消息行，以简化 chatList 的主体
    private func messageRow(for message: ChatMessage, proxy: ScrollViewProxy) -> some View {
        let isReasoningExpandedBinding = Binding<Bool>(
            get: { viewModel.reasoningExpandedState[message.id, default: false] },
            set: { viewModel.reasoningExpandedState[message.id] = $0 }
        )
        
        let isToolCallsExpandedBinding = Binding<Bool>(
            get: { viewModel.toolCallsExpandedState[message.id, default: false] },
            set: { viewModel.toolCallsExpandedState[message.id] = $0 }
        )
        
        return ChatBubble(
            message: message,
            isReasoningExpanded: isReasoningExpandedBinding,
            isToolCallsExpanded: isToolCallsExpandedBinding,
            enableMarkdown: viewModel.enableMarkdown,
            enableBackground: viewModel.enableBackground,
            enableLiquidGlass: isLiquidGlassEnabled
        )
        .id(message.id)
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
                    onRetry: {
                        viewModel.retryLastMessage()
                    },
                    onDelete: {
                        viewModel.deleteMessage(message)
                    },
                    onBranch: { copyPrompts in
                        _ = viewModel.branchSessionFromMessage(upToMessage: message, copyPrompts: copyPrompts)
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
            withAnimation {
                proxy.scrollTo("inputBubble", anchor: .bottom)
            }
        }
        
        return Button(action: scrollAction) {
            let icon = Image(systemName: "arrow.down.circle")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
            
            if isLiquidGlassEnabled {
                if #available(watchOS 26.0, *) {
                    icon.glassEffect(.clear, in: Circle())
                } else {
                    icon
                }
            } else {
                icon
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
        .transition(.scale.combined(with: .opacity))
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
                        let textField = TextField("输入...", text: $viewModel.userInput)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 0)
                            .padding(.vertical, 0)
                        
                        if #available(watchOS 26.0, *) {
                            textField.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16))
                        } else {
                            textField
                        }

                        let sendButton = Button(action: viewModel.sendMessage) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 38, height: 38)
                        .disabled(!canSend || viewModel.isSendingMessage)
                        
                        if #available(watchOS 26.0, *) {
                            sendButton.glassEffect(.clear, in: Circle())
                        } else {
                            sendButton
                        }
                    }
                    .frame(height: 38)
                } else {
                    HStack(spacing: 12) {
                        TextField("输入...", text: $viewModel.userInput)
                            .textFieldStyle(.plain)

                        Button(action: viewModel.sendMessage) {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .disabled(!canSend || viewModel.isSendingMessage)
                    }
                    .padding(10)
                    .background(viewModel.enableBackground ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
                    .cornerRadius(12)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        
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
                        Label("清空输入", systemImage: "trash")
                    }
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if viewModel.enableSpeechInput {
                    Button {
                        viewModel.beginSpeechInputFlow()
                    } label: {
                        Label("语言输入", systemImage: viewModel.isRecordingSpeech ? "waveform.circle.fill" : "mic.fill")
                    }
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
    }
}

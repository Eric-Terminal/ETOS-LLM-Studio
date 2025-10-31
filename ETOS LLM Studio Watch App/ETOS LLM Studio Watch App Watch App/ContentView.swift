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
    
    // MARK: - 视图主体
    
    var body: some View {
        ZStack {
            // 背景图
            if viewModel.enableBackground, let bgImage = viewModel.currentBackgroundImageUIImage {
                Image(uiImage: bgImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
        case .export(let session):
            ExportView(
                session: session,
                onExport: viewModel.exportSessionViaNetwork
            )
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
                Button(action: {
                    withAnimation {
                        viewModel.messages = viewModel.allMessagesForSession
                        viewModel.isHistoryFullyLoaded = true
                    }
                }) {
                    Label("显示剩余 \(remainingCount) 条记录", systemImage: "arrow.up.circle")
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
                .buttonStyle(.plain)
                .padding(8)
                .glassEffect(in: Circle())
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
            enableLiquidGlass: viewModel.enableLiquidGlass
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
        Button(action: {
            withAnimation {
                proxy.scrollTo("inputBubble", anchor: .bottom)
            }
        }) {
            Image(systemName: "arrow.down.circle.fill")
                .glassEffect(.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
        .transition(.scale.combined(with: .opacity))
    }
    
    private var inputBubble: some View {
        let coreBubble = Group {
            if viewModel.enableLiquidGlass {
                HStack(spacing: 10) {
                    TextField("输入...", text: $viewModel.userInput)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 0)
                        .padding(.vertical, 0)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16))

                    Button(action: viewModel.sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 38, height: 38)
                    .glassEffect(.clear, in: Circle())
                    .disabled(viewModel.userInput.isEmpty || viewModel.isSendingMessage)
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
                    .disabled(viewModel.userInput.isEmpty || viewModel.isSendingMessage)
                }
                .padding(10)
                .background(viewModel.enableBackground ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
                .cornerRadius(12)
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
                if !viewModel.userInput.isEmpty {
                    Button(role: .destructive) {
                        viewModel.clearUserInput()
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

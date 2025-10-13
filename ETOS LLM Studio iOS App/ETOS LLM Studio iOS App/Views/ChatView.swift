
// ============================================================================
// ChatView.swift
// ============================================================================
// ETOS LLM Studio iOS App 聊天主视图
//
// 功能特性:
// - 应用的主聊天界面，负责组合聊天列表和输入框
// - 连接 ChatViewModel 来驱动视图
// - 管理 Sheet 和导航
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared

struct ChatView: View {
    
    // MARK: - 状态对象
    
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var isAtBottom = true
    @State private var showScrollToBottomButton = false
    @State private var showMultilineInput = false
    
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
            
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        chatList(proxy: proxy)

                        if showScrollToBottomButton {
                            scrollToBottomButton(proxy: proxy)
                        }
                    }
                }
                inputBar
            }
            .navigationTitle(viewModel.currentSession?.name ?? "新对话")
            .sheet(item: $viewModel.activeSheet) { item in
                sheetView(for: item)
            }
            .sheet(isPresented: $showMultilineInput) {
                MultilineInputView(userInput: $viewModel.userInput)
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
        switch item {
        case .editMessage:
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
                MessageRowView(message: message, viewModel: viewModel, proxy: proxy)
            }
            
            Spacer()
                .id("bottomSpacer")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .onAppear { isAtBottom = true; showScrollToBottomButton = false }
                .onDisappear { isAtBottom = false; showScrollToBottomButton = true }
        }
        .listStyle(.plain)
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onAppear {
            UITableView.appearance().backgroundColor = .clear
        }
        .onDisappear {
            UITableView.appearance().backgroundColor = .systemGroupedBackground
        }
        .toolbar {

        }
        .onChange(of: viewModel.messages.count) {
            if isAtBottom {
                withAnimation {
                    proxy.scrollTo("bottomSpacer", anchor: .bottom)
                }
            }
        }
    }
    
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            withAnimation {
                proxy.scrollTo("bottomSpacer", anchor: .bottom)
            }
        }) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.largeTitle)
                .padding()
        }
        .buttonStyle(.plain)
    }
    
    private var inputBar: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("输入...", text: $viewModel.userInput)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(uiColor: .systemGray6))
                .clipShape(Capsule())

            Button(action: { showMultilineInput = true }) {
                Image(systemName: "plus.viewfinder")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Button(action: viewModel.sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.userInput.isEmpty || viewModel.isSendingMessage)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }
}

private struct MultilineInputView: View {
    @Binding var userInput: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            TextEditor(text: $userInput)
                .padding()
                .navigationTitle("编辑消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

private struct MessageRowView: View {
    let message: ChatMessage
    @ObservedObject var viewModel: ChatViewModel
    let proxy: ScrollViewProxy
    
    @State private var showInfoAlert = false
    
    var body: some View {
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
        .contextMenu {
            Button {
                viewModel.messageToEdit = message
                viewModel.activeSheet = .editMessage
            } label: {
                Label("编辑消息", systemImage: "pencil")
            }

            if viewModel.canRetry(message: message) {
                Button {
                    viewModel.retryLastMessage()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
            }

            Button {
                showInfoAlert = true
            } label: {
                Label("信息", systemImage: "info.circle")
            }

            Divider()

            Button(role: .destructive) {
                viewModel.deleteMessage(message)
            } label: {
                Label("删除消息", systemImage: "trash.fill")
            }
        }
        .alert("信息", isPresented: $showInfoAlert) {
            Button("好的") { }
        } message: {
            if let index = viewModel.allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
                Text("消息 ID: \(message.id.uuidString)\n会话位置: 第 \(index + 1) / \(viewModel.allMessagesForSession.count) 条")
            }
        }
    }
}

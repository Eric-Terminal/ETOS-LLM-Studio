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
import MarkdownUI

struct ContentView: View {
    
    // MARK: - 状态对象
    
    @StateObject private var viewModel = ChatViewModel()
    
    // MARK: - 视图主体
    
    var body: some View {
        ZStack {
            // 背景图
            if viewModel.enableBackground {
                Image(viewModel.currentBackgroundImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .edgesIgnoringSafeArea(.all)
                    .blur(radius: viewModel.backgroundBlur)
                    .opacity(viewModel.backgroundOpacity)
            }
            
            // 主导航
            NavigationStack {
                ScrollViewReader { proxy in
                    List {
                        // 懒加载按钮
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
                        
                        // 用于将内容推到底部的占位符
                        Spacer().listRowBackground(Color.clear)

                        // 消息列表
                        ForEach($viewModel.messages) { $message in
                            ChatBubble(message: $message, 
                                       enableMarkdown: viewModel.enableMarkdown, 
                                       enableBackground: viewModel.enableBackground,
                                       enableLiquidGlass: viewModel.enableLiquidGlass) // Pass down the toggle
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
                                                viewModel.messageToDelete = message
                                                viewModel.showDeleteMessageConfirm = true
                                            },
                                            messageIndex: viewModel.allMessagesForSession.firstIndex { $0.id == message.id },
                                            totalMessages: viewModel.allMessagesForSession.count
                                        )
                                    } label: {
                                        Label("更多", systemImage: "ellipsis.circle.fill")
                                    }
                                    .tint(.gray)
                                }
                        }
                        
                        // 输入区域
                        inputBubble
                            .id("inputBubble")
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .background(Color.clear)
                    .toolbar { // 使用标准的 Toolbar
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
                        withAnimation {
                            proxy.scrollTo("inputBubble", anchor: .bottom)
                        }
                    }
                    .confirmationDialog("确认删除", isPresented: $viewModel.showDeleteMessageConfirm, titleVisibility: .visible) {
                        Button("删除消息", role: .destructive) {
                            if let message = viewModel.messageToDelete, let index = viewModel.messages.firstIndex(where: { $0.id == message.id }) {
                                viewModel.deleteMessage(at: IndexSet(integer: index))
                            }
                            viewModel.messageToDelete = nil
                        }
                        Button("取消", role: .cancel) {
                            viewModel.messageToDelete = nil
                        }
                    } message: {
                        Text("您确定要删除这条消息吗？此操作无法撤销。")
                    }
                }
                .sheet(item: $viewModel.activeSheet) { item in
                    // Sheet 视图处理器
                    switch item {
                    case .editMessage:
                        if let messageToEdit = viewModel.messageToEdit,
                           let messageIndex = viewModel.allMessagesForSession.firstIndex(where: { $0.id == messageToEdit.id }) {
                            
                            let messageBinding = $viewModel.allMessagesForSession[messageIndex]
                            
                            EditMessageView(message: messageBinding, onSave: { updatedMessage in
                                viewModel.saveMessagesForCurrentSession()
                                viewModel.updateDisplayedMessages()
                            })
                        }
                    case .settings:
                        SettingsView(
                            selectedModel: $viewModel.selectedModel,
                            allModels: viewModel.modelConfigs,
                            sessions: $viewModel.chatSessions,
                            currentSession: $viewModel.currentSession,
                            aiTemperature: $viewModel.aiTemperature,
                            aiTopP: $viewModel.aiTopP,
                            systemPrompt: $viewModel.systemPrompt,
                            maxChatHistory: $viewModel.maxChatHistory,
                            lazyLoadMessageCount: $viewModel.lazyLoadMessageCount,
                            enableStreaming: $viewModel.enableStreaming,
                            enableMarkdown: $viewModel.enableMarkdown,
                            enableBackground: $viewModel.enableBackground,
                            backgroundBlur: $viewModel.backgroundBlur,
                            backgroundOpacity: $viewModel.backgroundOpacity,
                            allBackgrounds: viewModel.backgroundImages,
                            currentBackgroundImage: $viewModel.currentBackgroundImage,
                            enableAutoRotateBackground: $viewModel.enableAutoRotateBackground,
                            enableLiquidGlass: $viewModel.enableLiquidGlass,
                            deleteAction: viewModel.deleteSession,
                            branchAction: viewModel.branchSession,
                            exportAction: { session in
                                viewModel.activeSheet = .export(session)
                            },
                            deleteLastMessageAction: viewModel.deleteLastMessage,
                            saveSessionsAction: viewModel.forceSaveSessions
                        )
                    case .export(let session):
                        ExportView(
                            session: session,
                            onExport: viewModel.exportSessionViaNetwork
                        )
                    }
                }
            }
            .onChange(of: viewModel.selectedModel.name) {
                viewModel.selectedModelName = viewModel.selectedModel.name
            }
            .onChange(of: viewModel.activeSheet) {
                if viewModel.activeSheet == nil {
                    viewModel.saveCurrentSessionDetails()
                    if let session = viewModel.currentSession {
                        viewModel.loadAndDisplayMessages(for: session)
                    } else {
                        viewModel.allMessagesForSession = []
                        viewModel.updateDisplayedMessages()
                    }
                }
            }
        }
    }
    
    // MARK: - 视图组件
    
    private var inputBubble: some View {
        let content = HStack(spacing: 12) {
            TextField("输入...", text: $viewModel.userInput)
                .textFieldStyle(.plain)
            
            Button(action: viewModel.sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(viewModel.userInput.isEmpty || (viewModel.allMessagesForSession.last?.isLoading ?? false))
        }
        .padding(10)

        return AnyView(
            Group {
                if viewModel.enableLiquidGlass {
                    content.glassEffect(.clear)
                } else {
                    content.background(viewModel.enableBackground ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial))
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        )
    }
}

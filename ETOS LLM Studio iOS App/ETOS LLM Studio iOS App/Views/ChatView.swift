// ============================================================================
// ChatView.swift
// ============================================================================
// 聊天主界面 (iOS)
// - 显示消息列表、底部固定输入框
// - 支持长按消息调出操作菜单
// - 使用系统风格的留白与材质，贴合 Apple Design
// ============================================================================

import SwiftUI
import MarkdownUI
import Shared
import UIKit

struct ChatView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var showScrollToBottom = false
    @State private var editingMessage: ChatMessage?
    @State private var editingContent: String = ""
    @State private var messageInfo: MessageInfoPayload?
    @FocusState private var composerFocused: Bool
    
    var body: some View {
        NavigationStack {
            ZStack {
                backgroundLayer
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .trailing, spacing: 12, pinnedViews: []) {
                            modelSelectorBar
                            historyBanner
                            
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
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 120)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            composerFocused = false
                        }
                    )
                    .onChange(of: viewModel.messages.count) { _ in
                        guard !viewModel.messages.isEmpty else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(viewModel.messages.last?.id, anchor: .bottom)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showScrollToBottom {
                            Button {
                                if let last = viewModel.messages.last {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        proxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 22, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.tint)
                                    .padding(10)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .padding(.trailing, 20)
                            .padding(.bottom, 140)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel("滚动到底部")
                        }
                    }
                }
            }
            .navigationTitle(viewModel.currentSession?.name ?? "新的对话")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            viewModel.createNewSession()
                        } label: {
                            Label("开始新会话", systemImage: "plus.message")
                        }
                        
                        Button {
                            composerFocused = true
                        } label: {
                            Label("快速输入", systemImage: "keyboard")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("快速操作")
                }
            }
            .safeAreaInset(edge: .bottom) {
                MessageComposerView(
                    text: $viewModel.userInput,
                    isSending: viewModel.isSendingMessage,
                    sendAction: {
                        viewModel.sendMessage()
                    },
                    focus: $composerFocused
                )
                .background(.ultraThinMaterial)
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
        }
    }
    
    // MARK: - Background
    
    private var backgroundLayer: some View {
        Group {
            if viewModel.enableBackground,
               let image = viewModel.currentBackgroundImageUIImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .blur(radius: viewModel.backgroundBlur)
                    .opacity(viewModel.backgroundOpacity)
                    .overlay(Color.black.opacity(0.1))
            } else {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            }
        }
    }
    
// MARK: - Components

    @ViewBuilder
    private var historyBanner: some View {
        let remaining = viewModel.allMessagesForSession.count - viewModel.messages.count
        if remaining > 0 && !viewModel.isHistoryFullyLoaded {
            Button {
                withAnimation {
                    viewModel.loadEntireHistory()
                }
            } label: {
                Label("显示剩余 \(remaining) 条记录", systemImage: "arrow.uturn.left.circle")
            }
            .font(.footnote)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var modelSelectorBar: some View {
        if !viewModel.activatedModels.isEmpty {
            let selection = Binding<String?>(
                get: { viewModel.selectedModel?.id },
                set: { newValue in
                    guard let id = newValue,
                          let target = viewModel.activatedModels.first(where: { $0.id == id }) else { return }
                    viewModel.setSelectedModel(target)
                }
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("当前模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("选择模型", selection: selection) {
                    Text("选择模型")
                        .tag(Optional<String>.none)
                    ForEach(viewModel.activatedModels, id: \.id) { runnable in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(runnable.model.displayName)
                            Text(runnable.provider.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional<String>.some(runnable.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    Color(uiColor: .secondarySystemBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
    }
    
    @ViewBuilder
    private func contextMenu(for message: ChatMessage) -> some View {
        Button {
            editingMessage = message
            editingContent = message.content
        } label: {
            Label("编辑", systemImage: "pencil")
        }
        
        if viewModel.canRetry(message: message) {
            Button {
                viewModel.retryLastMessage()
            } label: {
                Label("重试响应", systemImage: "arrow.clockwise")
            }
        }
        
        Button(role: .destructive) {
            viewModel.deleteMessage(message)
        } label: {
            Label("删除消息", systemImage: "trash")
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

// MARK: - Composer

private struct MessageComposerView: View {
    @Binding var text: String
    let isSending: Bool
    let sendAction: () -> Void
    let focus: FocusState<Bool>.Binding
    
    var body: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .center, spacing: 12) {
                TextField("输入...", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused(focus)
                
                Button {
                    sendAction()
                } label: {
                    Image(systemName: isSending ? "paperplane.circle.fill" : "paperplane.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .help("发送当前消息")
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(.thinMaterial)
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
                        Text("第 \(payload.displayIndex) / \(payload.totalCount) 条")
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
        }
    }
}

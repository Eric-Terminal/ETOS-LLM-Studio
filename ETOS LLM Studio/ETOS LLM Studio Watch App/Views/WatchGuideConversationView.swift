// ============================================================================
// WatchGuideConversationView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 使用独立对话窗口，保留来源设置页并复用同一段可恢复对话。
// ============================================================================

import SwiftUI
import ETOSCore

/// watchOS 同样只让消息片段订阅流式状态，输入框和模型列表不参与逐批重绘。
private struct WatchGuideStreamingObservedContent<Content: View>: View {
    @ObservedObject var state: GuideStreamingState
    private let content: () -> Content

    init(state: GuideStreamingState, @ViewBuilder content: @escaping () -> Content) {
        self.state = state
        self.content = content
    }

    var body: some View {
        content()
    }
}

/// watchOS 只刷新正在增长的回答，避免 List 在每批流式文本到达时重建历史 Markdown。
private struct WatchGuideMessageContent: View, Equatable {
    let message: GuideConversationMessage
    let displayedContent: String
    let isStreaming: Bool
    let tools: GuideMessageTools
    let isToolActive: Bool
    let awaitingToolCallID: String?
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.displayedContent == rhs.displayedContent
            && lhs.isStreaming == rhs.isStreaming
            && lhs.tools == rhs.tools
            && lhs.isToolActive == rhs.isToolActive
            && lhs.awaitingToolCallID == rhs.awaitingToolCallID
            && lhs.enableMarkdown == rhs.enableMarkdown
            && lhs.enableAdvancedRenderer == rhs.enableAdvancedRenderer
    }

    @ViewBuilder
    var body: some View {
        if message.role == .assistant {
            VStack(alignment: .leading) {
                if !displayedContent.isEmpty {
                    ETAdvancedMarkdownRenderer(
                        content: displayedContent,
                        preparedContent: nil,
                        enableMarkdown: enableMarkdown,
                        isOutgoing: false,
                        enableAdvancedRenderer: enableAdvancedRenderer,
                        enableMathRendering: enableAdvancedRenderer,
                        customTextColor: nil,
                        isStreaming: isStreaming
                    )
                }
                GuideToolStatusLine(tools, active: isToolActive, awaiting: awaitingToolCallID)
            }
        } else {
            Text(displayedContent)
                .font(.footnote)
                .foregroundStyle(message.role == .error ? .red : .primary)
        }
    }
}

struct WatchGuideConversationView: View {
    @ObservedObject var controller: GuideConversationController
    @ObservedObject private var router: GuideModelRouter
    @StateObject private var presentation: GuideMessagePresentation
    @ObservedObject private var appConfig = AppConfigStore.shared

    @State private var input = ""
    @State private var editingMessage: GuideConversationMessage?
    private let close: () -> Void

    init(controller: GuideConversationController, close: @escaping () -> Void) {
        self.controller = controller
        self.close = close
        _presentation = StateObject(wrappedValue: GuideMessagePresentation(controller: controller))
        _router = ObservedObject(wrappedValue: controller.router)
    }

    var body: some View {
        List {
            // 输入操作始终位于列表开头，不随历史长度或可用模型数量向下移动。
            Section(NSLocalizedString("问题", value: "Question", comment: "手表向导问题输入分组")) {
                TextField(NSLocalizedString("问问软件怎么用…", value: "Ask how to use the app…", comment: "手表向导输入框占位"), text: $input)
                    .accessibilityIdentifier("watchGuideInput")
                if controller.isResponding {
                    Button(NSLocalizedString("停止生成", value: "Stop Generating", comment: "手表停止向导生成按钮"), role: .destructive) {
                        controller.cancel()
                    }
                } else {
                    Button(NSLocalizedString("发送", value: "Send", comment: "手表发送向导问题按钮")) {
                        send()
                    }
                    .accessibilityIdentifier("watchGuideSend")
                    .disabled(
                        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || controller.isRestoringHistory
                            || controller.pendingProposal != nil
                            || controller.isAwaitingToolContinuation
                    )
                }
            }

            Section(NSLocalizedString("回答模型", value: "Answer Model", comment: "手表向导模型线路分组")) {
                NavigationLink {
                    WatchGuideModelRouteSelectionView(router: router, preservesSourceContext: true)
                } label: {
                    MarqueeTitleSubtitleSelectionRow(
                        title: selectedModelTitle,
                        subtitle: router.route == .userModel ? router.selectedUserModel?.provider.name : nil,
                        isSelected: false,
                        subtitleUIFont: .preferredFont(forTextStyle: .caption2)
                    )
                }
                .accessibilityLabel(NSLocalizedString("选择向导模型", value: "Choose Guide Model", comment: "向导线路菜单辅助标签"))
                .accessibilityIdentifier("watchGuideModelPicker")
            }

            if controller.isRestoringHistory {
                ProgressView()
            } else if controller.messages.isEmpty {
                Section {
                    Label(NSLocalizedString("使用助手", value: "App Guide", comment: "助手空状态标题"), systemImage: "questionmark.bubble")
                    Text(NSLocalizedString("可以问我怎么配置模型，或让我带你找到需要的设置。", value: "Ask how to set up a model or find a setting.", comment: "助手空状态说明"))
                        .font(.footnote).foregroundStyle(.secondary)
                    GuideSuggestedQuestions(controller: controller)
                }
            } else {
                Section(NSLocalizedString("对话", value: "Conversation", comment: "手表向导消息分组")) {
                    WatchGuideStreamingObservedContent(state: controller.streamingState) {
                        ForEach(controller.messages) { message in
                            messageRow(message)
                        }
                        if presentation.isWaitingForReply(controller) {
                            ProgressView(NSLocalizedString("正在回答…", value: "Answering…", comment: "手表向导回答状态"))
                        }
                    }
                }
            }

            if let proposal = controller.pendingProposal {
                Section(NSLocalizedString("等待确认", value: "Awaiting Confirmation", comment: "手表向导修改预览分组")) {
                    Text(proposal.summary)
                    NavigationLink {
                        WatchGuideProposalConfirmationView(
                            controller: controller,
                            proposal: proposal
                        )
                    } label: {
                        Label(NSLocalizedString("查看并确认", value: "Review and Confirm", comment: "手表查看向导修改按钮"), systemImage: "checkmark.circle")
                    }
                }
            }

            if controller.isAwaitingToolContinuation {
                Section(NSLocalizedString("需要继续查找吗？", value: "Keep looking?", comment: "手表向导连续工具调用确认标题")) {
                    Text(NSLocalizedString("这个问题涉及的设置稍微多一点，需要我继续往下排查吗？", value: "There are a few more settings to check. Would you like me to keep looking?", comment: "手表向导连续工具调用确认说明"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("继续查找", value: "Keep Looking", comment: "手表允许向导继续调用工具")) {
                        controller.continueToolCalls()
                    }
                    Button(NSLocalizedString("不用了", value: "No Thanks", comment: "手表停止向导继续调用工具"), role: .cancel) {
                        controller.finishToolCalls()
                    }
                }
            }

            if controller.lastError != nil {
                Section(NSLocalizedString("恢复", value: "Restore", comment: "手表向导错误恢复分组")) {
                    Button(NSLocalizedString("重试", value: "Retry", comment: "手表向导重试按钮")) {
                        controller.retryLastResponse()
                    }
                    if controller.canRetryWithBuiltIn {
                        Button(NSLocalizedString("使用内置向导重试", value: "Retry with Built-in Guide", comment: "手表切换内置向导重试按钮")) {
                            controller.retryWithBuiltIn()
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("使用助手", value: "App Guide", comment: "手表向导标题"))
        .modifier(GuideConversationFallbackContext())
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(NSLocalizedString("关闭", value: "Close", comment: "关闭手表向导窗口"))
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if controller.canUndo {
                    GuideUndoButton(controller: controller)
                }
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(NSLocalizedString("清空向导上下文", value: "Clear Guide Context", comment: "手表清空向导按钮"))
            }
        }
        .sheet(item: $editingMessage) { message in
            WatchGuideMessageEditorView(controller: controller, message: message)
        }
    }

    @ViewBuilder
    private func messageRow(_ message: GuideConversationMessage) -> some View {
        let isStreaming = controller.streamingMessageID == message.id
        let tools = presentation.tools[message.id] ?? GuideMessageTools()
        let active = controller.isResponding && controller.messages.last?.id == message.id
        let content = isStreaming ? controller.streamingContent : message.content
        let row = WatchGuideMessageContent(
            message: message,
            displayedContent: content,
            isStreaming: isStreaming,
            tools: tools,
            isToolActive: active,
            awaitingToolCallID: controller.pendingProposal?.toolCallID,
            enableMarkdown: appConfig.enableMarkdown,
            enableAdvancedRenderer: appConfig.enableAdvancedRenderer
        )
        .equatable()

        if !content.isEmpty || tools.awaits(controller.pendingProposal?.toolCallID) || (active && tools.hasPendingRead) {
            row.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if controller.canRetryMessage(message.id) {
                    Button {
                        controller.retryResponse(for: message.id)
                    } label: {
                        Label(NSLocalizedString("重试", value: "Retry", comment: "手表重试向导回答"), systemImage: "arrow.clockwise")
                    }
                }
                if controller.canEditMessage(message.id) {
                    Button {
                        editingMessage = message
                    } label: {
                        Label(NSLocalizedString("编辑", value: "Edit", comment: "手表编辑向导消息"), systemImage: "pencil")
                    }
                }
            }
        }
        GuideDestinationButtons(tools.destinations)
    }

    private var selectedModelTitle: String {
        guard router.route == .userModel else {
            return NSLocalizedString("内置免费向导", value: "Built-in Free Guide", comment: "内置向导线路名称")
        }
        return router.selectedUserModel?.model.displayName
            ?? NSLocalizedString("所选向导模型当前不可用。", value: "The selected guide model is currently unavailable.", comment: "向导所选模型失效提示")
    }

    private func send() {
        let content = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !controller.isRestoringHistory,
              !controller.isResponding, controller.pendingProposal == nil,
              !controller.isAwaitingToolContinuation else { return }
        input = ""
        controller.send(content)
    }
}

private struct WatchGuideMessageEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GuideConversationController
    let message: GuideConversationMessage

    @State private var content: String

    init(controller: GuideConversationController, message: GuideConversationMessage) {
        self.controller = controller
        self.message = message
        _content = State(initialValue: message.content)
    }

    var body: some View {
        NavigationStack {
            List {
                Section(NSLocalizedString("消息内容", value: "Message content", comment: "手表向导消息编辑内容")) {
                    TextField(NSLocalizedString("消息内容", value: "Message content", comment: "手表向导消息编辑输入框"), text: $content)
                }
                Section {
                    Button(NSLocalizedString("保存", value: "Save", comment: "手表保存向导消息编辑")) {
                        controller.editUserMessage(message.id, content: content)
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(NSLocalizedString("编辑消息", value: "Edit message", comment: "手表编辑向导消息标题"))
        }
    }
}

private struct WatchGuideProposalConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GuideConversationController
    let proposal: GuideActionProposal

    var body: some View {
        List {
            Section {
                Text(proposal.summary)
            }
            Section(NSLocalizedString("修改内容", value: "Changes", comment: "手表向导修改详情分组")) {
                ForEach(proposal.mutations) { mutation in
                    VStack(alignment: .leading) {
                        Text(mutation.label)
                        GuideMutationValueView(mutation: mutation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }
            Section {
                Button(NSLocalizedString("确认应用", value: "Apply", comment: "手表确认向导修改按钮")) {
                    controller.confirmPendingProposal()
                    dismiss()
                }
                Button(NSLocalizedString("不应用", value: "Don’t Apply", comment: "手表拒绝向导修改按钮"), role: .cancel) {
                    controller.rejectPendingProposal()
                    dismiss()
                }
            }
        }
        .navigationTitle(NSLocalizedString("确认修改", value: "Confirm Changes", comment: "手表向导确认修改标题"))
    }
}

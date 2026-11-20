// ============================================================================
// GuideConversationViews.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 向导的紧凑面板与完整会话共用同一内容视图和本机恢复的对话。
// ============================================================================

import SwiftUI
import ETOSCore
import UIKit

extension Notification.Name {
    static let requestGuideModelManagement = Notification.Name("requestGuideModelManagement")
}

private enum GuideMessageListAnchor: Hashable {
    case bottom
}

/// 把高频流式通知限制在消息列表，避免输入框跟随每批正文重新进入 TextInputUI 更新链路。
private struct GuideStreamingObservedContent<Content: View>: View {
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

/// 每条消息独立比较渲染输入，流式增量只允许刷新当前回答，历史 Markdown 不参与重绘。
private struct GuideMessageBubble: View, Equatable {
    let message: GuideConversationMessage
    let displayedContent: String
    let compact: Bool
    let isStreaming: Bool
    let tools: GuideMessageTools
    let isToolActive: Bool
    let awaitingToolCallID: String?
    let isLatestError: Bool
    let canRetryWithBuiltIn: Bool
    let canManageModel: Bool
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool
    let onOpenActions: (GuideConversationMessage) -> Void
    let onRetry: () -> Void
    let onRetryWithBuiltIn: () -> Void
    let onManageModel: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.displayedContent == rhs.displayedContent
            && lhs.compact == rhs.compact
            && lhs.isStreaming == rhs.isStreaming
            && lhs.tools == rhs.tools
            && lhs.isToolActive == rhs.isToolActive
            && lhs.awaitingToolCallID == rhs.awaitingToolCallID
            && lhs.isLatestError == rhs.isLatestError
            && lhs.canRetryWithBuiltIn == rhs.canRetryWithBuiltIn
            && lhs.canManageModel == rhs.canManageModel
            && lhs.enableMarkdown == rhs.enableMarkdown
            && lhs.enableAdvancedRenderer == rhs.enableAdvancedRenderer
    }

    var body: some View {
        if !displayedContent.isEmpty || tools.isVisible(active: isToolActive, awaiting: awaitingToolCallID) {
            let isUser = message.role == .user
            let shape = TelegramBubbleShape(isOutgoing: isUser)
            HStack {
                if isUser { Spacer(minLength: compact ? 28 : 64) }
                VStack(alignment: .leading, spacing: 6) {
                    if message.role == .tool {
                        Label(NSLocalizedString("页面操作", value: "Page Actions", comment: "向导工具消息标签"), systemImage: "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if !displayedContent.isEmpty {
                        messageContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GuideToolStatusLine(tools, active: isToolActive, awaiting: awaitingToolCallID)
                    GuideDestinationButtons(tools.destinations)
                    if isLatestError {
                        errorRecoveryActions
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(bubbleBackground, in: shape)
                .contentShape(shape)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            var actionMessage = message
                            actionMessage.content = displayedContent
                            onOpenActions(actionMessage)
                        }
                )
                if !isUser { Spacer(minLength: compact ? 20 : 56) }
            }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.role == .assistant {
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
        } else {
            Text(displayedContent)
                .font(.body)
                .foregroundStyle(message.role == .error ? .red : .primary)
        }
    }

    private var bubbleBackground: some ShapeStyle {
        switch message.role {
        case .user:
            return AnyShapeStyle(Color.accentColor.opacity(0.16))
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.12))
        case .tool:
            return AnyShapeStyle(Color.green.opacity(0.12))
        case .assistant:
            return AnyShapeStyle(.thinMaterial)
        }
    }

    private var errorRecoveryActions: some View {
        HStack(spacing: 8) {
            Button(action: onRetry) {
                Label(NSLocalizedString("重试", value: "Retry", comment: "向导重试按钮"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .font(.callout.weight(.semibold))

            if canRetryWithBuiltIn || canManageModel {
                Menu {
                    if canRetryWithBuiltIn {
                        Button(action: onRetryWithBuiltIn) {
                            Label(
                                NSLocalizedString("使用内置向导重试", value: "Retry with Built-in Guide", comment: "切换内置向导重试按钮"),
                                systemImage: "sparkles"
                            )
                        }
                    }
                    if canManageModel {
                        Button(action: onManageModel) {
                            Label(
                                NSLocalizedString("检查模型配置", value: "Review Model Configuration", comment: "向导错误后打开模型管理按钮"),
                                systemImage: "slider.horizontal.3"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(NSLocalizedString("更多", value: "More", comment: "向导错误恢复更多操作"))
            }
            Spacer()
        }
        .padding(.top, 2)
    }
}

struct GuideConversationView: View {
    @ObservedObject var controller: GuideConversationController
    @ObservedObject private var router: GuideModelRouter
    @StateObject private var presentation: GuideMessagePresentation
    @ObservedObject private var appConfig = AppConfigStore.shared
    let compact: Bool

    @State private var input = ""
    @State private var routeRevision = 0
    @State private var followsLatestMessage = true
    @State private var messageActionMessage: GuideConversationMessage?
    @State private var editingMessage: GuideConversationMessage?
    @FocusState private var inputFocused: Bool

    init(controller: GuideConversationController, compact: Bool) {
        self.controller = controller
        self.compact = compact
        _presentation = StateObject(wrappedValue: GuideMessagePresentation(controller: controller))
        _router = ObservedObject(wrappedValue: controller.router)
    }

    var body: some View {
        VStack(spacing: 0) {
            modelBar
            Divider()
            messageList
                .frame(maxHeight: .infinity)
            Divider()
            if let proposal = controller.pendingProposal {
                proposalPreview(proposal)
            }
            if controller.isAwaitingToolContinuation {
                toolContinuationPrompt
            }
            composer
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .sheet(item: $messageActionMessage) { message in
            GuideMessageActionSheet(
                message: message,
                canEdit: controller.canEditMessage(message.id),
                canRetry: controller.canRetryMessage(message.id),
                onEdit: {
                    messageActionMessage = nil
                    DispatchQueue.main.async {
                        editingMessage = message
                    }
                },
                onRetry: {
                    messageActionMessage = nil
                    controller.retryResponse(for: message.id)
                }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $editingMessage) { message in
            NavigationStack {
                EditMessageView(
                    message: ChatMessage(id: message.id, role: .user, content: message.content)
                ) { updatedMessage in
                    controller.editUserMessage(message.id, content: updatedMessage.content)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var messageList: some View {
        GuideStreamingObservedContent(state: controller.streamingState) {
            ScrollViewReader { proxy in
                ScrollView {
                    // 普通栈可避免可选文本固有高度与
                    // LazyVStack 可见区放置互相触发，在浮窗宽高约束下形成 TextKit 2 布局反馈环。
                    VStack(spacing: 10) {
                        if controller.messages.isEmpty {
                            emptyState
                        }
                        ForEach(controller.messages) { message in
                            let isStreaming = controller.streamingMessageID == message.id
                            GuideMessageBubble(
                                message: message,
                                displayedContent: isStreaming ? controller.streamingContent : message.content,
                                compact: compact,
                                isStreaming: isStreaming,
                                tools: presentation.tools[message.id] ?? GuideMessageTools(),
                                isToolActive: controller.isResponding && controller.messages.last?.id == message.id,
                                awaitingToolCallID: controller.pendingProposal?.toolCallID,
                                isLatestError: isLatestError(message),
                                canRetryWithBuiltIn: controller.canRetryWithBuiltIn,
                                canManageModel: router.route == .userModel,
                                enableMarkdown: appConfig.enableMarkdown,
                                enableAdvancedRenderer: appConfig.enableAdvancedRenderer,
                                onOpenActions: { messageActionMessage = $0 },
                                onRetry: { controller.retryLastResponse() },
                                onRetryWithBuiltIn: {
                                    controller.retryWithBuiltIn()
                                    routeRevision &+= 1
                                },
                                onManageModel: {
                                    GuideNavigationCoordinator.shared.request(.providerManagement)
                                }
                            )
                            .equatable()
                            .id(message.id)
                        }
                        if controller.isRestoringHistory || presentation.isWaitingForReply(controller) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(GuideMessageListAnchor.bottom)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            // 用户开始查看上文后，流式更新不能继续把视口抢回底部。
                            followsLatestMessage = false
                        }
                )
                .onChange(of: controller.messages.count) { _, count in
                    if count == 0 || controller.messages.last?.role == .user {
                        followsLatestMessage = true
                    }
                    guard followsLatestMessage else { return }
                    proxy.scrollTo(GuideMessageListAnchor.bottom, anchor: .bottom)
                }
                .onChange(of: controller.streamingState.revision) { _, _ in
                    guard followsLatestMessage else { return }
                    proxy.scrollTo(GuideMessageListAnchor.bottom, anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo(GuideMessageListAnchor.bottom, anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatestMessage && !controller.messages.isEmpty {
                        Button {
                            followsLatestMessage = true
                            proxy.scrollTo(GuideMessageListAnchor.bottom, anchor: .bottom)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .padding()
                        .accessibilityLabel(NSLocalizedString("回到最新消息", value: "Jump to Latest Message", comment: "向导回到底部按钮"))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(.title2)
                .foregroundStyle(.blue)
            Text(NSLocalizedString("使用助手", value: "App Guide", comment: "向导空状态标题"))
                .font(.headline)
            Text(NSLocalizedString("可以问我怎么配置模型，或让我带你找到需要的设置。", value: "Ask how to set up a model or find a setting.", comment: "助手空状态说明"))
                .font(.footnote).foregroundStyle(.secondary)
            GuideSuggestedQuestions(controller: controller)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isLatestError(_ message: GuideConversationMessage) -> Bool {
        message.role == .error
            && controller.lastError != nil
            && controller.lastErrorMessageID == message.id
    }

    private func proposalPreview(_ proposal: GuideActionProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(NSLocalizedString("等待确认", value: "Awaiting Confirmation", comment: "向导修改预览状态"), systemImage: "slider.horizontal.3")
                .font(.headline)
            Text(proposal.summary)
                .font(.subheadline)
            ForEach(proposal.mutations) { mutation in
                HStack(alignment: .firstTextBaseline) {
                    Text(mutation.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    GuideMutationValueView(mutation: mutation)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .font(.caption)
            }
            HStack {
                Button(NSLocalizedString("不应用", value: "Don’t Apply", comment: "拒绝向导修改按钮"), role: .cancel) {
                    controller.rejectPendingProposal()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(NSLocalizedString("确认应用", value: "Apply", comment: "确认向导修改按钮")) {
                    controller.confirmPendingProposal()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
    }

    private var toolContinuationPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                NSLocalizedString("需要继续查找吗？", value: "Keep looking?", comment: "向导连续工具调用确认标题"),
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
            )
            .font(.headline)
            Text(NSLocalizedString("这个问题涉及的设置稍微多一点，需要我继续往下排查吗？", value: "There are a few more settings to check. Would you like me to keep looking?", comment: "向导连续工具调用确认说明"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button(NSLocalizedString("不用了", value: "No Thanks", comment: "停止向导继续调用工具"), role: .cancel) {
                    controller.finishToolCalls()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(NSLocalizedString("继续查找", value: "Keep Looking", comment: "允许向导继续调用工具")) {
                    controller.continueToolCalls()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
    }

    private var modelBar: some View {
        HStack {
            Text(NSLocalizedString("回答使用的模型", value: "Model Used for Answers", comment: "向导当前回答模型标签"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            routeMenu
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var routeMenu: some View {
        Menu {
            Button {
                router.useBuiltIn()
                routeRevision &+= 1
            } label: {
                routeMenuLabel(
                    NSLocalizedString("内置免费向导", value: "Built-in Free Guide", comment: "内置向导线路名称"),
                    selected: router.route == .builtIn
                )
            }
            Section(NSLocalizedString("使用我的模型", value: "Use My Model", comment: "用户向导模型分组")) {
                if router.availableUserModels.isEmpty {
                    Text(NSLocalizedString("没有已启用且支持工具调用的云端聊天模型", value: "No enabled cloud chat model supports tool calling", comment: "无可用用户向导模型"))
                } else {
                    ForEach(router.availableUserModels, id: \.id) { model in
                        Button {
                            router.selectUserModel(model)
                            routeRevision &+= 1
                        } label: {
                            routeMenuLabel(
                                "\(model.model.displayName) · \(model.provider.name)",
                                selected: router.route == .userModel && router.selectedUserModel?.id == model.id
                            )
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: router.route == .builtIn ? "sparkles" : "person.crop.circle")
                Text(selectedRouteTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
        }
        .id(routeRevision)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(NSLocalizedString("选择向导模型", value: "Choose Guide Model", comment: "向导线路菜单辅助标签"))
    }

    private var selectedRouteTitle: String {
        if router.route == .builtIn {
            return NSLocalizedString("内置免费向导", value: "Built-in Free Guide", comment: "内置向导线路名称")
        }
        guard let model = router.selectedUserModel else {
            return NSLocalizedString("所选向导模型当前不可用。", value: "The selected guide model is currently unavailable.", comment: "向导所选模型失效提示")
        }
        return "\(model.model.displayName) · \(model.provider.name)"
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                NSLocalizedString("问问软件怎么用，或让我带你去设置…", value: "Ask how to use the app or find a setting…", comment: "向导输入框占位"),
                text: $input,
                axis: .vertical
            )
            .lineLimit(compact ? 1...4 : 1...6)
            .textFieldStyle(.plain)
            .focused($inputFocused)
            .submitLabel(.send)
            .onSubmit(send)

            if controller.isResponding {
                Button {
                    controller.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .accessibilityLabel(NSLocalizedString("停止生成", value: "Stop Generating", comment: "停止向导生成按钮"))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(
                    input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || controller.isRestoringHistory
                        || controller.pendingProposal != nil
                        || controller.isAwaitingToolContinuation
                )
                .accessibilityLabel(NSLocalizedString("发送", value: "Send", comment: "发送向导问题按钮"))
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func routeMenuLabel(_ title: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : "circle")
    }

    private func send() {
        let content = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !controller.isRestoringHistory,
              !controller.isResponding, controller.pendingProposal == nil,
              !controller.isAwaitingToolContinuation else { return }
        input = ""
        followsLatestMessage = true
        controller.send(content)
    }
}

private struct GuideMessageActionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let message: GuideConversationMessage
    let canEdit: Bool
    let canRetry: Bool
    let onEdit: () -> Void
    let onRetry: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if canEdit {
                        Button(action: onEdit) {
                            Label(NSLocalizedString("编辑", value: "Edit", comment: "编辑向导用户消息"), systemImage: "pencil")
                        }
                    }
                    if canRetry {
                        Button(action: onRetry) {
                            Label(NSLocalizedString("重试", value: "Retry", comment: "重试向导最近回答"), systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = message.content
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("复制", value: "Copy", comment: "复制向导消息"), systemImage: "doc.on.doc")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle(NSLocalizedString("消息操作", value: "Message Actions", comment: "向导消息操作标题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", value: "Done", comment: "关闭向导消息操作")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct GuideFullConversationView: View {
    @ObservedObject var controller: GuideConversationController

    var body: some View {
        GuideConversationView(controller: controller, compact: false)
            .navigationTitle(NSLocalizedString("使用助手", value: "App Guide", comment: "向导完整会话标题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if controller.canUndo {
                        GuideUndoButton(controller: controller)
                    }
                    Button {
                        controller.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(NSLocalizedString("清空向导上下文", value: "Clear Guide Context", comment: "清空向导按钮"))
                }
            }
    }
}

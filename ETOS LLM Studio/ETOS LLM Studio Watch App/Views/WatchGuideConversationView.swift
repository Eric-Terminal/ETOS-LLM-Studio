// ============================================================================
// WatchGuideConversationView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// watchOS 不悬浮窗口；设置页进入的二级页面复用同一段内存会话。
// ============================================================================

import SwiftUI
import ETOSCore

private struct WatchGuideToolCallRow: View {
    let call: InternalToolCall
    let isActive: Bool
    let isAwaitingConfirmation: Bool

    private var status: (title: String, systemImage: String, color: Color) {
        switch call.resultDisposition {
        case .completed:
            return (NSLocalizedString("已完成", comment: "手表向导工具调用完成状态"), "checkmark.circle.fill", .green)
        case .failed:
            return (NSLocalizedString("失败", comment: "手表向导工具调用失败状态"), "xmark.circle.fill", .red)
        case .rejected:
            return (NSLocalizedString("已拒绝", comment: "手表向导工具调用拒绝状态"), "hand.raised.circle.fill", .secondary)
        case nil where isAwaitingConfirmation:
            return (NSLocalizedString("等待确认", comment: "手表向导工具调用等待确认状态"), "clock.badge.exclamationmark", .orange)
        case nil where isActive:
            return (NSLocalizedString("处理中", comment: "手表向导工具调用处理状态"), "gearshape.2", .blue)
        case nil:
            return (NSLocalizedString("已停止", comment: "手表向导工具调用停止状态"), "pause.circle.fill", .secondary)
        }
    }

    var body: some View {
        let status = status
        HStack(spacing: 6) {
            if isActive && call.resultDisposition == nil && !isAwaitingConfirmation {
                ProgressView()
            } else {
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(call.toolName)
                    .font(.caption2.monospaced().weight(.semibold))
                    .lineLimit(2)
                Text(status.title)
                    .font(.caption2)
                    .foregroundStyle(status.color)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// watchOS 只刷新正在增长的回答，避免 List 在每批流式文本到达时重建历史 Markdown。
private struct WatchGuideMessageContent: View, Equatable {
    let message: GuideConversationMessage
    let displayedContent: String
    let isStreaming: Bool
    let isToolActive: Bool
    let awaitingToolCallID: String?
    let enableMarkdown: Bool
    let enableAdvancedRenderer: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
            && lhs.displayedContent == rhs.displayedContent
            && lhs.isStreaming == rhs.isStreaming
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
                ForEach(message.toolCalls, id: \.id) { call in
                    WatchGuideToolCallRow(
                        call: call,
                        isActive: isToolActive,
                        isAwaitingConfirmation: awaitingToolCallID == call.id
                    )
                }
            }
        } else {
            Text(displayedContent)
                .font(.footnote)
                .foregroundStyle(message.role == .error ? .red : .primary)
        }
    }
}

private struct WatchGuideEntryModifier: ViewModifier {
    @EnvironmentObject private var controller: GuideConversationController
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if appConfig.guideOverlayEnabled {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            GuideContextCoordinator.shared.pinActivePage()
                            isPresented = true
                        } label: {
                            Image(systemName: "questionmark.bubble")
                        }
                        .accessibilityLabel(NSLocalizedString("询问当前页面", comment: "手表当前页面向导入口"))
                    }
                }
            }
            .navigationDestination(isPresented: $isPresented) {
                WatchGuideConversationView(controller: controller)
            }
    }
}

extension View {
    func watchGuideEntry() -> some View {
        modifier(WatchGuideEntryModifier())
    }
}

struct WatchGuideConversationView: View {
    @ObservedObject var controller: GuideConversationController
    @ObservedObject private var router: GuideModelRouter
    @ObservedObject private var coordinator = GuideContextCoordinator.shared
    @ObservedObject private var appConfig = AppConfigStore.shared

    @State private var input = ""
    @State private var editingMessage: GuideConversationMessage?

    init(controller: GuideConversationController) {
        self.controller = controller
        _router = ObservedObject(wrappedValue: controller.router)
    }

    var body: some View {
        List {
            if controller.messages.isEmpty {
                Section {
                    Label(NSLocalizedString("询问当前页面", comment: "手表向导空状态标题"), systemImage: "questionmark.bubble")
                    Text(emptyStateDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(NSLocalizedString("对话", comment: "手表向导消息分组")) {
                    ForEach(controller.messages) { message in
                        messageRow(message)
                    }
                    if controller.isResponding {
                        ProgressView(NSLocalizedString("正在回答…", comment: "手表向导回答状态"))
                    }
                }
            }

            if let proposal = controller.pendingProposal {
                Section(NSLocalizedString("等待确认", comment: "手表向导修改预览分组")) {
                    Text(proposal.summary)
                    NavigationLink {
                        WatchGuideProposalConfirmationView(
                            controller: controller,
                            proposal: proposal
                        )
                    } label: {
                        Label(NSLocalizedString("查看并确认", comment: "手表查看向导修改按钮"), systemImage: "checkmark.circle")
                    }
                }
            }

            if controller.isAwaitingToolContinuation {
                Section(NSLocalizedString("继续查找？", comment: "手表向导连续工具调用确认标题")) {
                    Text(NSLocalizedString("向导已连续完成 8 轮工具调用。是否允许它继续读取页面、文档或源码？", comment: "手表向导连续工具调用确认说明"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("继续调用", comment: "手表允许向导继续调用工具")) {
                        controller.continueToolCalls()
                    }
                    Button(NSLocalizedString("到此为止", comment: "手表停止向导继续调用工具"), role: .cancel) {
                        controller.finishToolCalls()
                    }
                }
            }

            if controller.lastError != nil {
                Section(NSLocalizedString("恢复", comment: "手表向导错误恢复分组")) {
                    Button(NSLocalizedString("重试", comment: "手表向导重试按钮")) {
                        controller.retryLastResponse()
                    }
                    if controller.canRetryWithBuiltIn {
                        Button(NSLocalizedString("使用内置向导重试", comment: "手表切换内置向导重试按钮")) {
                            controller.retryWithBuiltIn()
                        }
                    }
                }
            }

            Section(NSLocalizedString("回答模型", comment: "手表向导模型线路分组")) {
                routeButton(
                    title: NSLocalizedString("内置免费向导", comment: "内置向导线路名称"),
                    selected: router.route == .builtIn
                ) {
                    router.useBuiltIn()
                }
                ForEach(router.availableUserModels, id: \.id) { model in
                    routeButton(
                        title: "\(model.model.displayName) · \(model.provider.name)",
                        selected: router.route == .userModel && router.selectedUserModel?.id == model.id
                    ) {
                        router.selectUserModel(model)
                    }
                }
            }

            Section(NSLocalizedString("问题", comment: "手表向导问题输入分组")) {
                TextField(NSLocalizedString("询问这个页面…", comment: "手表向导输入框占位"), text: $input)
                if controller.isResponding {
                    Button(NSLocalizedString("停止生成", comment: "手表停止向导生成按钮"), role: .destructive) {
                        controller.cancel()
                    }
                } else {
                    Button(NSLocalizedString("发送", comment: "手表发送向导问题按钮")) {
                        send()
                    }
                    .disabled(
                        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || controller.pendingProposal != nil
                            || controller.isAwaitingToolContinuation
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("页面向导", comment: "手表向导标题"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if controller.canUndo {
                    Button {
                        controller.undoLastChange()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .accessibilityLabel(NSLocalizedString("撤销上次修改", comment: "手表向导撤销按钮"))
                }
                Button {
                    controller.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(NSLocalizedString("清空向导上下文", comment: "手表清空向导按钮"))
            }
        }
        .onDisappear {
            coordinator.unpinActivePage()
        }
        .sheet(item: $editingMessage) { message in
            WatchGuideMessageEditorView(controller: controller, message: message)
        }
    }

    private var emptyStateDetail: String {
        guard let title = coordinator.activePage?.title else {
            return NSLocalizedString("这个页面还没有声明可供向导读取的上下文。", comment: "手表向导无页面上下文说明")
        }
        return String(
            format: NSLocalizedString("向导会使用“%@”页面声明的配置与文档回答。", comment: "手表向导当前页面说明"),
            title
        )
    }

    @ViewBuilder
    private func messageRow(_ message: GuideConversationMessage) -> some View {
        let isStreaming = controller.streamingMessageID == message.id
        let row = WatchGuideMessageContent(
            message: message,
            displayedContent: isStreaming ? controller.streamingContent : message.content,
            isStreaming: isStreaming,
            isToolActive: controller.isResponding && controller.messages.last?.id == message.id,
            awaitingToolCallID: controller.pendingProposal?.toolCallID,
            enableMarkdown: appConfig.enableMarkdown,
            enableAdvancedRenderer: appConfig.enableAdvancedRenderer
        )
        .equatable()

        row.swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if controller.canRetryMessage(message.id) {
                Button {
                    controller.retryResponse(for: message.id)
                } label: {
                    Label(NSLocalizedString("重试", comment: "手表重试向导回答"), systemImage: "arrow.clockwise")
                }
            }
            if controller.canEditMessage(message.id) {
                Button {
                    editingMessage = message
                } label: {
                    Label(NSLocalizedString("编辑", comment: "手表编辑向导消息"), systemImage: "pencil")
                }
            }
        }
    }

    private func routeButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.plain)
    }

    private func send() {
        let content = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
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
                Section(NSLocalizedString("消息内容", comment: "手表向导消息编辑内容")) {
                    TextField(NSLocalizedString("消息内容", comment: "手表向导消息编辑输入框"), text: $content)
                }
                Section {
                    Button(NSLocalizedString("保存", comment: "手表保存向导消息编辑")) {
                        controller.editUserMessage(message.id, content: content)
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(NSLocalizedString("编辑消息", comment: "手表编辑向导消息标题"))
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
            Section(NSLocalizedString("修改内容", comment: "手表向导修改详情分组")) {
                ForEach(proposal.mutations) { mutation in
                    VStack(alignment: .leading) {
                        Text(mutation.label)
                        Text(mutation.newValue.prettyPrintedCompact())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
            }
            Section {
                Button(NSLocalizedString("确认应用", comment: "手表确认向导修改按钮")) {
                    controller.confirmPendingProposal()
                    dismiss()
                }
                Button(NSLocalizedString("不应用", comment: "手表拒绝向导修改按钮"), role: .cancel) {
                    controller.rejectPendingProposal()
                    dismiss()
                }
            }
        }
        .navigationTitle(NSLocalizedString("确认修改", comment: "手表向导确认修改标题"))
    }
}

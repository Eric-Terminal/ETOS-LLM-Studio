// ============================================================================
// GuideConversationViews.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 内存向导的紧凑面板与完整会话共用同一内容视图。
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

private struct GuideToolCallRow: View {
    let call: InternalToolCall
    let isActive: Bool
    let isAwaitingConfirmation: Bool

    private var status: (title: String, systemImage: String, color: Color) {
        switch call.resultDisposition {
        case .completed:
            return (NSLocalizedString("已完成", comment: "向导工具调用完成状态"), "checkmark.circle.fill", .green)
        case .failed:
            return (NSLocalizedString("失败", comment: "向导工具调用失败状态"), "xmark.circle.fill", .red)
        case .rejected:
            return (NSLocalizedString("已拒绝", comment: "向导工具调用拒绝状态"), "hand.raised.circle.fill", .secondary)
        case nil where isAwaitingConfirmation:
            return (NSLocalizedString("等待确认", comment: "向导工具调用等待确认状态"), "clock.badge.exclamationmark", .orange)
        case nil where isActive:
            return (NSLocalizedString("处理中", comment: "向导工具调用处理状态"), "gearshape.2", .blue)
        case nil:
            return (NSLocalizedString("已停止", comment: "向导工具调用停止状态"), "pause.circle.fill", .secondary)
        }
    }

    var body: some View {
        let status = status
        HStack(spacing: 8) {
            if isActive && call.resultDisposition == nil && !isAwaitingConfirmation {
                ProgressView()
                    .controlSize(.mini)
                    .tint(status.color)
            } else {
                Image(systemName: status.systemImage)
                    .foregroundStyle(status.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(call.toolName)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(2)
                Text(NSLocalizedString("工具调用", comment: "向导工具调用类型标签"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(status.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(status.color)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct GuideConversationView: View {
    @ObservedObject var controller: GuideConversationController
    @ObservedObject private var router: GuideModelRouter
    @ObservedObject private var coordinator = GuideContextCoordinator.shared
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if controller.messages.isEmpty {
                        emptyState
                    }
                    ForEach(controller.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    if controller.isResponding {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(GuideMessageListAnchor.bottom)
                        .onAppear {
                            followsLatestMessage = true
                        }
                }
                .padding()
            }
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
            .onChange(of: controller.streamingContentRevision) { _, _ in
                guard followsLatestMessage else { return }
                proxy.scrollTo(GuideMessageListAnchor.bottom, anchor: .bottom)
            }
            .onChange(of: controller.isResponding) { _, isResponding in
                if isResponding {
                    followsLatestMessage = true
                }
                guard followsLatestMessage else { return }
                proxy.scrollTo(GuideMessageListAnchor.bottom, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(.title2)
                .foregroundStyle(.blue)
            Text(NSLocalizedString("询问当前页面", comment: "向导空状态标题"))
                .font(.headline)
            Text(emptyStateDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyStateDetail: String {
        if let page = coordinator.activePage?.title {
            return String(
                format: NSLocalizedString("向导已了解“%@”页面公开的设置与文档。可以直接问它在哪里配置，或让它生成一份待确认的修改。", comment: "向导当前页面空状态说明"),
                page
            )
        }
        return NSLocalizedString("这个页面还没有声明可供向导读取的上下文。", comment: "向导无页面上下文说明")
    }

    @ViewBuilder
    private func messageBubble(_ message: GuideConversationMessage) -> some View {
        let isUser = message.role == .user
        let shape = TelegramBubbleShape(isOutgoing: isUser)
        HStack {
            if isUser { Spacer(minLength: compact ? 28 : 64) }
            VStack(alignment: .leading, spacing: 6) {
                if message.role == .tool {
                    Label(NSLocalizedString("页面操作", comment: "向导工具消息标签"), systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !message.content.isEmpty {
                    messageContent(message)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.toolCalls, id: \.id) { call in
                            GuideToolCallRow(
                                call: call,
                                isActive: controller.isResponding && controller.messages.last?.id == message.id,
                                isAwaitingConfirmation: controller.pendingProposal?.toolCallID == call.id
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isLatestError(message) {
                    errorRecoveryActions
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(bubbleBackground(for: message.role), in: shape)
            .contentShape(shape)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        messageActionMessage = message
                    }
            )
            if !isUser { Spacer(minLength: compact ? 20 : 56) }
        }
    }

    @ViewBuilder
    private func messageContent(_ message: GuideConversationMessage) -> some View {
        if message.role == .assistant {
            ETAdvancedMarkdownRenderer(
                content: message.content,
                preparedContent: nil,
                enableMarkdown: appConfig.enableMarkdown,
                isOutgoing: false,
                enableAdvancedRenderer: appConfig.enableAdvancedRenderer,
                enableMathRendering: appConfig.enableAdvancedRenderer,
                customTextColor: nil,
                isStreaming: isStreaming(message)
            )
        } else {
            Text(message.content)
                .font(.body)
                .foregroundStyle(message.role == .error ? .red : .primary)
        }
    }

    private func isStreaming(_ message: GuideConversationMessage) -> Bool {
        controller.isResponding
            && message.role == .assistant
    }

    private func isLatestError(_ message: GuideConversationMessage) -> Bool {
        message.role == .error
            && controller.lastError != nil
            && controller.lastErrorMessageID == message.id
    }

    private func bubbleBackground(for role: GuideConversationMessage.Role) -> some ShapeStyle {
        switch role {
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

    private func proposalPreview(_ proposal: GuideActionProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(NSLocalizedString("等待确认", comment: "向导修改预览状态"), systemImage: "slider.horizontal.3")
                .font(.headline)
            Text(proposal.summary)
                .font(.subheadline)
            ForEach(proposal.mutations) { mutation in
                HStack(alignment: .firstTextBaseline) {
                    Text(mutation.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(mutation.newValue.prettyPrintedCompact())
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .font(.caption)
            }
            HStack {
                Button(NSLocalizedString("不应用", comment: "拒绝向导修改按钮"), role: .cancel) {
                    controller.rejectPendingProposal()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(NSLocalizedString("确认应用", comment: "确认向导修改按钮")) {
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
                NSLocalizedString("继续查找？", comment: "向导连续工具调用确认标题"),
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
            )
            .font(.headline)
            Text(NSLocalizedString("向导已连续完成 8 轮工具调用。是否允许它继续读取页面、文档或源码？", comment: "向导连续工具调用确认说明"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Button(NSLocalizedString("到此为止", comment: "停止向导继续调用工具"), role: .cancel) {
                    controller.finishToolCalls()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(NSLocalizedString("继续调用", comment: "允许向导继续调用工具")) {
                    controller.continueToolCalls()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
    }

    private var errorRecoveryActions: some View {
        HStack(spacing: 8) {
            Button {
                controller.retryLastResponse()
            } label: {
                Label(NSLocalizedString("重试", comment: "向导重试按钮"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .font(.callout.weight(.semibold))

            if controller.canRetryWithBuiltIn || router.route == .userModel {
                Menu {
                    if controller.canRetryWithBuiltIn {
                        Button {
                            controller.retryWithBuiltIn()
                            routeRevision &+= 1
                        } label: {
                            Label(
                                NSLocalizedString("使用内置向导重试", comment: "切换内置向导重试按钮"),
                                systemImage: "sparkles"
                            )
                        }
                    }
                    if router.route == .userModel {
                        Button {
                            NotificationCenter.default.post(name: .requestGuideModelManagement, object: nil)
                        } label: {
                            Label(
                                NSLocalizedString("检查模型配置", comment: "向导错误后打开模型管理按钮"),
                                systemImage: "slider.horizontal.3"
                            )
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(NSLocalizedString("更多", comment: "向导错误恢复更多操作"))
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    private var modelBar: some View {
        HStack {
            Text(NSLocalizedString("回答使用的模型", comment: "向导当前回答模型标签"))
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
                    NSLocalizedString("内置免费向导", comment: "内置向导线路名称"),
                    selected: router.route == .builtIn
                )
            }
            Section(NSLocalizedString("使用我的模型", comment: "用户向导模型分组")) {
                if router.availableUserModels.isEmpty {
                    Text(NSLocalizedString("没有已启用且支持工具调用的云端聊天模型", comment: "无可用用户向导模型"))
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
        .accessibilityLabel(NSLocalizedString("选择向导模型", comment: "向导线路菜单辅助标签"))
    }

    private var selectedRouteTitle: String {
        if router.route == .builtIn {
            return NSLocalizedString("内置免费向导", comment: "内置向导线路名称")
        }
        guard let model = router.selectedUserModel else {
            return NSLocalizedString("所选向导模型当前不可用。", comment: "向导所选模型失效提示")
        }
        return "\(model.model.displayName) · \(model.provider.name)"
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(
                NSLocalizedString("询问这个页面…", comment: "向导输入框占位"),
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
                .accessibilityLabel(NSLocalizedString("停止生成", comment: "停止向导生成按钮"))
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(
                    input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || controller.pendingProposal != nil
                        || controller.isAwaitingToolContinuation
                )
                .accessibilityLabel(NSLocalizedString("发送", comment: "发送向导问题按钮"))
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
        guard !content.isEmpty else { return }
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
                            Label(NSLocalizedString("编辑", comment: "编辑向导用户消息"), systemImage: "pencil")
                        }
                    }
                    if canRetry {
                        Button(action: onRetry) {
                            Label(NSLocalizedString("重试", comment: "重试向导最近回答"), systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = message.content
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("复制", comment: "复制向导消息"), systemImage: "doc.on.doc")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle(NSLocalizedString("消息操作", comment: "向导消息操作标题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "关闭向导消息操作")) {
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
            .navigationTitle(NSLocalizedString("页面向导", comment: "向导完整会话标题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if controller.canUndo {
                        Button {
                            controller.undoLastChange()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .accessibilityLabel(NSLocalizedString("撤销上次修改", comment: "向导撤销按钮"))
                    }
                    Button {
                        controller.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(NSLocalizedString("清空向导上下文", comment: "清空向导按钮"))
                }
            }
    }
}

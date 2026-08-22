// ============================================================================
// GuideConversationViews.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 内存向导的紧凑面板与完整会话共用同一内容视图。
// ============================================================================

import SwiftUI
import ETOSCore

extension Notification.Name {
    static let requestGuideModelManagement = Notification.Name("requestGuideModelManagement")
}

struct GuideConversationView: View {
    @ObservedObject var controller: GuideConversationController
    @ObservedObject private var router: GuideModelRouter
    @ObservedObject private var coordinator = GuideContextCoordinator.shared
    let compact: Bool

    @State private var input = ""
    @State private var routeRevision = 0
    @FocusState private var inputFocused: Bool

    init(controller: GuideConversationController, compact: Bool) {
        self.controller = controller
        self.compact = compact
        _router = ObservedObject(wrappedValue: controller.router)
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            if let proposal = controller.pendingProposal {
                proposalPreview(proposal)
            }
            if controller.lastError != nil {
                recoveryActions
            }
            composer
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
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
                }
                .padding()
            }
            .onChange(of: controller.messages) { _, messages in
                guard let id = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
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
        HStack {
            if isUser { Spacer(minLength: compact ? 28 : 64) }
            VStack(alignment: .leading, spacing: 4) {
                if message.role == .tool {
                    Label(NSLocalizedString("页面操作", comment: "向导工具消息标签"), systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundStyle(message.role == .error ? .red : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(bubbleBackground(for: message.role))
            if !isUser { Spacer(minLength: compact ? 20 : 56) }
        }
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

    private var recoveryActions: some View {
        HStack {
            Button(NSLocalizedString("重试", comment: "向导重试按钮")) {
                controller.retryLastResponse()
            }
            .buttonStyle(.bordered)
            if controller.canRetryWithBuiltIn {
                Button(NSLocalizedString("使用内置向导重试", comment: "切换内置向导重试按钮")) {
                    controller.retryWithBuiltIn()
                    routeRevision &+= 1
                }
                .buttonStyle(.borderedProminent)
            }
            if router.route == .userModel {
                Button(NSLocalizedString("检查模型配置", comment: "向导错误后打开模型管理按钮")) {
                    NotificationCenter.default.post(name: .requestGuideModelManagement, object: nil)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
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
                Image(systemName: router.route == .builtIn ? "sparkles" : "person.crop.circle")
                    .frame(width: 30, height: 30)
            }
            .id(routeRevision)
            .accessibilityLabel(NSLocalizedString("选择向导模型", comment: "向导线路菜单辅助标签"))

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
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.pendingProposal != nil)
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
        controller.send(content)
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

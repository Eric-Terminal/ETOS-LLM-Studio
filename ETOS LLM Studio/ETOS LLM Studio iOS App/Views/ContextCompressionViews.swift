// ============================================================================
// ContextCompressionViews.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 续聊上下文气泡与压缩选项界面。
// ============================================================================

import SwiftUI
import ETOSCore

struct ContextCompressionReminderRefreshKey: Hashable {
    let sessionID: UUID?
    let messageVersion: Int
    let isSending: Bool
    let continuationID: UUID?
    let reminderEnabled: Bool
    let tokenThreshold: Int
}

struct ContextCompressionReminderCard: View {
    let estimatedTokens: Int
    let threshold: Int
    let onCompress: () -> Void

    var body: some View {
        Button(action: onCompress) {
            HStack {
                Image(systemName: "rectangle.compress.vertical")
                    .foregroundStyle(.tint)

                VStack(alignment: .leading) {
                    Text(NSLocalizedString(
                        "建议压缩上下文",
                        comment: "Context compression reminder title"
                    ))
                    .font(.subheadline.weight(.semibold))

                    Text(String(
                        format: NSLocalizedString(
                            "当前对话约 %@ Token，已达到 %@ Token 的提醒阈值。",
                            comment: "Context compression reminder token detail"
                        ),
                        estimatedTokens.formatted(.number),
                        threshold.formatted(.number)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        }
        .accessibilityHint(NSLocalizedString(
            "点击后立即按默认参数创建续聊会话",
            comment: "Context compression reminder accessibility hint"
        ))
    }
}

struct ConversationContinuationBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let context: ConversationContinuationContext
    @Binding var isExpanded: Bool
    let sourceSessionAvailable: Bool
    let onOpenSource: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Button {
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.spring(response: 0.34, dampingFraction: 1)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "rectangle.compress.vertical")
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("续聊上下文", comment: "Continuation context bubble title"))
                            .font(.subheadline.weight(.semibold))
                        Text(contextSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                VStack(alignment: .leading) {
                    Text(NSLocalizedString("较早对话摘要", comment: "Continuation context summary heading"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(context.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !context.retainedMessages.isEmpty {
                        Text(NSLocalizedString("最近对话原文", comment: "Continuation context retained messages heading"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top)

                        ForEach(context.retainedMessages) { message in
                            VStack(alignment: .leading) {
                                Text(roleTitle(message.role))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(message.content)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Button(action: onOpenSource) {
                        Label(
                            sourceSessionAvailable
                                ? NSLocalizedString("打开原会话", comment: "Open continuation source session action")
                                : NSLocalizedString("原会话已删除", comment: "Continuation source session deleted state"),
                            systemImage: sourceSessionAvailable ? "arrow.up.backward.circle" : "trash"
                        )
                        .font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!sourceSessionAvailable)
                    .padding(.top)
                }
                .transition(.opacity)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var contextSubtitle: String {
        String(
            format: NSLocalizedString(
                "来自“%@” · 摘要 %d 条 · 保留 %d 轮原文",
                comment: "Continuation context bubble subtitle"
            ),
            context.sourceSessionNameSnapshot,
            context.summarizedMessageCount,
            context.retainedRoundCount
        )
    }

    private func roleTitle(_ role: MessageRole) -> String {
        switch role {
        case .system:
            return NSLocalizedString("系统", comment: "Continuation retained message role")
        case .user:
            return NSLocalizedString("用户", comment: "Continuation retained message role")
        case .assistant:
            return NSLocalizedString("助手", comment: "Continuation retained message role")
        case .tool:
            return NSLocalizedString("工具", comment: "Continuation retained message role")
        case .error:
            return NSLocalizedString("错误", comment: "Continuation retained message role")
        }
    }
}

struct ContextCompressionOneTapView: View {
    typealias ProgressHandler = @MainActor @Sendable (ContextCompressionProgress) -> Void

    @Environment(\.dismiss) private var dismiss

    let session: ChatSession
    let onCompress: (@escaping ProgressHandler) async throws -> ChatSession

    @State private var progress = ContextCompressionProgress(phase: .preparing)
    @State private var compressionTask: Task<Void, Never>?
    @State private var hasStarted = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()

                ProgressView()
                    .controlSize(.large)

                Text(NSLocalizedString(
                    "正在压缩为续聊",
                    comment: "One-tap context compression progress title"
                ))
                .font(.headline)

                Text(progressText(progress))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(String(
                    format: NSLocalizedString(
                        "原会话“%@”会完整保留。",
                        comment: "One-tap context compression source preservation"
                    ),
                    session.name
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                Spacer()
            }
            .padding()
            .navigationTitle(NSLocalizedString(
                "压缩为续聊",
                comment: "One-tap context compression navigation title"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString(
                        "停止",
                        comment: "Stop one-tap context compression action"
                    )) {
                        compressionTask?.cancel()
                    }
                    .disabled(compressionTask == nil)
                }
            }
            .onAppear(perform: startIfNeeded)
            .onDisappear {
                compressionTask?.cancel()
            }
            .interactiveDismissDisabled(compressionTask != nil)
            .alert(NSLocalizedString(
                "压缩失败",
                comment: "One-tap context compression failure title"
            ), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(NSLocalizedString("关闭", comment: "Close one-tap compression error")) {
                    dismiss()
                }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        compressionTask = Task {
            do {
                _ = try await onCompress { newProgress in
                    progress = newProgress
                }
                compressionTask = nil
                dismiss()
            } catch is CancellationError {
                compressionTask = nil
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                compressionTask = nil
            }
        }
    }

    private func progressText(_ progress: ContextCompressionProgress) -> String {
        switch progress.phase {
        case .preparing:
            return NSLocalizedString("正在准备完整对话与附件…", comment: "One-tap compression preparing progress")
        case .summarizing(let completed, let total):
            return String(
                format: NSLocalizedString("正在摘要分块 %d/%d…", comment: "One-tap compression chunk progress"),
                completed,
                total
            )
        case .synthesizing(let level):
            return String(
                format: NSLocalizedString("正在进行第 %d 层归并…", comment: "One-tap compression synthesis progress"),
                level
            )
        case .saving:
            return NSLocalizedString("正在保存并切换到新会话…", comment: "One-tap compression saving progress")
        }
    }
}

struct ContextCompressionOptionsView: View {
    typealias ProgressHandler = @MainActor @Sendable (ContextCompressionProgress) -> Void

    @Environment(\.dismiss) private var dismiss

    let session: ChatSession
    let models: [RunnableModel]
    let selectedModelID: String?
    let onCompress: (ContextCompressionOptions, @escaping ProgressHandler) async throws -> ChatSession

    @State private var retainedRoundCount = ContextCompressionOptions.defaultRetainedRoundCount
    @State private var compressionModelID: String?
    @State private var focusInstruction = ""
    @State private var progress: ContextCompressionProgress?
    @State private var compressionTask: Task<Void, Never>?
    @State private var errorMessage: String?

    private let retainedRoundChoices = [0, 2, 4, 6, 10]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(NSLocalizedString(
                            "系统会创建并切换到一个新的独立会话；原会话和全部消息保持不变，之后仍可继续。",
                            comment: "Context compression options introduction"
                        ))
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.tint)
                    }
                }

                Section {
                    Picker(
                        NSLocalizedString("保留最近原文", comment: "Context compression retained rounds picker"),
                        selection: $retainedRoundCount
                    ) {
                        ForEach(retainedRoundChoices, id: \.self) { count in
                            Text(String(
                                format: NSLocalizedString("%d 轮", comment: "Context compression retained round count"),
                                count
                            ))
                            .tag(count)
                        }
                    }

                    Picker(
                        NSLocalizedString("压缩模型", comment: "Context compression model picker"),
                        selection: $compressionModelID
                    ) {
                        Text(NSLocalizedString("自动选择", comment: "Automatic context compression model choice"))
                            .tag(String?.none)
                        ForEach(models) { model in
                            Text("\(model.model.displayName) · \(model.provider.name)")
                                .tag(Optional(model.id))
                        }
                    }
                } footer: {
                    Text(NSLocalizedString(
                        "最近轮次会按原角色和原文保留；更早内容会完整分片并递归归并，不会通过截断或丢弃旧消息缩短输入。",
                        comment: "Context compression retention explanation"
                    ))
                }

                Section {
                    TextEditor(text: $focusInstruction)
                        .frame(minHeight: 88)
                } header: {
                    Text(NSLocalizedString("额外侧重点（可选）", comment: "Context compression focus section"))
                } footer: {
                    Text(NSLocalizedString(
                        "例如需要特别保留的人物关系、术语、写作风格或未完成事项。留空时会均衡保留全部续聊信息。",
                        comment: "Context compression focus explanation"
                    ))
                }

                if let progress {
                    Section {
                        HStack {
                            ProgressView()
                            Text(progressText(progress))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        startCompression()
                    } label: {
                        Label(
                            NSLocalizedString("创建续聊会话", comment: "Start context compression action"),
                            systemImage: "rectangle.compress.vertical"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(compressionTask != nil || models.isEmpty)
                } footer: {
                    if models.isEmpty {
                        Text(NSLocalizedString(
                            "请先激活一个聊天模型。",
                            comment: "Context compression missing model hint"
                        ))
                    }
                }
            }
            .navigationTitle(NSLocalizedString("压缩为续聊", comment: "Context compression options title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(compressionTask == nil
                        ? NSLocalizedString("取消", comment: "")
                        : NSLocalizedString("停止", comment: "Stop context compression action")) {
                        if let compressionTask {
                            compressionTask.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(compressionTask != nil)
            .onAppear {
                compressionModelID = models.contains { $0.id == selectedModelID }
                    ? selectedModelID
                    : nil
            }
            .alert(NSLocalizedString("压缩失败", comment: "Context compression failure title"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button(NSLocalizedString("好的", comment: ""), role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func startCompression() {
        let trimmedFocus = focusInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = ContextCompressionOptions(
            retainedRoundCount: retainedRoundCount,
            focusInstruction: trimmedFocus.isEmpty ? nil : trimmedFocus,
            compressionModelIdentifier: compressionModelID
        )
        compressionTask = Task {
            do {
                _ = try await onCompress(options) { newProgress in
                    progress = newProgress
                }
                compressionTask = nil
                dismiss()
            } catch is CancellationError {
                progress = nil
                compressionTask = nil
            } catch {
                errorMessage = error.localizedDescription
                progress = nil
                compressionTask = nil
            }
        }
    }

    private func progressText(_ progress: ContextCompressionProgress) -> String {
        switch progress.phase {
        case .preparing:
            return NSLocalizedString("正在准备完整对话与附件…", comment: "Context compression preparing progress")
        case .summarizing(let completed, let total):
            return String(
                format: NSLocalizedString("正在摘要分块 %d/%d…", comment: "Context compression chunk progress"),
                completed,
                total
            )
        case .synthesizing(let level):
            return String(
                format: NSLocalizedString("正在进行第 %d 层归并…", comment: "Context compression synthesis progress"),
                level
            )
        case .saving:
            return NSLocalizedString("正在保存并切换到新会话…", comment: "Context compression saving progress")
        }
    }
}

extension ChatView {
    var contextCompressionReminderRefreshKey: ContextCompressionReminderRefreshKey {
        ContextCompressionReminderRefreshKey(
            sessionID: viewModel.currentSession?.id,
            messageVersion: viewModel.allMessageIdentityVersion,
            isSending: viewModel.isSendingMessage,
            continuationID: continuationContext?.id,
            reminderEnabled: appConfig.enableContextCompressionReminder,
            tokenThreshold: appConfig.contextCompressionReminderTokenThreshold
        )
    }

    var shouldShowContextCompressionReminder: Bool {
        guard let session = viewModel.currentSession,
              !session.isTemporary,
              !viewModel.isSendingMessage,
              !viewModel.activatedChatModels.isEmpty else {
            return false
        }
        return ContextCompressionReminderPolicy.shouldRemind(
            estimatedTokens: contextCompressionEstimatedTokens,
            isEnabled: appConfig.enableContextCompressionReminder,
            tokenThreshold: appConfig.contextCompressionReminderTokenThreshold
        )
    }

    @MainActor
    func refreshContextCompressionReminderEstimate() async {
        guard appConfig.enableContextCompressionReminder,
              let sessionID = viewModel.currentSession?.id,
              viewModel.currentSession?.isTemporary == false else {
            contextCompressionEstimatedTokens = 0
            return
        }
        let messages = viewModel.allMessagesForSession
        let context = continuationContext
        let estimate = await Task.detached(priority: .utility) {
            ContextCompressionReminderEstimator.estimate(
                messages: messages,
                continuationContext: context
            )
        }.value
        try? Task.checkCancellation()
        guard !Task.isCancelled, viewModel.currentSession?.id == sessionID else { return }
        contextCompressionEstimatedTokens = estimate
    }

    func presentOneTapContextCompression() {
        guard let session = viewModel.currentSession,
              !session.isTemporary,
              !viewModel.isSendingMessage else { return }
        contextCompressionReminderSourceSession = session
    }

    @MainActor
    func reloadContinuationContext() async {
        guard let sessionID = viewModel.currentSession?.id else {
            continuationContext = nil
            isContinuationSourceSessionAvailable = false
            return
        }
        do {
            let loadedContext = try await viewModel.loadConversationContinuationContext(for: sessionID)
            try Task.checkCancellation()
            guard viewModel.currentSession?.id == sessionID else { return }
            continuationContext = loadedContext
            isContinuationSourceSessionAvailable = loadedContext.map { context in
                viewModel.chatSessions.contains { $0.id == context.sourceSessionID }
            } ?? false
        } catch is CancellationError {
            return
        } catch {
            continuationContext = nil
            isContinuationSourceSessionAvailable = false
        }
    }
}

// ============================================================================
// WatchContextCompressionViews.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 续聊上下文卡片、详情与压缩选项界面。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchContextCompressionReminderRefreshKey: Hashable {
    let sessionID: UUID?
    let messageVersion: Int
    let isSending: Bool
    let continuationID: UUID?
    let reminderEnabled: Bool
    let tokenThreshold: Int
}

struct WatchContextCompressionReminderCard: View {
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
                        comment: "Watch context compression reminder title"
                    ))
                    .etFont(.footnote.weight(.semibold))

                    Text(String(
                        format: NSLocalizedString(
                            "约 %@ / %@ Token",
                            comment: "Watch context compression reminder token detail"
                        ),
                        estimatedTokens.formatted(.number),
                        threshold.formatted(.number)
                    ))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .etFont(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(NSLocalizedString(
            "点击后立即按默认参数创建续聊会话",
            comment: "Watch context compression reminder accessibility hint"
        ))
    }
}

struct WatchConversationContinuationCard: View {
    let context: ConversationContinuationContext

    var body: some View {
        HStack {
            Image(systemName: "rectangle.compress.vertical")
                .foregroundStyle(.tint)

            VStack(alignment: .leading) {
                Text(NSLocalizedString("续聊上下文", comment: "Continuation context card title"))
                    .etFont(.footnote.weight(.semibold))
                Text(context.sourceSessionNameSnapshot)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct WatchConversationContinuationDetailView: View {
    let context: ConversationContinuationContext
    let sourceSessionAvailable: Bool
    let onOpenSource: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section(NSLocalizedString("来源", comment: "Continuation context source section")) {
                Text(context.sourceSessionNameSnapshot)
                    .etFont(.footnote)

                Button {
                    onOpenSource()
                    dismiss()
                } label: {
                    Label(
                        sourceSessionAvailable
                            ? NSLocalizedString("打开原会话", comment: "Open continuation source session action")
                            : NSLocalizedString("原会话已删除", comment: "Continuation source session deleted state"),
                        systemImage: sourceSessionAvailable ? "arrow.up.backward.circle" : "trash"
                    )
                }
                .disabled(!sourceSessionAvailable)
            }

            Section(NSLocalizedString("较早对话摘要", comment: "Continuation context summary heading")) {
                Text(context.summary)
                    .etFont(.footnote)
                    .textSelection(.enabled)
            }

            if !context.retainedMessages.isEmpty {
                Section(NSLocalizedString("最近对话原文", comment: "Continuation context retained messages heading")) {
                    ForEach(context.retainedMessages) { message in
                        VStack(alignment: .leading) {
                            Text(roleTitle(message.role))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            Text(message.content)
                                .etFont(.footnote)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section(NSLocalizedString("详细信息", comment: "Continuation context details section")) {
                Text(String(
                    format: NSLocalizedString("摘要消息：%d", comment: "Continuation summarized message count"),
                    context.summarizedMessageCount
                ))
                Text(String(
                    format: NSLocalizedString("保留原文：%d 轮", comment: "Continuation retained round count"),
                    context.retainedRoundCount
                ))
            }
        }
        .navigationTitle(NSLocalizedString("续聊上下文", comment: "Continuation context detail title"))
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

struct WatchContextCompressionOneTapView: View {
    typealias ProgressHandler = @MainActor @Sendable (ContextCompressionProgress) -> Void

    @Environment(\.dismiss) private var dismiss

    let session: ChatSession
    let onCompress: (@escaping ProgressHandler) async throws -> ChatSession

    @State private var progress = ContextCompressionProgress(phase: .preparing)
    @State private var compressionTask: Task<Void, Never>?
    @State private var hasStarted = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            Spacer()

            ProgressView()

            Text(NSLocalizedString(
                "正在压缩为续聊",
                comment: "Watch one-tap context compression progress title"
            ))
            .etFont(.headline)
            .multilineTextAlignment(.center)

            Text(progressText(progress))
                .etFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(String(
                format: NSLocalizedString(
                    "原会话“%@”会完整保留。",
                    comment: "Watch one-tap context compression source preservation"
                ),
                session.name
            ))
            .etFont(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Spacer()

            Button(role: .destructive) {
                compressionTask?.cancel()
            } label: {
                Label(NSLocalizedString(
                    "停止",
                    comment: "Stop watch one-tap context compression action"
                ), systemImage: "stop.fill")
            }
            .disabled(compressionTask == nil)
        }
        .navigationTitle(NSLocalizedString(
            "压缩为续聊",
            comment: "Watch one-tap context compression navigation title"
        ))
        .onAppear(perform: startIfNeeded)
        .onDisappear {
            compressionTask?.cancel()
        }
        .interactiveDismissDisabled(compressionTask != nil)
        .alert(NSLocalizedString(
            "压缩失败",
            comment: "Watch one-tap context compression failure title"
        ), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("关闭", comment: "Close watch one-tap compression error")) {
                dismiss()
            }
        } message: {
            Text(errorMessage ?? "")
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
            return NSLocalizedString("正在准备对话与附件…", comment: "Watch one-tap compression preparing progress")
        case .summarizing(let completed, let total):
            return String(
                format: NSLocalizedString("摘要 %d/%d…", comment: "Watch one-tap compression chunk progress"),
                completed,
                total
            )
        case .synthesizing(let level):
            return String(
                format: NSLocalizedString("第 %d 层归并…", comment: "Watch one-tap compression synthesis progress"),
                level
            )
        case .saving:
            return NSLocalizedString("正在保存新会话…", comment: "Watch one-tap compression saving progress")
        }
    }
}

struct WatchContextCompressionOptionsView: View {
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
        Form {
            Section {
                Text(NSLocalizedString(
                    "创建新的独立会话，原会话会完整保留。",
                    comment: "Watch context compression introduction"
                ))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker(
                    NSLocalizedString("保留原文", comment: "Watch context compression retained rounds picker"),
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
                        Text(model.model.displayName)
                            .tag(Optional(model.id))
                    }
                }
            } footer: {
                Text(NSLocalizedString(
                    "更早内容会完整分片处理，不截断或丢弃消息。",
                    comment: "Watch context compression retention explanation"
                ))
            }

            Section(NSLocalizedString("额外侧重点（可选）", comment: "Context compression focus section")) {
                TextField(
                    NSLocalizedString("需要特别保留的内容", comment: "Watch context compression focus placeholder"),
                    text: $focusInstruction
                )
            }

            if let progress {
                Section {
                    ProgressView()
                    Text(progressText(progress))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
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
                }
                .disabled(compressionTask != nil || models.isEmpty)

                if compressionTask != nil {
                    Button(role: .destructive) {
                        compressionTask?.cancel()
                    } label: {
                        Label(NSLocalizedString("停止", comment: "Stop context compression action"), systemImage: "stop.fill")
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("压缩为续聊", comment: "Context compression options title"))
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
            return NSLocalizedString("正在准备对话与附件…", comment: "Watch context compression preparing progress")
        case .summarizing(let completed, let total):
            return String(
                format: NSLocalizedString("摘要 %d/%d…", comment: "Watch context compression chunk progress"),
                completed,
                total
            )
        case .synthesizing(let level):
            return String(
                format: NSLocalizedString("第 %d 层归并…", comment: "Watch context compression synthesis progress"),
                level
            )
        case .saving:
            return NSLocalizedString("正在保存新会话…", comment: "Watch context compression saving progress")
        }
    }
}

extension ContentView {
    var contextCompressionReminderRefreshKey: WatchContextCompressionReminderRefreshKey {
        WatchContextCompressionReminderRefreshKey(
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

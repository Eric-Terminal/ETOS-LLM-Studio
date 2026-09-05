// ============================================================================
// GuideConversationController.swift
// ============================================================================
// ETOS LLM Studio
//
// 向导对话可在本机恢复；执行状态只驻留内存，写入工具必须停在原生确认预览。
// ============================================================================

import Foundation
import Combine

/// 流式正文使用独立观察对象，避免每个文本批次都让模型选择器和输入框重新参与 SwiftUI 更新。
@MainActor
public final class GuideStreamingState: ObservableObject {
    public private(set) var messageID: UUID?
    public private(set) var content = ""
    public private(set) var revision = 0

    func begin(messageID: UUID) {
        objectWillChange.send()
        self.messageID = messageID
        content.removeAll(keepingCapacity: true)
        revision &+= 1
    }

    func append(_ delta: String, messageID: UUID) {
        guard self.messageID == messageID, !delta.isEmpty else { return }
        objectWillChange.send()
        content.append(contentsOf: delta)
        revision &+= 1
    }

    func reset(messageID: UUID? = nil) {
        guard messageID == nil || self.messageID == messageID else { return }
        objectWillChange.send()
        self.messageID = nil
        content.removeAll(keepingCapacity: false)
        revision &+= 1
    }
}

@MainActor
public final class GuideConversationController: ObservableObject {
    /// 首次配置有多个入口，但必须共用同一段对话，避免旧控制器覆盖刚保存的历史。
    public static let modelSetup = GuideConversationController(historyStore: .modelSetup)

    @Published public private(set) var messages: [GuideConversationMessage] = []
    @Published public private(set) var isRestoringHistory = false
    @Published public private(set) var isResponding = false
    @Published public private(set) var pendingProposal: GuideActionProposal?
    @Published public private(set) var canUndo = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastErrorMessageID: UUID?
    @Published public private(set) var canRetryWithBuiltIn = false
    @Published public private(set) var isAwaitingToolContinuation = false
    public let sessionID: UUID
    public let router: GuideModelRouter
    public let streamingState = GuideStreamingState()

    /// 兼容调用方读取当前流式快照；变化通知只由 `streamingState` 发出。
    public var streamingMessageID: UUID? { streamingState.messageID }
    public var streamingContent: String { streamingState.content }

    private let contextCoordinator: GuideContextCoordinator
    private let knowledgeService: GuideKnowledgeService
    private let sourceService: GuideSourceService
    private let historyStore: GuideConversationHistoryStore?
    private var historyRestoreTask: Task<Void, Never>?
    private var historyWriteTask: Task<Void, Never>?
    private var requestHistory: [ChatMessage] = []
    private var currentTask: Task<Void, Never>?
    private var activeTaskID: UUID?
    private var pendingToolCall: InternalToolCall?
    private var remainingToolCalls: ArraySlice<InternalToolCall> = []
    private var toolBatchPage: GuidePageDescriptor?
    private var unavailableReadTools = Set<String>()
    private var undoProposal: GuideActionProposal?
    private var latestUserMessageID: UUID?
    private var latestUserMessageAllowsEditing = false
    private var latestTurnMessageIDs: Set<UUID> = []

    public init(
        sessionID: UUID = UUID(),
        router: GuideModelRouter? = nil,
        contextCoordinator: GuideContextCoordinator? = nil,
        knowledgeService: GuideKnowledgeService = .shared,
        sourceService: GuideSourceService = .shared,
        historyStore: GuideConversationHistoryStore? = nil
    ) {
        self.sessionID = sessionID
        self.router = router ?? GuideModelRouter()
        self.contextCoordinator = contextCoordinator ?? .shared
        self.knowledgeService = knowledgeService
        self.sourceService = sourceService
        self.historyStore = historyStore
        if let historyStore {
            isRestoringHistory = true
            historyRestoreTask = Task { [weak self] in
                let restored = await historyStore.load()
                guard let self, !Task.isCancelled else { return }
                if let restored {
                    messages = restored.messages
                    requestHistory = restored.requestHistory
                    latestUserMessageID = restored.latestUserMessageID
                    latestUserMessageAllowsEditing = restored.latestUserMessageAllowsEditing
                    latestTurnMessageIDs = restored.latestTurnMessageIDs
                    if let error = messages.last, error.role == .error {
                        lastError = error.content
                        lastErrorMessageID = error.id
                        canRetryWithBuiltIn = self.router.route == .userModel
                    }
                }
                isRestoringHistory = false
                historyRestoreTask = nil
            }
        }
    }

    deinit {
        currentTask?.cancel()
        historyRestoreTask?.cancel()
    }

    public func send(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !isRestoringHistory,
              !isResponding,
              pendingProposal == nil,
              !isAwaitingToolContinuation else { return }
        lastError = nil
        lastErrorMessageID = nil
        canRetryWithBuiltIn = false
        let message = GuideConversationMessage(role: .user, content: trimmed)
        messages.append(message)
        requestHistory.append(ChatMessage(role: .user, content: trimmed))
        latestUserMessageID = message.id
        latestUserMessageAllowsEditing = true
        latestTurnMessageIDs = [message.id]
        scheduleHistorySave()
        startResponseLoop()
    }

    public func sendSetupChoice(_ choice: GuideModelSetupChoice, displayName: String) {
        guard !isRestoringHistory, !isResponding, pendingProposal == nil, !isAwaitingToolContinuation else { return }
        lastError = nil
        lastErrorMessageID = nil
        canRetryWithBuiltIn = false
        let message = GuideConversationMessage(role: .user, content: displayName)
        messages.append(message)
        requestHistory.append(ChatMessage(
            role: .user,
            content: "<guide_setup_choice version=\"1\">{\"choice\":\"\(choice.rawValue)\"}</guide_setup_choice>"
        ))
        latestUserMessageID = message.id
        latestUserMessageAllowsEditing = false
        latestTurnMessageIDs = [message.id]
        scheduleHistorySave()
        startResponseLoop()
    }

    public func retryLastResponse() {
        guard let messageID = latestUserMessageID else { return }
        retryResponse(for: messageID)
    }

    public func canEditMessage(_ messageID: UUID) -> Bool {
        !isResponding
            && pendingProposal == nil
            && !isAwaitingToolContinuation
            && latestUserMessageID == messageID
            && latestUserMessageAllowsEditing
    }

    public func canRetryMessage(_ messageID: UUID) -> Bool {
        !isResponding
            && pendingProposal == nil
            && !isAwaitingToolContinuation
            && latestTurnMessageIDs.contains(messageID)
    }

    public func editUserMessage(_ messageID: UUID, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canEditMessage(messageID),
              prepareLatestUserTurn(messageID: messageID, replacementContent: trimmed) else { return }
        startResponseLoop()
    }

    public func retryResponse(for messageID: UUID) {
        guard canRetryMessage(messageID),
              let latestUserID = latestUserMessageID,
              prepareLatestUserTurn(messageID: latestUserID, replacementContent: nil) else { return }
        startResponseLoop()
    }

    public func retryWithBuiltIn() {
        router.useBuiltIn()
        retryLastResponse()
    }

    public func cancel() {
        activeTaskID = nil
        let task = currentTask
        currentTask = nil
        task?.cancel()
        discardToolBatch()
        commitStreamingContent()
        removeEmptyAssistantMessages()
        compactRequestHistoryAfterCompletedTurn()
        isResponding = false
        isAwaitingToolContinuation = false
        scheduleHistorySave()
    }

    public func clear() {
        // 先使恢复任务失效，避免清空后迟到的磁盘读取重新填回旧对话。
        historyRestoreTask?.cancel()
        historyRestoreTask = nil
        isRestoringHistory = false
        cancel()
        messages.removeAll()
        requestHistory.removeAll()
        pendingProposal = nil
        pendingToolCall = nil
        undoProposal = nil
        canUndo = false
        lastError = nil
        lastErrorMessageID = nil
        canRetryWithBuiltIn = false
        isAwaitingToolContinuation = false
        latestUserMessageID = nil
        latestUserMessageAllowsEditing = false
        latestTurnMessageIDs.removeAll()
        scheduleHistorySave()
    }

    public func confirmPendingProposal() {
        guard let proposal = pendingProposal, let call = pendingToolCall, !isResponding else { return }
        pendingProposal = nil
        pendingToolCall = nil
        isResponding = true
        let taskID = UUID()
        activeTaskID = taskID
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await contextCoordinator.execute(proposal)
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                undoProposal = execution.undoProposal
                canUndo = execution.undoProposal != nil
                appendToolResult(call: call, content: execution.message, disposition: .completed)
                let message = GuideConversationMessage(role: .tool, content: execution.message)
                messages.append(message)
                latestTurnMessageIDs.insert(message.id)
                scheduleHistorySave()
                await runResponseLoop(taskID: taskID)
            } catch is CancellationError {
                guard activeTaskID == taskID else { return }
                isResponding = false
                activeTaskID = nil
                currentTask = nil
            } catch {
                finishWithError(error, taskID: taskID)
            }
        }
    }

    public func rejectPendingProposal() {
        guard let call = pendingToolCall, !isResponding else { return }
        pendingProposal = nil
        pendingToolCall = nil
        let message = NSLocalizedString("用户没有应用这项修改。", comment: "Guide proposal rejected tool result")
        appendToolResult(call: call, content: message, disposition: .rejected)
        let toolMessage = GuideConversationMessage(role: .tool, content: message)
        messages.append(toolMessage)
        latestTurnMessageIDs.insert(toolMessage.id)
        scheduleHistorySave()
        startResponseLoop()
    }

    public func undoLastChange() {
        guard let undoProposal,
              !isResponding,
              pendingProposal == nil,
              !isAwaitingToolContinuation else { return }
        isResponding = true
        let taskID = UUID()
        activeTaskID = taskID
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await contextCoordinator.execute(undoProposal)
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                self.undoProposal = nil
                canUndo = false
                messages.append(GuideConversationMessage(role: .tool, content: execution.message))
                scheduleHistorySave()
                isResponding = false
                activeTaskID = nil
                currentTask = nil
            } catch is CancellationError {
                guard activeTaskID == taskID else { return }
                isResponding = false
                activeTaskID = nil
                currentTask = nil
            } catch {
                finishWithError(error, taskID: taskID)
            }
        }
    }

    public func continueToolCalls() {
        guard isAwaitingToolContinuation, !isResponding, pendingProposal == nil else { return }
        isAwaitingToolContinuation = false
        startResponseLoop()
    }

    public func finishToolCalls() {
        guard isAwaitingToolContinuation, !isResponding else { return }
        isAwaitingToolContinuation = false
        compactRequestHistoryAfterCompletedTurn()
        scheduleHistorySave()
    }

    private func startResponseLoop() {
        isAwaitingToolContinuation = false
        isResponding = true
        resetStreamingContent()
        let taskID = UUID()
        activeTaskID = taskID
        currentTask = Task { [weak self] in
            await self?.runResponseLoop(taskID: taskID)
        }
    }

    private func prepareLatestUserTurn(messageID: UUID, replacementContent: String?) -> Bool {
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID && $0.role == .user }),
              messages.lastIndex(where: { $0.role == .user }) == messageIndex,
              let historyIndex = requestHistory.lastIndex(where: { $0.role == .user }) else {
            return false
        }

        if let replacementContent {
            messages[messageIndex].content = replacementContent
            requestHistory[historyIndex] = ChatMessage(role: .user, content: replacementContent)
        }
        messages.removeSubrange((messageIndex + 1)..<messages.endIndex)
        requestHistory.removeSubrange((historyIndex + 1)..<requestHistory.endIndex)
        discardToolBatch()
        isAwaitingToolContinuation = false
        lastError = nil
        lastErrorMessageID = nil
        canRetryWithBuiltIn = false
        latestTurnMessageIDs = [messageID]
        scheduleHistorySave()
        return true
    }

    private func runResponseLoop(taskID: UUID) async {
        do {
            guard activeTaskID == taskID else { return }
            // 确认或拒绝提案后，先补齐同一条 assistant 消息的全部工具结果。
            // 提前请求模型会留下悬空的 tool_call_id，并让兼容接口拒绝整轮请求。
            guard try await processRemainingToolCalls(taskID: taskID) else { return }
            let resolved = try router.resolvedClient()
            for _ in 0..<8 {
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                let context = try await contextCoordinator.currentContext()
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                let tools = (
                    GuideToolCatalog.availableKnowledgeDefinitions(
                        commitSHA: GuideBuildVersion.fullCommitSHA()
                    ) + context.descriptor.tools.map(\.definition)
                ).filter { !unavailableReadTools.contains($0.name) }
                let outbound = GuidePromptBuilder.requestMessages(
                    history: requestHistory,
                    context: context,
                    includesClientSystemPrompt: resolved.includesClientSystemPrompt
                )
                let placeholderID = UUID()
                messages.append(GuideConversationMessage(id: placeholderID, role: .assistant, content: ""))
                latestTurnMessageIDs.insert(placeholderID)
                beginStreaming(messageID: placeholderID)

                var completedMessage: ChatMessage?
                var bufferedDelta = ""
                let updateClock = ContinuousClock()
                var lastPublishedAt: ContinuousClock.Instant?
                for try await event in resolved.client.events(messages: outbound, tools: tools, sessionID: sessionID) {
                    try Task.checkCancellation()
                    guard activeTaskID == taskID else { return }
                    switch event {
                    case .contentDelta(let delta):
                        bufferedDelta.append(contentsOf: delta)
                        let now = updateClock.now
                        let shouldPublish = lastPublishedAt == nil
                            || (lastPublishedAt?.duration(to: now) ?? .zero) >= .milliseconds(120)
                        if shouldPublish {
                            publishStreamingContent(bufferedDelta, messageID: placeholderID)
                            bufferedDelta.removeAll(keepingCapacity: true)
                            lastPublishedAt = now
                        }
                    case .completed(let message):
                        completedMessage = message
                    }
                }
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return }
                if completedMessage == nil, !bufferedDelta.isEmpty {
                    publishStreamingContent(bufferedDelta, messageID: placeholderID)
                }
                guard let response = completedMessage else { throw GuideError.invalidResponse }
                if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                    messages[index] = GuideConversationMessage(
                        id: placeholderID,
                        role: .assistant,
                        content: response.content,
                        toolCalls: response.toolCalls ?? []
                    )
                }
                resetStreamingContent(messageID: placeholderID)
                requestHistory.append(response)
                scheduleHistorySave()

                let calls = response.toolCalls ?? []
                if calls.isEmpty {
                    removeEmptyAssistantMessage(id: placeholderID)
                    compactRequestHistoryAfterCompletedTurn()
                    isResponding = false
                    activeTaskID = nil
                    currentTask = nil
                    return
                }

                remainingToolCalls = calls[...]
                toolBatchPage = context.descriptor
                guard try await processRemainingToolCalls(taskID: taskID) else { return }
                removeEmptyAssistantMessage(id: placeholderID)
            }
            isAwaitingToolContinuation = true
            isResponding = false
            activeTaskID = nil
            currentTask = nil
        } catch is CancellationError {
            guard activeTaskID == taskID else { return }
            commitStreamingContent()
            removeEmptyAssistantMessages()
            isResponding = false
            activeTaskID = nil
            currentTask = nil
        } catch {
            finishWithError(error, taskID: taskID)
        }
    }

    private func processRemainingToolCalls(taskID: UUID) async throws -> Bool {
        while let call = remainingToolCalls.popFirst() {
            try Task.checkCancellation()
            guard activeTaskID == taskID else { return false }
            let pageTool = toolBatchPage?.tools.first { $0.definition.name == call.toolName }
            do {
                // 同名工具可能出现在多个设置页，不能把上一页排队的修改应用到新页面。
                if pageTool != nil {
                    let current = try await contextCoordinator.currentContext()
                    try Task.checkCancellation()
                    guard activeTaskID == taskID else { return false }
                    guard current.descriptor.id == toolBatchPage?.id else { throw GuideError.pageChanged }
                }
                if pageTool?.access == .proposeChange {
                    let proposal = try await contextCoordinator.makeProposal(for: call)
                    try Task.checkCancellation()
                    guard activeTaskID == taskID else { return false }
                    guard proposal.pageID == toolBatchPage?.id else { throw GuideError.pageChanged }
                    pendingProposal = proposal
                    pendingToolCall = call
                    scheduleHistorySave()
                    isResponding = false
                    activeTaskID = nil
                    currentTask = nil
                    return false
                }
                let result = try await executeReadTool(call)
                try Task.checkCancellation()
                guard activeTaskID == taskID else { return false }
                appendToolResult(call: call, content: result, disposition: .completed)
            } catch {
                if error is CancellationError { throw error }
                guard activeTaskID == taskID else { return false }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                appendToolResult(call: call, content: message, disposition: .failed)
                if pageTool?.access != .proposeChange {
                    unavailableReadTools.insert(call.toolName)
                }
            }
        }
        toolBatchPage = nil
        return true
    }

    private func discardToolBatch() {
        pendingProposal = nil
        pendingToolCall = nil
        remainingToolCalls = []
        toolBatchPage = nil
        unavailableReadTools.removeAll()
    }

    private func executeReadTool(_ call: InternalToolCall) async throws -> String {
        let arguments = try GuideToolArguments.decode(call.arguments)
        switch call.toolName {
        case GuideToolCatalog.currentPageContext.name:
            return try encoded(await contextCoordinator.currentContext())
        case GuideToolCatalog.searchDocuments.name:
            let query = try GuideToolArguments.string("query", in: arguments)
            return try encoded(await knowledgeService.search(query))
        case GuideToolCatalog.readDocument.name:
            let id = try GuideToolArguments.string("id", in: arguments)
            guard let document = await knowledgeService.document(id: id) else {
                throw GuideError.invalidToolArguments
            }
            return try encoded(document)
        case GuideToolCatalog.listProviderTemplates.name:
            return try encoded(GuideProviderTemplate.cloudTemplates)
        case GuideToolCatalog.readProviderTemplate.name:
            let id = try GuideToolArguments.string("id", in: arguments)
            guard let template = GuideProviderTemplate.cloudTemplates.first(where: { $0.id == id }) else {
                throw GuideError.invalidToolArguments
            }
            return try encoded(template)
        case GuideToolCatalog.searchSourceTree.name:
            let query = try GuideToolArguments.string("query", in: arguments)
            guard let sha = GuideBuildVersion.fullCommitSHA() else { throw GuideError.sourceUnavailable }
            return try encoded(try await sourceService.searchTree(query: query, commitSHA: sha))
        case GuideToolCatalog.searchSourceCode.name:
            let query = try GuideToolArguments.string("query", in: arguments)
            let pathPrefix = try GuideToolArguments.optionalString("path_prefix", in: arguments)
            guard let sha = GuideBuildVersion.fullCommitSHA() else { throw GuideError.sourceUnavailable }
            return try encoded(try await sourceService.searchSourceCode(
                query: query,
                pathPrefix: pathPrefix,
                commitSHA: sha
            ))
        case GuideToolCatalog.listSourceDirectory.name:
            let path = try GuideToolArguments.string("path", in: arguments)
            guard let sha = GuideBuildVersion.fullCommitSHA() else { throw GuideError.sourceUnavailable }
            return try encoded(try await sourceService.listDirectory(path: path, commitSHA: sha))
        case GuideToolCatalog.readSourceFile.name:
            let path = try GuideToolArguments.string("path", in: arguments)
            let start = try GuideToolArguments.integer("start_line", in: arguments)
            let end = try GuideToolArguments.integer("end_line", in: arguments)
            guard let sha = GuideBuildVersion.fullCommitSHA() else { throw GuideError.sourceUnavailable }
            return try encoded(try await sourceService.readSource(
                path: path,
                startLine: start,
                endLine: end,
                commitSHA: sha
            ))
        default:
            return try await contextCoordinator.executeReadTool(call)
        }
    }

    private func appendToolResult(
        call: InternalToolCall,
        content: String,
        disposition: InternalToolCallResultDisposition
    ) {
        var resolvedCall = call
        resolvedCall.result = content
        resolvedCall.resultDisposition = disposition
        requestHistory.append(ChatMessage(
            role: .tool,
            content: content,
            toolCalls: [resolvedCall]
        ))
        updateVisibleToolCall(resolvedCall)
        scheduleHistorySave()
    }

    private func updateVisibleToolCall(_ resolvedCall: InternalToolCall) {
        guard let messageIndex = messages.lastIndex(where: { message in
            message.toolCalls.contains { $0.id == resolvedCall.id }
        }),
        let callIndex = messages[messageIndex].toolCalls.firstIndex(where: { $0.id == resolvedCall.id }) else {
            return
        }

        var visibleCalls = messages[messageIndex].toolCalls
        var visibleCall = resolvedCall
        // 工具结果可能包含大段文档或源码；可见消息只保留终态，原文仅保留到本轮回答完成。
        visibleCall.result = nil
        visibleCalls[callIndex] = visibleCall
        let message = messages[messageIndex]
        messages[messageIndex] = GuideConversationMessage(
            id: message.id,
            role: message.role,
            content: message.content,
            toolCalls: visibleCalls
        )
    }

    private func removeEmptyAssistantMessage(id: UUID) {
        messages.removeAll {
            $0.id == id && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.toolCalls.isEmpty
        }
        if !messages.contains(where: { $0.id == id }) {
            latestTurnMessageIDs.remove(id)
        }
    }

    private func finishWithError(_ error: Error, taskID: UUID) {
        guard activeTaskID == taskID else { return }
        discardToolBatch()
        commitStreamingContent()
        removeEmptyAssistantMessages()
        compactRequestHistoryAfterCompletedTurn()
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        canRetryWithBuiltIn = router.route == .userModel
        let errorMessage = GuideConversationMessage(role: .error, content: message)
        messages.append(errorMessage)
        lastErrorMessageID = errorMessage.id
        latestTurnMessageIDs.insert(errorMessage.id)
        scheduleHistorySave()
        isResponding = false
        isAwaitingToolContinuation = false
        activeTaskID = nil
        currentTask = nil
    }

    private func beginStreaming(messageID: UUID) {
        streamingState.begin(messageID: messageID)
    }

    private func publishStreamingContent(_ content: String, messageID: UUID) {
        streamingState.append(content, messageID: messageID)
    }

    /// 停止或失败时保留用户已经看到的部分回答；正常完成则由协议终态一次性写入最终消息。
    private func commitStreamingContent() {
        guard let messageID = streamingMessageID else { return }
        if !streamingContent.isEmpty,
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            let message = messages[index]
            messages[index] = GuideConversationMessage(
                id: message.id,
                role: message.role,
                content: streamingContent,
                toolCalls: message.toolCalls
            )
            requestHistory.append(ChatMessage(role: .assistant, content: streamingContent))
        }
        resetStreamingContent(messageID: messageID)
    }

    private func resetStreamingContent(messageID: UUID? = nil) {
        streamingState.reset(messageID: messageID)
    }

    public func restoreHistory() async {
        await historyRestoreTask?.value
    }

    /// 后台切换时可额外保存已显示的流式片段，不打断正在生成的请求。
    public func persistHistory() async {
        await restoreHistory()
        scheduleHistorySave()
        await historyWriteTask?.value
    }

    private func scheduleHistorySave() {
        guard let historyStore, !isRestoringHistory else { return }
        let snapshot = GuideConversationHistorySnapshot(
            messages: messages, requestHistory: requestHistory,
            streamingMessageID: streamingMessageID, streamingContent: streamingContent,
            latestUserMessageID: latestUserMessageID,
            latestUserMessageAllowsEditing: latestUserMessageAllowsEditing
        )
        let previousWrite = historyWriteTask
        // 按事件顺序落盘；清空必须排在旧写入之后，不能被迟到的保存覆盖。
        historyWriteTask = Task {
            await previousWrite?.value
            await historyStore.save(snapshot)
        }
    }

    /// 工具原文只服务于本轮推理；最终回答形成后保留它只会让下一问重复携带源码和隐藏思考。
    private func compactRequestHistoryAfterCompletedTurn() {
        unavailableReadTools.removeAll()
        requestHistory.removeAll { message in
            message.role == .tool || (message.role == .assistant && !(message.toolCalls ?? []).isEmpty)
        }
        for index in requestHistory.indices where requestHistory[index].role == .assistant {
            requestHistory[index].reasoningContent = nil
            requestHistory[index].reasoningProviderSpecificFields = nil
            requestHistory[index].providerResponseMetadata = nil
        }
    }

    private func removeEmptyAssistantMessages() {
        let removedIDs = Set(messages.compactMap { message in
            message.role == .assistant
                && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && message.toolCalls.isEmpty
                ? message.id
                : nil
        })
        messages.removeAll {
            $0.role == .assistant
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.toolCalls.isEmpty
        }
        latestTurnMessageIDs.subtract(removedIDs)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else { throw GuideError.invalidResponse }
        return string
    }
}

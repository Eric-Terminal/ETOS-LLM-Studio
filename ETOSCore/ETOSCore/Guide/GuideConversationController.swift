// ============================================================================
// GuideConversationController.swift
// ============================================================================
// ETOS LLM Studio
//
// 向导会话完全驻留内存。读取工具可自动执行，写入工具必须停在原生确认预览。
// ============================================================================

import Foundation
import Combine

@MainActor
public final class GuideConversationController: ObservableObject {
    @Published public private(set) var messages: [GuideConversationMessage] = []
    @Published public private(set) var isResponding = false
    @Published public private(set) var pendingProposal: GuideActionProposal?
    @Published public private(set) var canUndo = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastErrorMessageID: UUID?
    @Published public private(set) var canRetryWithBuiltIn = false
    @Published public private(set) var isAwaitingToolContinuation = false

    public let sessionID: UUID
    public let router: GuideModelRouter

    private let contextCoordinator: GuideContextCoordinator
    private let knowledgeService: GuideKnowledgeService
    private let sourceService: GuideSourceService
    private var requestHistory: [ChatMessage] = []
    private var currentTask: Task<Void, Never>?
    private var pendingToolCall: InternalToolCall?
    private var undoProposal: GuideActionProposal?
    private var latestUserMessageID: UUID?
    private var latestUserMessageAllowsEditing = false
    private var latestTurnMessageIDs: Set<UUID> = []

    public init(
        sessionID: UUID = UUID(),
        router: GuideModelRouter? = nil,
        contextCoordinator: GuideContextCoordinator? = nil,
        knowledgeService: GuideKnowledgeService = .shared,
        sourceService: GuideSourceService = .shared
    ) {
        self.sessionID = sessionID
        self.router = router ?? GuideModelRouter()
        self.contextCoordinator = contextCoordinator ?? .shared
        self.knowledgeService = knowledgeService
        self.sourceService = sourceService
    }

    deinit {
        currentTask?.cancel()
    }

    public func send(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
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
        startResponseLoop()
    }

    public func sendSetupChoice(_ choice: GuideModelSetupChoice, displayName: String) {
        guard !isResponding, pendingProposal == nil, !isAwaitingToolContinuation else { return }
        lastError = nil
        lastErrorMessageID = nil
        canRetryWithBuiltIn = false
        let message = GuideConversationMessage(role: .user, content: displayName)
        messages.append(message)
        requestHistory.append(ChatMessage(
            role: .user,
            content: "<guide_setup_choice version=\"1\">{\"choice\":\"(choice.rawValue)\"}</guide_setup_choice>"
        ))
        latestUserMessageID = message.id
        latestUserMessageAllowsEditing = false
        latestTurnMessageIDs = [message.id]
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
        currentTask?.cancel()
        currentTask = nil
        removeEmptyAssistantMessages()
        isResponding = false
        isAwaitingToolContinuation = false
    }

    public func clear() {
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
    }

    public func confirmPendingProposal() {
        guard let proposal = pendingProposal, let call = pendingToolCall, !isResponding else { return }
        pendingProposal = nil
        pendingToolCall = nil
        isResponding = true
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await contextCoordinator.execute(proposal)
                undoProposal = execution.undoProposal
                canUndo = execution.undoProposal != nil
                appendToolResult(call: call, content: execution.message, disposition: .completed)
                let message = GuideConversationMessage(role: .tool, content: execution.message)
                messages.append(message)
                latestTurnMessageIDs.insert(message.id)
                await runResponseLoop()
            } catch is CancellationError {
                isResponding = false
            } catch {
                finishWithError(error)
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
        startResponseLoop()
    }

    public func undoLastChange() {
        guard let undoProposal,
              !isResponding,
              pendingProposal == nil,
              !isAwaitingToolContinuation else { return }
        isResponding = true
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let execution = try await contextCoordinator.execute(undoProposal)
                self.undoProposal = nil
                canUndo = false
                messages.append(GuideConversationMessage(role: .tool, content: execution.message))
                isResponding = false
            } catch is CancellationError {
                isResponding = false
            } catch {
                finishWithError(error)
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
    }

    private func startResponseLoop() {
        isAwaitingToolContinuation = false
        isResponding = true
        currentTask = Task { [weak self] in
            await self?.runResponseLoop()
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
        pendingToolCall = nil
        isAwaitingToolContinuation = false
        lastError = nil
        lastErrorMessageID = nil
        canRetryWithBuiltIn = false
        latestTurnMessageIDs = [messageID]
        return true
    }

    private func runResponseLoop() async {
        do {
            let resolved = try router.resolvedClient()
            for _ in 0..<8 {
                try Task.checkCancellation()
                let context = try await contextCoordinator.currentContext()
                let tools = GuideToolCatalog.knowledgeDefinitions + context.descriptor.tools.map(\.definition)
                let outbound = GuidePromptBuilder.requestMessages(
                    history: requestHistory,
                    context: context,
                    includesClientSystemPrompt: resolved.includesClientSystemPrompt
                )
                let placeholderID = UUID()
                messages.append(GuideConversationMessage(id: placeholderID, role: .assistant, content: ""))
                latestTurnMessageIDs.insert(placeholderID)

                var completedMessage: ChatMessage?
                for try await event in resolved.client.events(messages: outbound, tools: tools, sessionID: sessionID) {
                    switch event {
                    case .contentDelta(let delta):
                        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                            messages[index].content += delta
                        }
                    case .completed(let message):
                        completedMessage = message
                    }
                }
                guard let response = completedMessage else { throw GuideError.invalidResponse }
                if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                    messages[index].content = response.content
                    messages[index] = GuideConversationMessage(
                        id: placeholderID,
                        role: .assistant,
                        content: response.content,
                        toolCalls: response.toolCalls ?? []
                    )
                }
                requestHistory.append(response)

                let calls = response.toolCalls ?? []
                if calls.isEmpty {
                    removeEmptyAssistantMessage(id: placeholderID)
                    isResponding = false
                    currentTask = nil
                    return
                }

                for call in calls {
                    if isProposalTool(call.toolName, context: context) {
                        pendingProposal = try await contextCoordinator.makeProposal(for: call)
                        pendingToolCall = call
                        removeEmptyAssistantMessage(id: placeholderID)
                        isResponding = false
                        currentTask = nil
                        return
                    }
                    do {
                        let result = try await executeReadTool(call)
                        appendToolResult(call: call, content: result, disposition: .completed)
                    } catch {
                        // 知识检索失败属于一次工具结果，交还模型改用文档或换关键词，不能终止整段向导会话。
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        appendToolResult(call: call, content: message, disposition: .failed)
                    }
                }
                removeEmptyAssistantMessage(id: placeholderID)
            }
            isAwaitingToolContinuation = true
            isResponding = false
            currentTask = nil
        } catch is CancellationError {
            removeEmptyAssistantMessages()
            isResponding = false
            currentTask = nil
        } catch {
            finishWithError(error)
        }
    }

    private func isProposalTool(_ name: String, context: GuidePageContext) -> Bool {
        context.descriptor.tools.contains { $0.access == .proposeChange && $0.definition.name == name }
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
        case GuideToolCatalog.listSourceDirectory.name:
            let path = try GuideToolArguments.string("path", in: arguments)
            guard let sha = GuideBuildVersion.fullCommitSHA() else { throw GuideError.sourceUnavailable }
            return try encoded(try await sourceService.listDirectory(path: path, commitSHA: sha))
        case GuideToolCatalog.readSourceFile.name:
            let path = try GuideToolArguments.string("path", in: arguments)
            let start = try GuideToolArguments.integer("start_line", in: arguments)
            let end = try GuideToolArguments.integer("end_line", in: arguments)
            guard let sha = GuideBuildVersion.fullCommitSHA() else { throw GuideError.sourceUnavailable }
            return try await sourceService.readSource(path: path, startLine: start, endLine: end, commitSHA: sha)
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
    }

    private func removeEmptyAssistantMessage(id: UUID) {
        messages.removeAll {
            $0.id == id && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.toolCalls.isEmpty
        }
        if !messages.contains(where: { $0.id == id }) {
            latestTurnMessageIDs.remove(id)
        }
    }

    private func finishWithError(_ error: Error) {
        removeEmptyAssistantMessages()
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        canRetryWithBuiltIn = router.route == .userModel
        let errorMessage = GuideConversationMessage(role: .error, content: message)
        messages.append(errorMessage)
        lastErrorMessageID = errorMessage.id
        latestTurnMessageIDs.insert(errorMessage.id)
        isResponding = false
        isAwaitingToolContinuation = false
        currentTask = nil
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

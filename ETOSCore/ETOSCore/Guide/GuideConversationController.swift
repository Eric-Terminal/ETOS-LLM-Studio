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
    @Published public private(set) var canRetryWithBuiltIn = false

    public let sessionID: UUID
    public let router: GuideModelRouter

    private let contextCoordinator: GuideContextCoordinator
    private let knowledgeService: GuideKnowledgeService
    private let sourceService: GuideSourceService
    private var requestHistory: [ChatMessage] = []
    private var currentTask: Task<Void, Never>?
    private var pendingToolCall: InternalToolCall?
    private var undoProposal: GuideActionProposal?

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
        guard !trimmed.isEmpty, !isResponding, pendingProposal == nil else { return }
        lastError = nil
        canRetryWithBuiltIn = false
        messages.append(GuideConversationMessage(role: .user, content: trimmed))
        requestHistory.append(ChatMessage(role: .user, content: trimmed))
        startResponseLoop()
    }

    public func sendSetupChoice(_ choice: GuideModelSetupChoice, displayName: String) {
        guard !isResponding, pendingProposal == nil else { return }
        lastError = nil
        canRetryWithBuiltIn = false
        messages.append(GuideConversationMessage(role: .user, content: displayName))
        requestHistory.append(ChatMessage(
            role: .user,
            content: "<guide_setup_choice version=\"1\">{\"choice\":\"(choice.rawValue)\"}</guide_setup_choice>"
        ))
        startResponseLoop()
    }

    public func retryLastResponse() {
        guard !isResponding, pendingProposal == nil,
              requestHistory.last(where: { $0.role == .user }) != nil else { return }
        messages.removeAll { $0.role == .error }
        lastError = nil
        canRetryWithBuiltIn = false
        startResponseLoop()
    }

    public func retryWithBuiltIn() {
        router.useBuiltIn()
        retryLastResponse()
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isResponding = false
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
        canRetryWithBuiltIn = false
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
                messages.append(GuideConversationMessage(role: .tool, content: execution.message))
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
        messages.append(GuideConversationMessage(role: .tool, content: message))
        startResponseLoop()
    }

    public func undoLastChange() {
        guard let undoProposal, !isResponding, pendingProposal == nil else { return }
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

    private func startResponseLoop() {
        isResponding = true
        currentTask = Task { [weak self] in
            await self?.runResponseLoop()
        }
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
            throw NSError(
                domain: "GuideConversation",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("向导连续调用工具次数过多，请清空上下文后换一种问法。", comment: "Guide tool loop limit")]
            )
        } catch is CancellationError {
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
            throw GuideError.unsupportedTool(call.toolName)
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
    }

    private func finishWithError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        canRetryWithBuiltIn = router.route == .userModel
        messages.append(GuideConversationMessage(role: .error, content: message))
        isResponding = false
        currentTask = nil
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else { throw GuideError.invalidResponse }
        return string
    }
}

// ============================================================================
// ChatService.swift
// ============================================================================ 
// ETOS LLM Studio
//
// 本类作为应用的中央大脑，处理所有与平台无关的业务逻辑。
// 它被设计为单例，以便在应用的不同部分（iOS 和 watchOS）之间共享。
// ============================================================================ 

import Foundation
import Combine
import os.log

/// 一个组合了 Provider 和 Model 的可运行实体，包含了发起 API 请求所需的所有信息。
public struct RunnableModel: Identifiable, Hashable {
    public var id: String { "\(provider.id.uuidString)-\(model.id.uuidString)" }
    public let provider: Provider
    public let model: Model
}

public class ChatService {
    
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatService")

    // MARK: - 单例
    public static let shared = ChatService()

    // MARK: - 用于 UI 订阅的公开 Subjects
    
    public let chatSessionsSubject: CurrentValueSubject<[ChatSession], Never>
    public let currentSessionSubject: CurrentValueSubject<ChatSession?, Never>
    public let messagesForSessionSubject: CurrentValueSubject<[ChatMessage], Never>
    
    public let providersSubject: CurrentValueSubject<[Provider], Never>
    public let selectedModelSubject: CurrentValueSubject<RunnableModel?, Never>

    public let requestStatusSubject = PassthroughSubject<RequestStatus, Never>()
    
    public enum RequestStatus {
        case started
        case finished
        case error
    }

    // MARK: - 私有状态
    
    private var cancellables = Set<AnyCancellable>()
    private var providers: [Provider]
    private let adapters: [String: APIAdapter]
    private let memoryManager: MemoryManager
    private let urlSession: URLSession

    // MARK: - 计算属性
    
    public var activatedRunnableModels: [RunnableModel] {
        var models: [RunnableModel] = []
        for provider in providers {
            for model in provider.models where model.isActivated {
                models.append(RunnableModel(provider: provider, model: model))
            }
        }
        return models
    }

    // MARK: - 初始化
    
    public init(adapters: [String: APIAdapter]? = nil, memoryManager: MemoryManager = .shared, urlSession: URLSession = .shared) {
        logger.info("🚀 ChatService 正在初始化 (v2.1 重构版)...")
        
        self.memoryManager = memoryManager
        self.urlSession = urlSession
        ConfigLoader.setupInitialProviderConfigs()
        ConfigLoader.setupBackgroundsDirectory()
        self.providers = ConfigLoader.loadProviders()
        self.adapters = adapters ?? [
            "openai-compatible": OpenAIAdapter()
            // 在这里可以添加新的 Adapter, 例如: "google-gemini": GoogleAdapter()
        ]
        
        var loadedSessions = Persistence.loadChatSessions()
        let newTemporarySession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
        loadedSessions.insert(newTemporarySession, at: 0)
        
        self.providersSubject = CurrentValueSubject(self.providers)
        self.selectedModelSubject = CurrentValueSubject(nil)
        self.chatSessionsSubject = CurrentValueSubject(loadedSessions)
        self.currentSessionSubject = CurrentValueSubject(newTemporarySession)
        self.messagesForSessionSubject = CurrentValueSubject([])
        
        let savedModelID = UserDefaults.standard.string(forKey: "selectedRunnableModelID")
        let allRunnable = activatedRunnableModels
        var initialModel: RunnableModel? = allRunnable.first { $0.id == savedModelID }
        if initialModel == nil {
            initialModel = allRunnable.first
        }
        self.selectedModelSubject.send(initialModel)
        
        logger.info("  - 初始选中模型为: \(initialModel?.model.displayName ?? "无")")
        logger.info("  - 初始化完成。")
    }
    
    // MARK: - 公开方法 (配置管理)

    public func reloadProviders() {
        logger.info("🔄 正在重新加载提供商配置...")
        let currentSelectedID = selectedModelSubject.value?.id // 1. 记住当前选中模型的 ID

        self.providers = ConfigLoader.loadProviders() // 2. 从磁盘重载
        providersSubject.send(self.providers)

        let allRunnable = activatedRunnableModels // 3. 获取新的模型列表

        var newSelectedModel: RunnableModel? = nil
        if let currentID = currentSelectedID {
            // 4. 在新列表中找到对应的模型
            newSelectedModel = allRunnable.first { $0.id == currentID }
        }

        // 如果找不到（比如被删了或停用了），就用列表里第一个
        if newSelectedModel == nil {
            newSelectedModel = allRunnable.first
        }

        // 5. **关键**: 用新的模型对象强制更新当前选中的模型
        selectedModelSubject.send(newSelectedModel)
        // (我们直接操作 subject, 以绕过 setSelectedModel 里的“无变化则不更新”的检查)
        
        logger.info("✅ 提供商配置已刷新，并已更新当前选中模型。")
    }

    public func setSelectedModel(_ model: RunnableModel?) {
        guard selectedModelSubject.value?.id != model?.id else { return }
        selectedModelSubject.send(model)
        UserDefaults.standard.set(model?.id, forKey: "selectedRunnableModelID")
        logger.info("⚙️ 已将模型切换为: \(model?.model.displayName ?? "无")")
    }
    
    public func fetchModels(for provider: Provider) async throws -> [Model] {
        logger.info("☁️ 正在为提供商 '\(provider.name)' 获取云端模型列表...")
        guard let adapter = adapters[provider.apiFormat] else {
            throw NetworkError.adapterNotFound(format: provider.apiFormat)
        }
        
        guard let request = adapter.buildModelListRequest(for: provider) else {
            throw NetworkError.requestBuildFailed(provider: provider.name)
        }
        
        do {
            let data = try await fetchData(for: request)
            // 注意: ModelListResponse 需要在某个地方定义，或者让 Adapter 直接返回 [Model]
            let modelResponse = try JSONDecoder().decode(ModelListResponse.self, from: data)
            let fetchedModels = modelResponse.data.map { Model(modelName: $0.id) }
            logger.info("  - ✅ 成功获取并解析了 \(fetchedModels.count) 个模型。")
            return fetchedModels
        } catch {
            logger.error("  - ❌ 获取或解析模型列表失败: \(error.localizedDescription)")
            throw error
        }
    }
    
    public func saveAndReloadProviders(from providers: [Provider]) {
        logger.info("💾 正在保存并重载提供商配置...")
        self.providers = providers
        for provider in self.providers {
            ConfigLoader.saveProvider(provider)
        }
        self.reloadProviders()
    }

    // MARK: - 公开方法 (会话管理)
    
    public func createNewSession() {
        let newSession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        currentSessionSubject.send(newSession)
        messagesForSessionSubject.send([])
        logger.info("✨ 创建了新的临时会话。" )
    }
    
    public func deleteSessions(_ sessionsToDelete: [ChatSession]) {
        var currentSessions = chatSessionsSubject.value
        for session in sessionsToDelete {
            let fileURL = Persistence.getChatsDirectory().appendingPathComponent("\(session.id.uuidString).json")
            try? FileManager.default.removeItem(at: fileURL)
            logger.info("🗑️ 删除了会话的消息文件: \(session.name)")
        }
        currentSessions.removeAll { session in sessionsToDelete.contains { $0.id == session.id } }
        var newCurrentSession = currentSessionSubject.value
        if let current = newCurrentSession, sessionsToDelete.contains(where: { $0.id == current.id }) {
            if let firstSession = currentSessions.first {
                newCurrentSession = firstSession
            } else {
                let newSession = ChatSession(id: UUID(), name: "新的对话", isTemporary: true)
                currentSessions.append(newSession)
                newCurrentSession = newSession
            }
        }
        chatSessionsSubject.send(currentSessions)
        if newCurrentSession?.id != currentSessionSubject.value?.id {
            setCurrentSession(newCurrentSession)
        }
        Persistence.saveChatSessions(currentSessions)
        logger.info("💾 删除后已保存会话列表。" )
    }
    
    public func branchSession(from sourceSession: ChatSession, copyMessages: Bool) {
        let newSession = ChatSession(id: UUID(), name: "分支: \(sourceSession.name)", topicPrompt: sourceSession.topicPrompt, enhancedPrompt: sourceSession.enhancedPrompt, isTemporary: false)
        logger.info("🌿 创建了分支会话: \(newSession.name)")
        if copyMessages {
            let sourceMessages = Persistence.loadMessages(for: sourceSession.id)
            if !sourceMessages.isEmpty {
                Persistence.saveMessages(sourceMessages, for: newSession.id)
                logger.info("  - 复制了 \(sourceMessages.count) 条消息到新会话。" )
            }
        }
        var updatedSessions = chatSessionsSubject.value
        updatedSessions.insert(newSession, at: 0)
        chatSessionsSubject.send(updatedSessions)
        setCurrentSession(newSession)
        Persistence.saveChatSessions(updatedSessions)
        logger.info("💾 保存了会话列表。" )
    }
    
    public func deleteLastMessage(for session: ChatSession) {
        var messages = Persistence.loadMessages(for: session.id)
        if !messages.isEmpty {
            messages.removeLast()
            Persistence.saveMessages(messages, for: session.id)
            logger.info("🗑️ 删除了会话的最后一条消息: \(session.name)")
            if session.id == currentSessionSubject.value?.id {
                messagesForSessionSubject.send(messages)
            }
        }
    }
    
    public func updateMessageContent(_ message: ChatMessage, with newContent: String) {
        guard let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].content = newContent
        messagesForSessionSubject.send(messages)
        Persistence.saveMessages(messages, for: currentSession.id)
        logger.info("✏️ 已更新消息内容: \(message.id.uuidString)")
    }
    
    public func updateSession(_ session: ChatSession) {
        guard !session.isTemporary else { return }
        var currentSessions = chatSessionsSubject.value
        if let index = currentSessions.firstIndex(where: { $0.id == session.id }) {
            currentSessions[index] = session
            chatSessionsSubject.send(currentSessions)
            Persistence.saveChatSessions(currentSessions)
            logger.info("💾 更新了会话详情: \(session.name)")
        }
    }
    
    public func forceSaveSessions() {
        let sessions = chatSessionsSubject.value
        Persistence.saveChatSessions(sessions)
        logger.info("💾 已强制保存所有会话。" )
    }
    
    public func setCurrentSession(_ session: ChatSession?) {
        if session?.id == currentSessionSubject.value?.id { return }
        currentSessionSubject.send(session)
        let messages = session != nil ? Persistence.loadMessages(for: session!.id) : []
        messagesForSessionSubject.send(messages)
        logger.info("🔄 已切换到会话: \(session?.name ?? "无")")
    }
    
    // MARK: - 公开方法 (消息处理)
    
    public func addErrorMessage(_ content: String) {
        guard let currentSession = currentSessionSubject.value else { return }
        var messages = messagesForSessionSubject.value
        // 找到并替换正在加载中的消息，或者直接添加新错误消息
        if let loadingIndex = messages.lastIndex(where: { $0.role == .assistant && $0.content.isEmpty }) {
            messages[loadingIndex] = ChatMessage(id: messages[loadingIndex].id, role: .error, content: content)
        } else {
            messages.append(ChatMessage(id: UUID(), role: .error, content: content))
        }
        messagesForSessionSubject.send(messages)
        Persistence.saveMessages(messages, for: currentSession.id)
        logger.error("❌ 错误消息已添加: \(content)")
    }
        
    public func sendAndProcessMessage(
        content: String,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        enableMemory: Bool
    ) async {
        guard var currentSession = currentSessionSubject.value else {
            addErrorMessage("错误: 没有当前会话。" )
            requestStatusSubject.send(.error)
            return
        }

        // 准备用户消息和UI占位消息
        let userMessage = ChatMessage(role: .user, content: content)
        let loadingMessage = ChatMessage(role: .assistant, content: "") // 内容为空的助手消息作为加载占位符
        var wasTemporarySession = false
        
        var messages = messagesForSessionSubject.value
        messages.append(userMessage)
        messages.append(loadingMessage)
        messagesForSessionSubject.send(messages)
        
        // 处理临时会话的转换
        if currentSession.isTemporary {
            wasTemporarySession = true // 标记此为首次交互
            currentSession.name = String(userMessage.content.prefix(20))
            currentSession.isTemporary = false
            currentSessionSubject.send(currentSession)
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) { updatedSessions[index] = currentSession }
            chatSessionsSubject.send(updatedSessions)
            Persistence.saveChatSessions(updatedSessions)
            logger.info("✨ 临时会话已转为永久会话: \(currentSession.name)")
        }
        
        Persistence.saveMessages(messages, for: currentSession.id)
        requestStatusSubject.send(.started)
        
        // 初始调用，传入 saveMemoryTool
        await executeMessageRequest(
            messages: messages,
            loadingMessageID: loadingMessage.id,
            currentSessionID: currentSession.id,
            userMessage: userMessage,
            wasTemporarySession: wasTemporarySession,
            aiTemperature: aiTemperature,
            aiTopP: aiTopP,
            systemPrompt: systemPrompt,
            maxChatHistory: maxChatHistory,
            enableStreaming: enableStreaming,
            enhancedPrompt: enhancedPrompt,
            tools: enableMemory ? [saveMemoryTool] : nil, // 根据开关决定是否提供工具
            enableMemory: enableMemory
        )
    }
    
    // MARK: - Agent & Tooling
    
    /// 定义 `save_memory` 工具
    internal var saveMemoryTool: InternalToolDefinition {
        let parameters = JSONValue.dictionary([
            "type": .string("object"),
            "properties": .dictionary([
                "content": .dictionary([
                    "type": .string("string"),
                    "description": .string("需要长期记住的具体信息内容。")
                ])
            ]),
            "required": .array([.string("content")])
        ])
        // 将此工具标记为非阻塞式
        return InternalToolDefinition(name: "save_memory", description: "将一段重要的信息存入长期记忆库，以便将来回忆。", parameters: parameters, isBlocking: false)
    }
    
    /// 处理单个工具调用
    @available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *)
    private func handleToolCall(_ toolCall: InternalToolCall) async -> ChatMessage {
        logger.info("🤖 正在处理工具调用: \(toolCall.toolName)")
        
        var content = ""
        
        switch toolCall.toolName {
        case "save_memory":
            // 解析参数
            struct SaveMemoryArgs: Decodable {
                let content: String
            }
            if let argsData = toolCall.arguments.data(using: .utf8), let args = try? JSONDecoder().decode(SaveMemoryArgs.self, from: argsData) {
                await self.memoryManager.addMemory(content: args.content)
                content = "成功将内容 \"\(args.content)\" 存入记忆。"
                logger.info("  - ✅ 记忆保存成功。")
            } else {
                content = "错误：无法解析 save_memory 的参数。"
                logger.error("  - ❌ 无法解析 save_memory 的参数: \(toolCall.arguments)")
            }
            
        default:
            content = "错误：未知的工具名称 \(toolCall.toolName)。"
            logger.error("  - ❌ 未知的工具名称: \(toolCall.toolName)")
        }
        
        return ChatMessage(role: .tool, content: content, toolCalls: [InternalToolCall(id: toolCall.id, toolName: toolCall.toolName, arguments: "")])
    }

    // MARK: - 核心请求执行逻辑 (已重构)
    
    private func executeMessageRequest(
        messages: [ChatMessage],
        loadingMessageID: UUID,
        currentSessionID: UUID,
        userMessage: ChatMessage?,
        wasTemporarySession: Bool,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        tools: [InternalToolDefinition]?,
        enableMemory: Bool
    ) async {
        // 自动查第一步：执行记忆搜索
        var memoryPrompt = ""
        if enableMemory, #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *), let userMessage = userMessage {
            let memories = await self.memoryManager.searchMemories(query: userMessage.content, topK: 3)
            if !memories.isEmpty {
                let memoryStrings = memories.map { "- (\($0.createdAt.formatted(date: .abbreviated, time: .shortened))): \($0.content)" }
                memoryPrompt = "# 相关历史记忆\n\(memoryStrings.joined(separator: "\n"))\n\n---"
                logger.info("📚 已检索到 \(memories.count) 条相关记忆。")
            }
        }
        
        guard let runnableModel = selectedModelSubject.value else {
            addErrorMessage("错误: 没有选中的可用模型。请在设置中激活一个模型。" )
            requestStatusSubject.send(.error)
            return
        }
        
        guard let adapter = adapters[runnableModel.provider.apiFormat] else {
            addErrorMessage("错误: 找不到适用于 '\(runnableModel.provider.apiFormat)' 格式的 API 适配器。" )
            requestStatusSubject.send(.error)
            return
        }

        var messagesToSend: [ChatMessage] = []
        
        var combinedPrompt = buildCombinedPrompt(global: systemPrompt, topic: currentSessionSubject.value?.topicPrompt)
        if !memoryPrompt.isEmpty {
            combinedPrompt = memoryPrompt + "\n" + combinedPrompt
        }
        
        if !combinedPrompt.isEmpty {
            messagesToSend.append(ChatMessage(role: .system, content: combinedPrompt))
        }
        
        var chatHistory = messages.filter { $0.role != .error && $0.id != loadingMessageID }
        if maxChatHistory > 0 && chatHistory.count > maxChatHistory {
            chatHistory = Array(chatHistory.suffix(maxChatHistory))
        }
        
        if let enhanced = enhancedPrompt, !enhanced.isEmpty, let lastUserMsgIndex = chatHistory.lastIndex(where: { $0.role == .user }) {
            chatHistory[lastUserMsgIndex].content += "\n\n<instruction>\n\(enhanced)\n</instruction>"
        }
        messagesToSend.append(contentsOf: chatHistory)
        
        let commonPayload: [String: Any] = ["temperature": aiTemperature, "top_p": aiTopP, "stream": enableStreaming]
        
        guard let request = adapter.buildChatRequest(for: runnableModel, commonPayload: commonPayload, messages: messagesToSend, tools: tools) else {
            addErrorMessage("错误: 无法构建 API 请求。" )
            requestStatusSubject.send(.error)
            return
        }
        
        if enableStreaming {
            await handleStreamedResponse(request: request, adapter: adapter, loadingMessageID: loadingMessageID, currentSessionID: currentSessionID, userMessage: userMessage, wasTemporarySession: wasTemporarySession, aiTemperature: aiTemperature, aiTopP: aiTopP, systemPrompt: systemPrompt, maxChatHistory: maxChatHistory)
        } else {
            await handleStandardResponse(request: request, adapter: adapter, loadingMessageID: loadingMessageID, currentSessionID: currentSessionID, userMessage: userMessage, wasTemporarySession: wasTemporarySession, availableTools: tools, aiTemperature: aiTemperature, aiTopP: aiTopP, systemPrompt: systemPrompt, maxChatHistory: maxChatHistory, enableMemory: enableMemory)
        }
    }

    public func retryLastMessage(
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        enableMemory: Bool
    ) async {
        guard let currentSession = currentSessionSubject.value else { return }
        let messages = messagesForSessionSubject.value
        
        // 1. 找到最后一条用户消息
        guard let lastUserMessageIndex = messages.lastIndex(where: { $0.role == .user }) else { return }
        let lastUserMessage = messages[lastUserMessageIndex]
        
        // 2. 将历史记录裁剪到这条消息之前
        let historyBeforeRetry = Array(messages.prefix(upTo: lastUserMessageIndex))
        
        // 3. 更新实时消息列表
        messagesForSessionSubject.send(historyBeforeRetry)
        Persistence.saveMessages(historyBeforeRetry, for: currentSession.id)
        
        // 4. 使用原消息内容，调用主要的发送函数，重用其完整逻辑
        await sendAndProcessMessage(
            content: lastUserMessage.content,
            aiTemperature: aiTemperature,
            aiTopP: aiTopP,
            systemPrompt: systemPrompt,
            maxChatHistory: maxChatHistory,
            enableStreaming: enableStreaming,
            enhancedPrompt: enhancedPrompt,
            enableMemory: enableMemory
        )
    }
    
    // MARK: - 私有网络层与响应处理 (已重构)

    private enum NetworkError: LocalizedError {
        case badStatusCode(Int)
        case adapterNotFound(format: String)
        case requestBuildFailed(provider: String)

        var errorDescription: String? {
            switch self {
            case .badStatusCode(let code): return "服务器响应错误，状态码: \(code)"
            case .adapterNotFound(let format): return "找不到适用于 '\(format)' 格式的 API 适配器。"
            case .requestBuildFailed(let provider): return "无法为 '\(provider)' 构建请求。"
            }
        }
    }

    private func fetchData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("  - ❌ 网络请求失败，状态码: \(statusCode)")
            throw NetworkError.badStatusCode(statusCode)
        }
        return data
    }

    private func streamData(for request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.error("  - ❌ 流式网络请求失败，状态码: \(statusCode)")
            throw NetworkError.badStatusCode(statusCode)
        }
        return bytes
    }
    
    private func handleStandardResponse(request: URLRequest, adapter: APIAdapter, loadingMessageID: UUID, currentSessionID: UUID, userMessage: ChatMessage?, wasTemporarySession: Bool, availableTools: [InternalToolDefinition]?, aiTemperature: Double, aiTopP: Double, systemPrompt: String, maxChatHistory: Int, enableMemory: Bool) async {
        do {
            let data = try await fetchData(for: request)
            logger.debug("✅ [Debug] 收到 AI 原始响应体:\n---\n\(String(data: data, encoding: .utf8) ?? "无法以 UTF-8 解码")\n---")
            await processResponseMessage(responseMessage: try adapter.parseResponse(data: data), loadingMessageID: loadingMessageID, currentSessionID: currentSessionID, userMessage: userMessage, wasTemporarySession: wasTemporarySession, availableTools: availableTools, aiTemperature: aiTemperature, aiTopP: aiTopP, systemPrompt: systemPrompt, maxChatHistory: maxChatHistory, enableMemory: enableMemory)
        } catch {
            addErrorMessage("网络或解析错误: \(error.localizedDescription)")
            requestStatusSubject.send(.error)
        }
    }
    
    /// 处理已解析的聊天消息，包含所有工具调用和UI更新的核心逻辑 (可测试)
    internal func processResponseMessage(responseMessage: ChatMessage, loadingMessageID: UUID, currentSessionID: UUID, userMessage: ChatMessage?, wasTemporarySession: Bool, availableTools: [InternalToolDefinition]?, aiTemperature: Double, aiTopP: Double, systemPrompt: String, maxChatHistory: Int, enableMemory: Bool) async {
        var responseMessage = responseMessage // Make it mutable
        if let toolCalls = responseMessage.toolCalls, !toolCalls.isEmpty {
            // 统一处理所有工具调用，总是执行二次调用流程
            logger.info("🤖 AI 请求调用工具...进入二次调用流程。")
            updateMessage(with: responseMessage, for: loadingMessageID, in: currentSessionID)
            
            var toolResultMessages: [ChatMessage] = []
            if #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) {
                for toolCall in toolCalls {
                    let resultMessage = await handleToolCall(toolCall)
                    toolResultMessages.append(resultMessage)
                }
            } else {
                toolResultMessages.append(ChatMessage(role: .error, content: "错误: 工具调用需要 watchOS 9.0 或更高版本。"))
            }
            
            var updatedMessages = self.messagesForSessionSubject.value
            updatedMessages.append(contentsOf: toolResultMessages)
            self.messagesForSessionSubject.send(updatedMessages)
            Persistence.saveMessages(updatedMessages, for: currentSessionID)
            
            logger.info("🔄 再次调用 AI 以生成最终回复...")
            await executeMessageRequest(
                messages: updatedMessages, loadingMessageID: loadingMessageID, currentSessionID: currentSessionID,
                userMessage: userMessage, wasTemporarySession: wasTemporarySession, aiTemperature: aiTemperature,
                aiTopP: aiTopP, systemPrompt: systemPrompt, maxChatHistory: maxChatHistory,
                enableStreaming: false, enhancedPrompt: nil, tools: nil, enableMemory: enableMemory
            )
        } else {
            // --- 无工具调用，标准流程 ---
            var responseMessage = responseMessage
            let (finalContent, extractedReasoning) = parseThoughtTags(from: responseMessage.content)
            responseMessage.content = finalContent
            if !extractedReasoning.isEmpty { responseMessage.reasoningContent = (responseMessage.reasoningContent ?? "") + "\n" + extractedReasoning }
            
            updateMessage(with: responseMessage, for: loadingMessageID, in: currentSessionID)
            requestStatusSubject.send(.finished)
            
            if wasTemporarySession, let userMsg = userMessage { await generateAndApplySessionTitle(for: currentSessionID, firstUserMessage: userMsg, firstAssistantMessage: responseMessage) }
        }
    }
    
    private func handleStreamedResponse(request: URLRequest, adapter: APIAdapter, loadingMessageID: UUID, currentSessionID: UUID, userMessage: ChatMessage?, wasTemporarySession: Bool, aiTemperature: Double, aiTopP: Double, systemPrompt: String, maxChatHistory: Int) async {
        do {
            let bytes = try await streamData(for: request)
            for try await line in bytes.lines {
                guard let part = adapter.parseStreamingResponse(line: line) else { continue }
                
                var messages = messagesForSessionSubject.value
                if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                    if let contentPart = part.content {
                        messages[index].content += contentPart
                    }
                    if let reasoningPart = part.reasoningContent {
                        if messages[index].reasoningContent == nil { messages[index].reasoningContent = "" }
                        messages[index].reasoningContent! += reasoningPart
                    }
                    messagesForSessionSubject.send(messages)
                }
            }
            
            var finalAssistantMessage: ChatMessage?
            var messages = messagesForSessionSubject.value
            if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                let (finalContent, extractedReasoning) = parseThoughtTags(from: messages[index].content)
                messages[index].content = finalContent
                if !extractedReasoning.isEmpty {
                    if messages[index].reasoningContent == nil { messages[index].reasoningContent = "" }
                    messages[index].reasoningContent! += "\n" + extractedReasoning
                }
                finalAssistantMessage = messages[index]
                messagesForSessionSubject.send(messages)
                Persistence.saveMessages(messages, for: currentSessionID)
            }
            requestStatusSubject.send(.finished)

            if wasTemporarySession, let finalAssistantMessage = finalAssistantMessage, let userMsg = userMessage {
                Task {
                    await generateAndApplySessionTitle(
                        for: currentSessionID,
                        firstUserMessage: userMsg,
                        firstAssistantMessage: finalAssistantMessage
                    )
                }
            }

        } catch {
            addErrorMessage("流式传输错误: \(error.localizedDescription)")
            requestStatusSubject.send(.error)
        }
    }
    
    /// 将最终确定的消息更新到消息列表中
    private func updateMessage(with newMessage: ChatMessage, for loadingMessageID: UUID, in sessionID: UUID) {
        var messages = messagesForSessionSubject.value
        if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
            messages[index] = ChatMessage(
                id: loadingMessageID, // 保持ID不变
                role: newMessage.role,
                content: newMessage.content,
                reasoningContent: newMessage.reasoningContent,
                toolCalls: newMessage.toolCalls // 确保 toolCalls 也被更新
            )
            messagesForSessionSubject.send(messages)
            Persistence.saveMessages(messages, for: sessionID)
        }
    }
    
    /// 从字符串中解析并移除 <thought> 标签内容
    private func parseThoughtTags(from text: String) -> (content: String, reasoning: String) {
        var finalContent = ""
        var finalReasoning = ""
        let startTagRegex = try! NSRegularExpression(pattern: "<(thought|thinking|think)>(.*?)</\\1>", options: [.dotMatchesLineSeparators])
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var lastMatchEnd = 0

        startTagRegex.enumerateMatches(in: text, options: [], range: nsRange) { (match, _, _) in
            guard let match = match else { return }
            let fullMatchRange = Range(match.range(at: 0), in: text)!
            let contentBeforeMatch = String(text[text.index(text.startIndex, offsetBy: lastMatchEnd)..<fullMatchRange.lowerBound])
            finalContent += contentBeforeMatch
            if let reasoningRange = Range(match.range(at: 2), in: text) {
                finalReasoning += (finalReasoning.isEmpty ? "" : "\n\n") + String(text[reasoningRange])
            }
            lastMatchEnd = fullMatchRange.upperBound.utf16Offset(in: text)
        }
        let remainingContent = String(text[text.index(text.startIndex, offsetBy: lastMatchEnd)...])
        finalContent += remainingContent
        return (finalContent.trimmingCharacters(in: .whitespacesAndNewlines), finalReasoning)
    }
    
    /// 构建组合后的系统 Prompt
    private func buildCombinedPrompt(global: String, topic: String?) -> String {
        let topicPrompt = topic ?? ""
        if !global.isEmpty && !topicPrompt.isEmpty {
            return "# 全局指令\n\n\(global)\n\n---\n\n# 当前话题指令\n\n\(topicPrompt)"
        } else {
            return global.isEmpty ? topicPrompt : global
        }
    }
    
    // MARK: - 自动会话标题生成

    private func generateAndApplySessionTitle(for sessionID: UUID, firstUserMessage: ChatMessage, firstAssistantMessage: ChatMessage) async {
        // 1. 检查功能是否开启
        let isAutoNamingEnabled = UserDefaults.standard.object(forKey: "enableAutoSessionNaming") as? Bool ?? true
        guard isAutoNamingEnabled else {
            logger.info("自动标题功能已禁用，跳过生成。")
            return
        }

        // 2. 检查AI回复是否为错误
        guard firstAssistantMessage.role != .error else {
            logger.warning("AI首次回复为错误，跳过标题生成。")
            return
        }
        
        // 3. 获取当前模型和适配器
        guard let runnableModel = selectedModelSubject.value, let adapter = adapters[runnableModel.provider.apiFormat] else {
            logger.error("无法获取当前模型或适配器，无法生成标题。")
            return
        }
        
        logger.info("🚀 开始为会话 \(sessionID.uuidString) 生成标题...")

        // 4. 准备生成标题的提示
        let titlePrompt = """
        请根据以下对话内容，为本次对话生成一个简短、精炼的标题。

        要求：
        - 长度在4到8个词之间。
        - 能准确概括对话的核心主题。
        - 直接返回标题内容，不要包含任何额外说明、引号或标点符号。

        对话内容：
        用户: \(firstUserMessage.content)
        AI: \(firstAssistantMessage.content)
        """
        
        let titleRequestMessages = [ChatMessage(role: .user, content: titlePrompt)]
        
        // 5. 构建并发送API请求 (非流式)
        let payload: [String: Any] = ["temperature": 0.5, "stream": false]
        guard let request = adapter.buildChatRequest(for: runnableModel, commonPayload: payload, messages: titleRequestMessages, tools: nil) else {
            logger.error("构建标题生成请求失败。")
            return
        }

        do {
            let data = try await fetchData(for: request)
            logger.debug("✅ [Debug] 收到 AI 原始响应体:\n---\n\(String(data: data, encoding: .utf8) ?? "无法以 UTF-8 解码")\n---")
            let responseMessage = try adapter.parseResponse(data: data)
            
            // 6. 清理和应用标题
            let newTitle = responseMessage.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’"))

            guard !newTitle.isEmpty else {
                logger.warning("AI返回的标题为空。")
                return
            }

            // 7. 更新会话状态和持久化
            var currentSessions = chatSessionsSubject.value
            if let index = currentSessions.firstIndex(where: { $0.id == sessionID }) {
                currentSessions[index].name = newTitle
                
                // 如果是当前会话，也更新 currentSessionSubject
                if var currentSession = currentSessionSubject.value, currentSession.id == sessionID {
                    currentSession.name = newTitle
                    currentSessionSubject.send(currentSession)
                }
                
                chatSessionsSubject.send(currentSessions)
                Persistence.saveChatSessions(currentSessions)
                logger.info("✅ 成功生成并应用新标题: '\(newTitle)'")
            }
        } catch {
            logger.error("生成会话标题时发生网络或解析错误: \(error.localizedDescription)")
        }
    }
}

// 临时的，为了编译通过。这个结构体应该在某个地方有正式定义。
struct ModelListResponse: Decodable {
    struct ModelData: Decodable {
        let id: String
    }
    let data: [ModelData]
}

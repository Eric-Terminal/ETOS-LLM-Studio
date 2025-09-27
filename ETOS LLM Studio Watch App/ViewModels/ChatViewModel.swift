// ============================================================================ 
// ChatViewModel.swift
// ============================================================================ 
// ETOS LLM Studio Watch App 核心视图模型文件
//
// 功能特性:
// - 驱动主视图 (ContentView) 的所有业务逻辑
// - 管理应用状态，包括消息、会话、设置等
// - 处理网络请求、数据操作和用户交互
// ============================================================================ 

import Foundation
import SwiftUI
import WatchKit
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

@MainActor
class ChatViewModel: ObservableObject {
    
    // MARK: - @Published 属性 (UI 状态)
    
    @Published var messages: [ChatMessage] = []
    @Published var allMessagesForSession: [ChatMessage] = []
    @Published var isHistoryFullyLoaded: Bool = false
    @Published var userInput: String = ""
    @Published var showDeleteMessageConfirm: Bool = false
    @Published var messageToDelete: ChatMessage?
    @Published var messageToEdit: ChatMessage?
    @Published var activeSheet: ActiveSheet?
    
    @Published var chatSessions: [ChatSession] = []
    @Published var currentSession: ChatSession? {
        didSet(oldSession) {
            // 当会话切换时，加载对应的消息
            // 只有在会话ID实际发生变化时才重新加载，防止因修改会话名称等操作导致不必要的重载
            if currentSession?.id != oldSession?.id {
                if let session = currentSession {
                    loadAndDisplayMessages(for: session)
                }
            }
        }
    }
    
    @Published var selectedModel: AIModelConfig
    
    // MARK: - 用户偏好设置 (AppStorage)
    
    @AppStorage("enableMarkdown") var enableMarkdown: Bool = true
    @AppStorage("enableBackground") var enableBackground: Bool = true
    @AppStorage("backgroundBlur") var backgroundBlur: Double = 10.0
    @AppStorage("backgroundOpacity") var backgroundOpacity: Double = 0.7
    @AppStorage("selectedModelName") var selectedModelName: String = ""
    @AppStorage("aiTemperature") var aiTemperature: Double = 0.7
    @AppStorage("aiTopP") var aiTopP: Double = 1.0
    @AppStorage("systemPrompt") var systemPrompt: String = ""
    @AppStorage("maxChatHistory") var maxChatHistory: Int = 0
    @AppStorage("enableStreaming") var enableStreaming: Bool = false
    @AppStorage("lazyLoadMessageCount") var lazyLoadMessageCount: Int = 10
    @AppStorage("currentBackgroundImage") var currentBackgroundImage: String = "Background1"
    @AppStorage("enableAutoRotateBackground") var enableAutoRotateBackground: Bool = true
    @AppStorage("enableLiquidGlass") var enableLiquidGlass: Bool = false
    
    // MARK: - 公开属性
    
    let modelConfigs: [AIModelConfig]
    let backgroundImages: [String]
    
    // MARK: - 私有属性
    
    private var extendedSession: WKExtendedRuntimeSession?
    
    // MARK: - 初始化
    
    init() {
        logger.info("🚀 [ViewModel] ChatViewModel is initializing...")
        let loadedConfig = ConfigLoader.load()
        self.modelConfigs = loadedConfig.models
        self.backgroundImages = loadedConfig.backgrounds
        
        let savedModelName = UserDefaults.standard.string(forKey: "selectedModelName")
        let initialModel = self.modelConfigs.first { $0.name == savedModelName } ?? self.modelConfigs.first!
        self.selectedModel = initialModel
        logger.info("  - Initial model set to: \(initialModel.name)")
        
        if enableAutoRotateBackground {
            let availableBackgrounds = self.backgroundImages.filter { $0 != self.currentBackgroundImage }
            currentBackgroundImage = availableBackgrounds.randomElement() ?? self.backgroundImages.randomElement() ?? "Background1"
            logger.info("  - Auto-rotating background. New background: \(self.currentBackgroundImage)")
        }
        
        var loadedSessions = loadChatSessions()
        let newSession = ChatSession(id: UUID(), name: "新的对话", topicPrompt: nil, enhancedPrompt: nil, isTemporary: true)
        loadedSessions.insert(newSession, at: 0)
        
        self.chatSessions = loadedSessions
        self.currentSession = newSession
        self.allMessagesForSession = []
        updateDisplayedMessages()
        logger.info("  - ViewModel initialized with \(self.chatSessions.count) sessions.")
    }
    
    // MARK: - 公开方法 (视图操作)
    
    // MARK: 消息流
    
    func sendMessage() {
        logger.info("✉️ [API] sendMessage called.")
        let userMessageContent = userInput
        guard !userMessageContent.isEmpty else { return }
        userInput = ""
        
        Task {
            await sendAndProcessMessage(content: userMessageContent)
        }
    }
    
    func addErrorMessage(_ content: String) {
        if let loadingIndex = allMessagesForSession.lastIndex(where: { $0.isLoading }) {
            allMessagesForSession[loadingIndex] = ChatMessage(id: allMessagesForSession[loadingIndex].id, role: "error", content: content, isLoading: false)
        } else {
            allMessagesForSession.append(ChatMessage(id: UUID(), role: "error", content: content))
        }
        updateDisplayedMessages()
        if let sessionID = currentSession?.id { saveMessages(allMessagesForSession, for: sessionID) }
    }
    
    func retryLastMessage() {
        guard let lastUserMessageIndex = allMessagesForSession.lastIndex(where: { $0.role == "user" }) else { return }
        let lastUserMessage = allMessagesForSession[lastUserMessageIndex]
        allMessagesForSession.removeSubrange(lastUserMessageIndex...)
        updateDisplayedMessages()
        Task { await sendAndProcessMessage(content: lastUserMessage.content) }
    }
    
    // MARK: 会话和消息管理
    
    func deleteMessage(at offsets: IndexSet) {
        let idsToDelete = offsets.map { messages[$0].id }
        allMessagesForSession.removeAll { idsToDelete.contains($0.id) }
        updateDisplayedMessages()
        if let sessionID = currentSession?.id { saveMessages(allMessagesForSession, for: sessionID) }
    }
    
    func deleteSession(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { chatSessions[$0] }
        for session in sessionsToDelete {
            let fileURL = getChatsDirectory().appendingPathComponent("\(session.id.uuidString).json")
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        chatSessions.remove(atOffsets: offsets)
        
        if let current = currentSession, sessionsToDelete.contains(where: { $0.id == current.id }) {
            if let firstSession = chatSessions.first {
                currentSession = firstSession
            } else {
                let newSession = ChatSession(id: UUID(), name: "新的对话", topicPrompt: nil, enhancedPrompt: nil, isTemporary: true)
                chatSessions.append(newSession)
                currentSession = newSession
            }
        } else if currentSession == nil && !chatSessions.isEmpty {
            currentSession = chatSessions.first
        }
        
        saveChatSessions(chatSessions)
    }
    
    func branchSession(from sourceSession: ChatSession, copyMessages: Bool) {
        let newSession = ChatSession(id: UUID(), name: "分支: \(sourceSession.name)", topicPrompt: sourceSession.topicPrompt, enhancedPrompt: sourceSession.enhancedPrompt, isTemporary: false)
        if copyMessages {
            let sourceMessages = loadMessages(for: sourceSession.id)
            if !sourceMessages.isEmpty { saveMessages(sourceMessages, for: newSession.id) }
        }
        chatSessions.insert(newSession, at: 0)
        saveChatSessions(chatSessions)
        currentSession = newSession
    }
    
    func deleteLastMessage(for session: ChatSession) {
       var messages = loadMessages(for: session.id)
       if !messages.isEmpty {
           messages.removeLast()
           saveMessages(messages, for: session.id)
       }
    }
    
    func createNewSession() {
        let newSession = ChatSession(id: UUID(), name: "新的对话", topicPrompt: nil, enhancedPrompt: nil, isTemporary: true)
        chatSessions.insert(newSession, at: 0)
        currentSession = newSession
    }
    
    // MARK: 视图状态与持久化
    
    func updateDisplayedMessages() {
        // 同步UI上的状态（如折叠状态）到主数据源
        for message in messages {
            if message.isReasoningExpanded != nil, let index = allMessagesForSession.firstIndex(where: { $0.id == message.id }) {
                if allMessagesForSession[index].isReasoningExpanded != message.isReasoningExpanded {
                    allMessagesForSession[index].isReasoningExpanded = message.isReasoningExpanded
                }
            }
        }
        
        // 根据懒加载设置更新UI显示的消息列表
        let lazyCount = lazyLoadMessageCount
        if lazyCount > 0 && allMessagesForSession.count > lazyCount {
            messages = Array(allMessagesForSession.suffix(lazyCount))
            isHistoryFullyLoaded = false
        } else {
            messages = allMessagesForSession
            isHistoryFullyLoaded = true
        }
    }

    func loadAndDisplayMessages(for session: ChatSession) {
        allMessagesForSession = loadMessages(for: session.id)
        updateDisplayedMessages()
    }
    
    func saveCurrentSessionDetails() {
        if let session = currentSession, !session.isTemporary {
            if let index = chatSessions.firstIndex(where: { $0.id == session.id }) {
                chatSessions[index] = session
                saveChatSessions(chatSessions)
            }
        }
    }
    
    func saveMessagesForCurrentSession() {
        if let sessionID = currentSession?.id {
            saveMessages(allMessagesForSession, for: sessionID)
        }
    }
    
    func forceSaveSessions() {
        saveChatSessions(chatSessions)
    }
    
    func canRetry(message: ChatMessage) -> Bool {
        // Find the index of the last message from the user.
        guard let lastUserMessageIndex = allMessagesForSession.lastIndex(where: { $0.role == "user" }) else {
            // If there are no user messages, nothing can be retried.
            return false
        }
        
        // Find the index of the current message.
        guard let messageIndex = allMessagesForSession.firstIndex(where: { $0.id == message.id }) else {
            return false
        }
        
        // The retry button should appear on the last user message and all messages after it.
        return messageIndex >= lastUserMessageIndex
    }
    
    // MARK: 导出
    
    func exportSessionViaNetwork(session: ChatSession, ipAddress: String, completion: @escaping (ExportStatus) -> Void) {
        logger.info("🚀 [Export] 准备通过网络导出...")
        logger.info("  - 目标会话: \(session.name) (\(session.id.uuidString))")
        logger.info("  - 目标地址: \(ipAddress)")

        let messagesToExport = loadMessages(for: session.id)
        let exportableMessages = messagesToExport.map {
            ExportableChatMessage(role: $0.role, content: $0.content, reasoning: $0.reasoning)
        }
        let promptsToExport = ExportPrompts(
            globalSystemPrompt: self.systemPrompt.isEmpty ? nil : self.systemPrompt,
            topicPrompt: session.topicPrompt,
            enhancedPrompt: session.enhancedPrompt
        )
        let fullExportData = FullExportData(prompts: promptsToExport, history: exportableMessages)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let jsonData = try? encoder.encode(fullExportData) else {
            logger.error("  - ❌ 错误: 无法将消息编码为JSON。")
            completion(.failed("无法编码JSON"))
            return
        }

        guard let url = URL(string: "http://\(ipAddress)") else {
            logger.error("  - ❌ 错误: 无效的IP地址格式。")
            completion(.failed("无效的IP地址格式"))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 60

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    logger.error("  - ❌ 网络错误: \(error.localizedDescription)")
                    completion(.failed("网络错误: \(error.localizedDescription)"))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    logger.error("  - ❌ 服务器错误: 状态码 \(statusCode)")
                    completion(.failed("服务器错误: 状态码 \(statusCode)"))
                    return
                }
                
                logger.info("  - ✅ 导出成功！")
                completion(.success)
            }
        }.resume()
    }
    
    // MARK: - 私有方法 (内部逻辑)
    
    // MARK: API 请求与响应处理
    
    private func sendAndProcessMessage(content: String) async {
        let userMessage = ChatMessage(id: UUID(), role: "user", content: content)
        let loadingMessageID = UUID()
        
        allMessagesForSession.append(userMessage)
        let loadingMessage = ChatMessage(id: loadingMessageID, role: "assistant", content: "", isLoading: true)
        allMessagesForSession.append(loadingMessage)
        updateDisplayedMessages()
        startExtendedSession()
        
        if var session = currentSession, session.isTemporary {
            if allMessagesForSession.filter({ !$0.isLoading }).count == 1 {
                session.name = String(userMessage.content.prefix(20))
                session.isTemporary = false
                currentSession = session
                if let index = chatSessions.firstIndex(where: { $0.id == session.id }) {
                    chatSessions[index] = session
                }
                saveChatSessions(chatSessions)
            }
        }
        
        if let sessionId = currentSession?.id {
            saveMessages(allMessagesForSession, for: sessionId)
        }

        guard let url = URL(string: selectedModel.apiURL) else { 
            addErrorMessage("Error: Invalid API URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let randomApiKey = selectedModel.apiKeys.randomElement() {
            request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        } else {
            addErrorMessage("Error: No API Key configured for this model")
            return
        }
        
        var finalPayload = selectedModel.basePayload
        finalPayload["temperature"] = aiTemperature
        finalPayload["top_p"] = aiTopP
        if enableStreaming { finalPayload["stream"] = true }
        
        var apiMessages: [[String: String]] = []
        let globalPrompt = systemPrompt
        let topicPrompt = currentSession?.topicPrompt ?? ""
        var combinedPrompt = ""
        if !globalPrompt.isEmpty && !topicPrompt.isEmpty {
            combinedPrompt = "# 全局指令\n\(globalPrompt)\n\n---\n\n# 当前话题指令\n\(topicPrompt)"
        } else {
            combinedPrompt = globalPrompt.isEmpty ? topicPrompt : globalPrompt
        }

        if !combinedPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": combinedPrompt])
        }
        
        var chatHistoryToSend = allMessagesForSession.filter { !$0.isLoading && $0.role != "error" }
        if maxChatHistory > 0 && chatHistoryToSend.count > maxChatHistory {
            chatHistoryToSend = Array(chatHistoryToSend.suffix(maxChatHistory))
        }
        
        let enhancedPrompt = currentSession?.enhancedPrompt ?? ""
        var chatHistory = chatHistoryToSend.map { ["role": $0.role, "content": $0.content] }
        
        if !enhancedPrompt.isEmpty, let lastUserMessageIndex = chatHistory.lastIndex(where: { $0["role"] == "user" }) {
            let instructionXML = "<instruction>\n这是一个自动填充的instruction，除非用户要求否则不要在回复内容提及此instruction，默默执行遵守就好，否则会影响用户的回复体验。\n\n---\n\n\(enhancedPrompt)\n</instruction>"
            let originalContent = chatHistory[lastUserMessageIndex]["content"] ?? ""
            chatHistory[lastUserMessageIndex]["content"] = "\(originalContent)\n\n\(instructionXML)"
        }
        
        apiMessages.append(contentsOf: chatHistory)
        finalPayload["messages"] = apiMessages
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload, options: .prettyPrinted)
            if let httpBody = request.httpBody, let jsonString = String(data: httpBody, encoding: .utf8) {
                logger.debug("  - 完整的请求体 (Raw Request Body):\n---\n\(jsonString)\n---")
            }
        } catch {
            addErrorMessage("Error: Could not build request JSON - \(error.localizedDescription)")
            return
        }
        
        if enableStreaming {
            await handleStreamedResponse(request: request, loadingMessageID: loadingMessageID)
        } else {
            await handleStandardResponse(request: request, loadingMessageID: loadingMessageID)
        }
    }
    
    private func handleStandardResponse(request: URLRequest, loadingMessageID: UUID) async {
        var responseString: String? 
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            responseString = String(data: data, encoding: .utf8)
            
            if let responseStr = responseString {
                logger.debug("    - 完整的响应体 (Raw Response):\n---\n\(responseStr)\n---")
            }
            
            let apiResponse = try JSONDecoder().decode(GenericAPIResponse.self, from: data)
            if let messagePayload = apiResponse.choices.first?.message {
                let rawContent = messagePayload.content ?? ""
                let reasoningFromAPI = messagePayload.reasoning_content
                
                var finalContent = ""
                var finalReasoning = reasoningFromAPI ?? ""
                
                let startTagRegex = try! NSRegularExpression(pattern: "<(thought|thinking|think)>(.*?)</\\1>", options: [.dotMatchesLineSeparators])
                let nsRange = NSRange(rawContent.startIndex..<rawContent.endIndex, in: rawContent)
                
                var lastMatchEnd = 0
                startTagRegex.enumerateMatches(in: rawContent, options: [], range: nsRange) { (match, _, _) in
                    guard let match = match else { return }
                    
                    let fullMatchRange = Range(match.range(at: 0), in: rawContent)!
                    let contentBeforeMatch = String(rawContent[rawContent.index(rawContent.startIndex, offsetBy: lastMatchEnd)..<fullMatchRange.lowerBound])
                    finalContent += contentBeforeMatch
                    
                    if let reasoningRange = Range(match.range(at: 2), in: rawContent) {
                        finalReasoning += (finalReasoning.isEmpty ? "" : "\n\n") + String(rawContent[reasoningRange])
                    }
                    
                    lastMatchEnd = fullMatchRange.upperBound.utf16Offset(in: rawContent)
                }
                
                let remainingContent = String(rawContent[rawContent.index(rawContent.startIndex, offsetBy: lastMatchEnd)...])
                finalContent += remainingContent
                
                await MainActor.run {
                    if let index = self.allMessagesForSession.firstIndex(where: { $0.id == loadingMessageID }) {
                        self.allMessagesForSession[index].isLoading = false
                        self.allMessagesForSession[index].content = finalContent.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !finalReasoning.isEmpty {
                            self.allMessagesForSession[index].reasoning = finalReasoning
                            self.allMessagesForSession[index].isReasoningExpanded = false
                        }
                        
                        self.updateDisplayedMessages()
                        
                        if let sessionID = self.currentSession?.id {
                            saveMessages(self.allMessagesForSession, for: sessionID)
                        }
                    }
                }
            } else {
                throw URLError(.badServerResponse)
            }
        } catch {
            let errorMessage = "网络或解析错误: \(error.localizedDescription)"
            if let responseStr = responseString, !responseStr.isEmpty {
                await MainActor.run { self.addErrorMessage("API响应解析失败。\n响应体: \(responseStr)") }
            } else {
                await MainActor.run { self.addErrorMessage(errorMessage) }
            }
        }
        
        await MainActor.run {
            self.stopExtendedSession()
        }
    }
    
    private func handleStreamedResponse(request: URLRequest, loadingMessageID: UUID) async {
        var isInsideReasoningBlock = false
        let startTagRegex = try! NSRegularExpression(pattern: "<(thought|thinking|think)>")
        let endTagRegex = try! NSRegularExpression(pattern: "</(thought|thinking|think)>")
        
        var textBuffer = ""

        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            
            for try await line in bytes.lines {
                if line.hasPrefix("data:"), let data = line.dropFirst(5).data(using: .utf8) {
                    if line.contains("[DONE]") { break }

                    if let chunkString = String(data: data, encoding: .utf8) {
                        logger.debug("    - 流式响应块 (Stream Chunk):\n---\n\(chunkString)\n---")
                    }
                    
                    guard let chunk = try? JSONDecoder().decode(GenericAPIResponse.self, from: data),
                          let delta = chunk.choices.first?.delta else {
                        continue
                    }
                    
                    textBuffer += delta.content ?? ""
                    let apiReasoningChunk = delta.reasoning_content ?? ""

                    var contentToUpdate = ""
                    var reasoningToUpdate = apiReasoningChunk
                    
                    while true {
                        let bufferRange = NSRange(location: 0, length: textBuffer.utf16.count)
                        
                        if isInsideReasoningBlock {
                            if let match = endTagRegex.firstMatch(in: textBuffer, options: [], range: bufferRange) {
                                let range = Range(match.range, in: textBuffer)!
                                reasoningToUpdate += textBuffer[..<range.lowerBound]
                                textBuffer = String(textBuffer[range.upperBound...])
                                isInsideReasoningBlock = false
                                continue
                            } else {
                                reasoningToUpdate += textBuffer
                                textBuffer = ""
                            }
                        } else {
                            if let match = startTagRegex.firstMatch(in: textBuffer, options: [], range: bufferRange) {
                                let range = Range(match.range, in: textBuffer)!
                                contentToUpdate += textBuffer[..<range.lowerBound]
                                textBuffer = String(textBuffer[range.upperBound...])
                                isInsideReasoningBlock = true
                                continue
                            } else {
                                contentToUpdate += textBuffer
                                textBuffer = ""
                            }
                        }
                        break
                    }

                    await MainActor.run {
                        if let index = self.allMessagesForSession.firstIndex(where: { $0.id == loadingMessageID }) {
                            if self.allMessagesForSession[index].isLoading {
                                self.allMessagesForSession[index].isLoading = false
                            }
                            
                            if !reasoningToUpdate.isEmpty {
                                if self.allMessagesForSession[index].reasoning == nil {
                                    self.allMessagesForSession[index].reasoning = ""
                                    self.allMessagesForSession[index].isReasoningExpanded = false
                                }
                                self.allMessagesForSession[index].reasoning! += reasoningToUpdate
                            }

                            if !contentToUpdate.isEmpty {
                                self.allMessagesForSession[index].content += contentToUpdate
                            }
                            
                            self.updateDisplayedMessages()
                        }
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.addErrorMessage("流式传输错误: \(error.localizedDescription)")
            }
        }
        
        if !textBuffer.isEmpty {
            await MainActor.run {
                if let index = self.allMessagesForSession.firstIndex(where: { $0.id == loadingMessageID }) {
                    if isInsideReasoningBlock {
                        if self.allMessagesForSession[index].reasoning == nil {
                           self.allMessagesForSession[index].reasoning = ""
                           self.allMessagesForSession[index].isReasoningExpanded = false
                        }
                        self.allMessagesForSession[index].reasoning! += textBuffer
                    } else {
                        self.allMessagesForSession[index].content += textBuffer
                    }
                }
            }
        }

        await MainActor.run {
            if let index = self.allMessagesForSession.firstIndex(where: { $0.id == loadingMessageID }) {
                self.allMessagesForSession[index].isLoading = false
            }
            
            self.updateDisplayedMessages()
            self.stopExtendedSession()
            if let sessionID = self.currentSession?.id {
                saveMessages(self.allMessagesForSession, for: sessionID)
            }
        }
    }
    
    // MARK: 扩展运行时会话
    
    private func startExtendedSession() {
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.start()
    }
    
    private func stopExtendedSession() {
        extendedSession?.invalidate()
        extendedSession = nil
    }
}

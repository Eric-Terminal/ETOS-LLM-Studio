// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio Watch App 主视图文件
//
// 功能特性:
// - 多会话聊天管理
// - Markdown消息渲染
// - 自定义背景设置
// - AI模型切换支持
// ============================================================================

import SwiftUI
import MarkdownUI
import WatchKit

// MARK: - 数据结构定义
// ============================================================================
struct AIModelConfig: Identifiable, Hashable {
    static func == (lhs: AIModelConfig, rhs: AIModelConfig) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    
    let id = UUID()
    let name: String        // 模型显示名称
    let apiKeys: [String]   // API密钥数组
    let apiURL: String      // API端点URL
    let basePayload: [String: Any]  // 基础请求负载参数
}

/// 聊天消息数据结构
/// 支持编码解码，用于消息持久化存储
///
/// 角色类型说明:
/// - user: 用户发送的消息
/// - assistant: AI回复的消息
/// - system: 系统提示消息
/// - error: 错误提示消息
struct ChatMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: String // "user", "assistant", "system", "error"
    var content: String
    var reasoningContent: String?
    var isLoading: Bool = false

    // 自定义编码键，用于JSON序列化
    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, isLoading
    }

    // 自定义解码器
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        isLoading = try container.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false
    }

    // 自定义编码器
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        // 仅当reasoningContent有值时才编码
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        // 仅当isLoading为true时才编码
        if isLoading {
            try container.encode(isLoading, forKey: .isLoading)
        }
    }
    
    // 为了方便其他代码调用而增加的便利初始化器
    init(id: UUID, role: String, content: String, reasoningContent: String? = nil, isLoading: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.isLoading = isLoading
    }
}

/// 用于导出的聊天消息数据结构（移除了UUID）
struct ExportableChatMessage: Codable {
    var role: String
    var content: String
    var reasoningContent: String?
}

/// 用于导出提示词的结构
struct ExportPrompts: Codable {
    let globalSystemPrompt: String?
    let topicPrompt: String?
    let enhancedPrompt: String?
}

/// 完整的导出数据结构，包含提示词和历史记录
struct FullExportData: Codable {
    let prompts: ExportPrompts
    let history: [ExportableChatMessage]
}

/// 聊天会话数据结构
/// 用于管理多个独立的聊天记录
///
/// 特性:
/// - 支持临时会话标记
/// - 自动生成会话名称
/// - 持久化存储支持
struct ChatSession: Identifiable, Codable, Hashable {
    let id: UUID        // 会话唯一标识
    var name: String    // 会话名称（如首条消息）
    var topicPrompt: String? // 新增：当前会话的话题提示词
    var enhancedPrompt: String? // 新增：当前会话的增强提示词
    var isTemporary: Bool = false // 标记是否为尚未保存的临时会话
    
    // 自定义编码，在保存到JSON时忽略 isTemporary 字段，因为它只在运行时需要
    enum CodingKeys: String, CodingKey {
        case id, name, topicPrompt, enhancedPrompt
    }
}

/// 通用API响应数据结构
/// 用于解析不同AI服务提供商的响应格式
///
/// 支持字段:
/// - choices: 响应选择列表
/// - message: 消息内容对象
/// - reasoning_content: 思考过程内容
struct GenericAPIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?          // 消息内容
            let reasoning_content: String?  // 思考过程内容
        }
        // 在流式响应中，message 字段可能不存在，而是一个 delta 字段
        struct Delta: Codable {
            let content: String?
            let reasoning_content: String?
        }
        let message: Message?
        let delta: Delta?
    }
    let choices: [Choice]  // 响应选择列表
}


// MARK: - 主视图
// ============================================================================

/// 用于管理所有可能弹出的 Sheet 视图的枚举
/// 遵循 Identifiable 协议，以便与 .sheet(item:) 修饰符一起使用
enum ActiveSheet: Identifiable, Equatable {
    case settings
    case editMessage
    case export(ChatSession) // 新增：用于显示导出视图，并传递会话
    
    var id: Int {
        switch self {
        case .settings: return 1
        case .editMessage: return 2
        case .export: return 3
        }
    }
}

/// 主聊天界面视图
/// 负责显示聊天消息、处理用户输入和与AI API交互
///
/// 主要功能:
/// - 实时聊天消息显示
/// - 用户输入处理
/// - AI API调用管理
/// - 多会话切换支持
struct ContentView: View {
    
    /// 支持的AI模型配置列表
    let modelConfigs: [AIModelConfig]
    
    // MARK: - 状态属性
    
    @State private var messages: [ChatMessage] = []      // 当前会话的聊天消息列表
    @State private var userInput: String = ""           // 用户输入文本
    @State private var showDeleteMessageConfirm: Bool = false // 控制删除消息确认弹窗
    @State private var messageToDelete: ChatMessage?          // 待删除的消息
    @State private var messageToEdit: ChatMessage?            // 待编辑的消息
    @State private var activeSheet: ActiveSheet?              // 当前激活的 Sheet
    @State private var extendedSession: WKExtendedRuntimeSession? // watchOS 屏幕常亮会话
    
    // MARK: - 用户偏好设置
    @AppStorage("enableMarkdown") private var enableMarkdown: Bool = true // Markdown渲染开关
    @AppStorage("enableBackground") private var enableBackground: Bool = true // 背景开关
    @AppStorage("backgroundBlur") private var backgroundBlur: Double = 10.0 // 背景模糊半径
    @AppStorage("backgroundOpacity") private var backgroundOpacity: Double = 0.7 // 背景透明度
    @AppStorage("selectedModelName") private var selectedModelName: String? // 保存上次选择的模型名称
    @AppStorage("aiTemperature") private var aiTemperature: Double = 0.7 // AI的temperature参数
    @AppStorage("aiTopP") private var aiTopP: Double = 1.0 // AI的top_p参数
    @AppStorage("systemPrompt") private var systemPrompt: String = "" // 自定义系统提示词
    @AppStorage("maxChatHistory") private var maxChatHistory: Int = 0 // 最大上下文消息数，0为不限制
    @AppStorage("enableStreaming") private var enableStreaming: Bool = false // 流式输出开关
    
    @State private var selectedModel: AIModelConfig     // 当前选中的AI模型
    
    // MARK: - 背景设置
    private let backgroundImages: [String]
    @AppStorage("currentBackgroundImage") private var currentBackgroundImage: String = "Background1" // 当前背景图名称
    @AppStorage("enableAutoRotateBackground") private var enableAutoRotateBackground: Bool = true // 是否自动轮换背景
    
    // MARK: - 会话管理
    @State private var chatSessions: [ChatSession] = [] // 所有聊天会话列表
    @State private var currentSession: ChatSession?     // 当前激活的聊天会话

    // MARK: - 初始化
    
    init() {
        print("🚀 [App] ContentView 正在初始化...")
        // 从 AppConfig.json 加载配置
        let loadedConfig = ConfigLoader.load()
        self.modelConfigs = loadedConfig.models
        self.backgroundImages = loadedConfig.backgrounds
        
        // 优先从 UserDefaults 加载上次选中的模型，如果找不到则使用第一个模型
        let savedModelName = UserDefaults.standard.string(forKey: "selectedModelName")
        let initialModel = self.modelConfigs.first { $0.name == savedModelName } ?? self.modelConfigs.first!
        _selectedModel = State(initialValue: initialModel)
        print("  - 当前选用模型: \(initialModel.name)")
        
        // 如果启用了自动轮换，则在应用启动时随机选择一张背景图片
        if enableAutoRotateBackground {
            let lastBackgroundImage = self.currentBackgroundImage
            let availableBackgrounds = self.backgroundImages.filter { $0 != lastBackgroundImage }
            
            if let newBackgroundImage = availableBackgrounds.randomElement() {
                self.currentBackgroundImage = newBackgroundImage
            } else {
                // 如果过滤后没有其他可用背景（例如总共只有一张图），则从原始列表随机选，以防万一
                self.currentBackgroundImage = self.backgroundImages.randomElement() ?? "Background1"
            }
            print("  - 自动轮换背景已启用，新背景为: \(self.currentBackgroundImage)")
        } else {
            print("  - 自动轮换背景已禁用，当前背景为: \(self.currentBackgroundImage)")
        }
        
        // 加载所有已保存的会话
        var loadedSessions = loadChatSessions()
        
        // 无论如何，总是在启动时创建一个新的会话
        let newSession = ChatSession(id: UUID(), name: "新的对话", topicPrompt: nil, enhancedPrompt: nil, isTemporary: true)
        print("  - 创建了一个新的临时会话: \(newSession.id.uuidString)")
        
        // 将新会话插入到列表的最前面，使其成为一个临时的会话
        loadedSessions.insert(newSession, at: 0)
        
        // 初始化状态，并将新创建的会话设为当前会话
        _chatSessions = State(initialValue: loadedSessions)
        _currentSession = State(initialValue: newSession)
        _messages = State(initialValue: []) // 新会话总是从空消息列表开始
        print("  - 初始化完成。当前共有 \(loadedSessions.count) 个会话（包含临时）。")
        print("  - 当前会话已设置为新的临时会话。")
    }

    // MARK: - 视图主体
    
    var body: some View {
        ZStack {
            // 如果启用了背景，则显示背景图片
            if enableBackground {
                Image(currentBackgroundImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .edgesIgnoringSafeArea(.all)
                    .blur(radius: backgroundBlur) // 高斯模糊
                    .opacity(backgroundOpacity)     // 透明度
            }
            
            NavigationStack {
                ScrollViewReader { proxy in
                    // 使用List替代ScrollView以获得原生的滑动删除功能
                    List {
                    // 添加一个隐形的Spacer，当内容不足一屏时，它会自动撑开，
                    // 将所有实际内容（消息和输入框）推到底部。
                    Spacer().listRowBackground(Color.clear)

                    ForEach(messages) { message in
                        ChatBubble(message: message, enableMarkdown: enableMarkdown, enableBackground: enableBackground)
                            .id(message.id) // 确保每个消息都有唯一ID以便滚动
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading) { // 右滑出现菜单
                                NavigationLink {
                                    // 导航到新的消息操作二级菜单
                                    MessageActionsView(
                                        message: message,
                                        canRetry: canRetry(message: message),
                                        onEdit: {
                                            messageToEdit = message
                                            activeSheet = .editMessage
                                        },
                                        onRetry: {
                                            retryLastMessage()
                                        },
                                        onDelete: {
                                            messageToDelete = message
                                            showDeleteMessageConfirm = true
                                        }
                                    )
                                } label: {
                                    Label("更多", systemImage: "ellipsis.circle.fill")
                                }
                                .tint(.gray)
                            }
                    }
                    
                    // 将输入区域作为列表的最后一个元素
                    inputBubble
                        .id("inputBubble") // 为输入区域设置一个固定ID
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .background(Color.clear) // 使List背景透明以显示下层视图
                // 当消息数量变化时，自动滚动到底部的输入框
                .onChange(of: messages.count) {
                    withAnimation {
                        // 滚动到固定的输入区域ID
                        proxy.scrollTo("inputBubble", anchor: .bottom)
                    }
                }
                // 消息删除确认对话框
                .confirmationDialog("确认删除", isPresented: $showDeleteMessageConfirm, titleVisibility: .visible) {
                    Button("删除消息", role: .destructive) {
                        if let message = messageToDelete, let index = messages.firstIndex(where: { $0.id == message.id }) {
                            deleteMessage(at: IndexSet(integer: index))
                        }
                        messageToDelete = nil
                    }
                    Button("取消", role: .cancel) {
                        messageToDelete = nil
                    }
                } message: {
                    Text("您确定要删除这条消息吗？此操作无法撤销。")
                }
            }
            // 统一的 Sheet 模态视图管理器
            .sheet(item: $activeSheet) { item in
                switch item {
                case .editMessage:
                    if let messageToEdit = messageToEdit,
                       let messageIndex = messages.firstIndex(where: { $0.id == messageToEdit.id }) {
                        
                        let messageBinding = $messages[messageIndex]
                        
                        EditMessageView(message: messageBinding, onSave: { updatedMessage in
                            // 在回调中保存整个消息数组
                            if let sessionID = currentSession?.id {
                                saveMessages(messages, for: sessionID)
                                print("💾 [Persistence] 消息编辑已保存。")
                            }
                        })
                    }
                case .settings:
                    SettingsView(
                        selectedModel: $selectedModel,
                        allModels: modelConfigs,
                        sessions: $chatSessions,
                        currentSession: $currentSession,
                        aiTemperature: $aiTemperature,
                        aiTopP: $aiTopP,
                        systemPrompt: $systemPrompt,
                        maxChatHistory: $maxChatHistory,
                        enableStreaming: $enableStreaming, // 传递绑定
                        enableMarkdown: $enableMarkdown,
                        enableBackground: $enableBackground,
                        backgroundBlur: $backgroundBlur,
                        backgroundOpacity: $backgroundOpacity,
                        allBackgrounds: backgroundImages,
                        currentBackgroundImage: $currentBackgroundImage,
                        enableAutoRotateBackground: $enableAutoRotateBackground,
                        deleteAction: deleteSession,
                        branchAction: branchSession,
                        exportAction: { session in
                            activeSheet = .export(session)
                        }
                    )
                case .export(let session):
                    ExportView(
                        session: session,
                        onExport: exportSessionViaNetwork
                    )
                }
            }
        }
        .onChange(of: selectedModel.name) {
            // 当模型选择变化时，保存新的模型名称
            selectedModelName = selectedModel.name
        }
        .onChange(of: activeSheet) {
            // 当 sheet 关闭时 (activeSheet 变为 nil)，执行原 onDismiss 的逻辑
            if activeSheet == nil {
                // 当设置面板关闭时，保存可能已更改的会话（例如话题提示词）
                if let session = currentSession, !session.isTemporary {
                    if let index = chatSessions.firstIndex(where: { $0.id == session.id }) {
                        chatSessions[index] = session
                        saveChatSessions(chatSessions)
                        print("💾 [Persistence] 设置面板关闭，已更新并保存当前会话的变更。")
                    }
                }
                
                // 根据当前选中的会话重新加载消息
                if let session = currentSession {
                    messages = loadMessages(for: session.id)
                } else {
                    messages = [] // 如果没有会话，则清空消息
                }
            }
        }
    }
}

    // MARK: - 视图组件
    // ============================================================================
    
    /// 输入气泡视图，作为列表的一部分
    /// 包含设置按钮、文本输入框和发送按钮
    private var inputBubble: some View {
        HStack(spacing: 12) {
            Button(action: { activeSheet = .settings }) {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain)
            .fixedSize()
            
            TextField("输入...", text: $userInput)
            
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(userInput.isEmpty || (messages.last?.isLoading ?? false))
        }
        .padding(10)
        .background(enableBackground ? AnyShapeStyle(.clear) : AnyShapeStyle(.ultraThinMaterial)) // 根据设置决定背景效果
        .cornerRadius(12)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - 消息处理函数
    // ============================================================================
    
    // MARK: - 主要消息流程
    
    /// 发送消息到AI API
    /// 处理用户输入、构建API请求并处理响应
    ///
    /// 处理流程:
    /// 1. 添加用户消息到列表
    /// 2. 创建加载占位符
    /// 3. 构建API请求
    /// 4. 发送请求并处理响应
    /// 5. 更新消息列表和保存状态
    func sendMessage() {
        print("✉️ [API] sendMessage 被调用。")
        let userMessageContent = userInput
        userInput = "" // 立即清空输入框
        
        Task {
            await sendAndProcessMessage(content: userMessageContent)
        }
    }

    private func sendAndProcessMessage(content: String) async {
        let currentConfig = selectedModel
        let userMessage = ChatMessage(id: UUID(), role: "user", content: content)
        
        // 创建一个唯一的ID给即将创建的加载消息
        let loadingMessageID = UUID()
        
        await MainActor.run {
            messages.append(userMessage)
            // 添加一个带isLoading标记的占位消息
            let loadingMessage = ChatMessage(id: loadingMessageID, role: "assistant", content: "", isLoading: true)
            messages.append(loadingMessage)
            print("  - 用户消息已添加到列表: \"\(userMessage.content)\"")
            print("  - 添加了AI加载占位符。")
            startExtendedSession()
        }
        
        // 如果是新对话的第一条消息，更新会话名称并将其持久化
        if var session = currentSession, session.isTemporary {
            let messageCountWithoutLoading = messages.filter { !$0.isLoading }.count
            if messageCountWithoutLoading == 1 {
                session.name = String(userMessage.content.prefix(20))
                session.isTemporary = false
                currentSession = session
                if let index = chatSessions.firstIndex(where: { $0.id == session.id }) {
                    chatSessions[index] = session
                }
                print("  - 这是新会话的第一条消息。会话名称更新为: \"\(session.name)\"")
                saveChatSessions(chatSessions)
            }
        }
        
        saveMessages(messages, for: currentSession!.id)

        guard let url = URL(string: currentConfig.apiURL) else {
            await MainActor.run { addErrorMessage("错误: API URL 无效") }; return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let randomApiKey = currentConfig.apiKeys.randomElement() {
            request.setValue("Bearer \(randomApiKey)", forHTTPHeaderField: "Authorization")
        } else {
            await MainActor.run { addErrorMessage("错误: 模型没有配置API Key") }; return
        }
        
        var finalPayload = currentConfig.basePayload
        finalPayload["temperature"] = aiTemperature
        finalPayload["top_p"] = aiTopP
        if enableStreaming {
            finalPayload["stream"] = true // 仅在开启时添加 stream 参数
        }
        
        var apiMessages: [[String: String]] = []
        let globalPrompt = systemPrompt
        let topicPrompt = currentSession?.topicPrompt ?? ""
        var combinedPrompt = ""
        let hasGlobalPrompt = !globalPrompt.isEmpty
        let hasTopicPrompt = !topicPrompt.isEmpty

        if hasGlobalPrompt && hasTopicPrompt {
            combinedPrompt = "# 全局指令\n\(globalPrompt)\n\n---\n\n# 当前话题指令\n\(topicPrompt)"
        } else {
            combinedPrompt = hasGlobalPrompt ? globalPrompt : topicPrompt
        }

        if !combinedPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": combinedPrompt])
        }
        
        // 在发送到API前，过滤掉isLoading的消息
        var chatHistoryToSend = messages.filter { !$0.isLoading && $0.role != "error" }
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
                print("  - 完整的请求体 (Raw Request Body):\n---\n\(jsonString)\n---")
            }
        } catch {
            await MainActor.run { addErrorMessage("错误: 无法构建请求体JSON - \(error.localizedDescription)") }; return
        }
        
        if enableStreaming {
            await handleStreamedResponse(request: request, loadingMessageID: loadingMessageID)
        } else {
            await handleStandardResponse(request: request, loadingMessageID: loadingMessageID)
        }
    }

    // MARK: - API响应处理
    
    private func handleStandardResponse(request: URLRequest, loadingMessageID: UUID) async {
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            
            if let responseString = String(data: data, encoding: .utf8) {
                print("    - 完整的响应体 (Raw Response):\n---\n\(responseString)\n---")
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
                
                let aiMessage = ChatMessage(id: loadingMessageID, role: "assistant", content: finalContent.trimmingCharacters(in: .whitespacesAndNewlines), reasoningContent: finalReasoning.isEmpty ? nil : finalReasoning, isLoading: false)
                
                await MainActor.run {
                    if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                        messages[index] = aiMessage
                    }
                    if let sessionID = currentSession?.id {
                        saveMessages(messages, for: sessionID)
                    }
                }
            } else {
                throw URLError(.badServerResponse)
            }
        } catch {
            let errorMessage = "网络或解析错误: \(error.localizedDescription)"
            if let httpBody = request.httpBody, let str = String(data: httpBody, encoding: .utf8) {
                await MainActor.run { addErrorMessage("JSON解析失败.\n请求体: \(str)") }
            } else {
                await MainActor.run { addErrorMessage(errorMessage) }
            }
        }
        
        await MainActor.run {
            stopExtendedSession()
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
                        print("    - 流式响应块 (Stream Chunk):\n---\n\(chunkString)\n---")
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
                            }
                        } else {
                            if let match = startTagRegex.firstMatch(in: textBuffer, options: [], range: bufferRange) {
                                let range = Range(match.range, in: textBuffer)!
                                contentToUpdate += textBuffer[..<range.lowerBound]
                                textBuffer = String(textBuffer[range.upperBound...])
                                isInsideReasoningBlock = true
                                continue
                            }
                        }
                        break
                    }

                    if !contentToUpdate.isEmpty || !reasoningToUpdate.isEmpty {
                        await MainActor.run {
                            if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                                // 只有当收到第一块“实际内容”时，才关闭加载状态
                                // 这样可以确保在仅有reasoning输出时，loading动画仍然持续
                                if messages[index].isLoading, !contentToUpdate.isEmpty {
                                    messages[index].isLoading = false
                                }
                                messages[index].content += contentToUpdate
                                if !reasoningToUpdate.isEmpty {
                                    if messages[index].reasoningContent == nil {
                                        messages[index].reasoningContent = reasoningToUpdate
                                    } else {
                                        messages[index].reasoningContent? += reasoningToUpdate
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            await MainActor.run {
                addErrorMessage("流式传输错误: \(error.localizedDescription)")
            }
        }
        
        // 流结束后，处理缓冲区中所有剩余的内容
        if !textBuffer.isEmpty {
            await MainActor.run {
                if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                    if isInsideReasoningBlock {
                        if messages[index].reasoningContent == nil { messages[index].reasoningContent = textBuffer }
                        else { messages[index].reasoningContent? += textBuffer }
                    } else {
                        messages[index].content += textBuffer
                    }
                }
            }
        }

        // 最终清理和保存
        await MainActor.run {
            if let index = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                messages[index].isLoading = false
            }
            
            stopExtendedSession()
            if let sessionID = currentSession?.id {
                saveMessages(messages, for: sessionID)
            }
        }
    }
    
    // MARK: - 消息与会话操作
    
    /// 添加错误消息到聊天记录
    /// - Parameter content: 错误消息内容
    func addErrorMessage(_ content: String) {
        // 在显示错误前，找到并替换加载指示器
        if let loadingIndex = messages.lastIndex(where: { $0.isLoading }) {
            let errorMessage = ChatMessage(id: messages[loadingIndex].id, role: "error", content: content, isLoading: false)
            messages[loadingIndex] = errorMessage
        } else {
            // 如果没有找到加载指示器（异常情况），则直接添加
            let errorMessage = ChatMessage(id: UUID(), role: "error", content: content)
            messages.append(errorMessage)
        }
        
        if let sessionID = currentSession?.id {
            saveMessages(messages, for: sessionID)
        }
    }
    
    /// 删除指定位置的消息
    /// - Parameter offsets: 要删除的消息索引集合
    func deleteMessage(at offsets: IndexSet) {
        messages.remove(atOffsets: offsets)
        // 删除后立即保存到本地文件
        saveMessages(messages, for: currentSession!.id)
    }
    
    /// 删除指定位置的会话
    /// - Parameter offsets: 要删除的会话索引集合
    ///
    /// 处理流程:
    /// 1. 删除对应的消息文件
    /// 2. 从会话列表中移除
    /// 3. 处理当前会话切换
    /// 4. 保存更新后的会话列表
    func deleteSession(at offsets: IndexSet) {
        let sessionsToDelete = offsets.map { chatSessions[$0] }
        print("🗑️ [Session] 准备删除 \(sessionsToDelete.count) 个会话...")
        
        // 从文件系统中删除对应的消息记录
        for session in sessionsToDelete {
            let fileURL = getChatsDirectory().appendingPathComponent("\(session.id.uuidString).json")
            print("  - 正在删除消息文件: \(fileURL.path)")
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        // 从状态数组中移除会话
        chatSessions.remove(atOffsets: offsets)
        print("  - 已从会话列表中移除。")
        
        // 检查当前会话是否被删除
        if let current = currentSession, sessionsToDelete.contains(where: { $0.id == current.id }) {
            print("  - 当前会话已被删除。正在切换到新会话...")
            // 如果被删除，则选择一个新的会话
            if let firstSession = chatSessions.first {
                currentSession = firstSession
                print("    - 切换到第一个可用会话: \(firstSession.name)")
            } else {
                // 如果没有会话了，创建一个新的
                let newSession = ChatSession(id: UUID(), name: "新的对话", topicPrompt: nil, enhancedPrompt: nil, isTemporary: true)
                chatSessions.append(newSession)
                currentSession = newSession
                print("    - 没有可用会话，已创建新的临时会话。")
            }
        } else if currentSession == nil && !chatSessions.isEmpty {
            // 如果由于某种原因当前没有选中会话，则默认选中第一个
            currentSession = chatSessions.first
            print("  - 当前没有选中会话，已自动切换到第一个可用会话: \(currentSession!.name)")
        }
        
        // 保存更新后的会话列表
        saveChatSessions(chatSessions)
        print("  - ✅ 会话删除操作完成。")
    }

    /// 从现有会话创建分支
    /// - Parameters:
    ///   - sourceSession: 从中创建分支的源会话
    ///   - copyMessages: 是否复制聊天记录
    func branchSession(from sourceSession: ChatSession, copyMessages: Bool) {
        print("🌿 [Session] 准备从会话“\(sourceSession.name)”创建分支...")
        print("  - 是否复制消息: \(copyMessages)")

        // 1. 创建一个新的会话实例
        let newSession = ChatSession(
            id: UUID(),
            name: "分支: \(sourceSession.name)",
            topicPrompt: sourceSession.topicPrompt,
            enhancedPrompt: sourceSession.enhancedPrompt,
            isTemporary: false // 分支会话直接就是非临时的
        )
        print("  - 已创建新会话: \(newSession.name) (\(newSession.id.uuidString))")

        // 2. 如果需要，复制聊天记录
        if copyMessages {
            let sourceMessages = loadMessages(for: sourceSession.id)
            if !sourceMessages.isEmpty {
                saveMessages(sourceMessages, for: newSession.id)
                print("  - 已成功复制 \(sourceMessages.count) 条消息到新会话。")
            } else {
                print("  - 源会话没有消息可复制。")
            }
        }

        // 3. 将新会话插入到列表顶部
        chatSessions.insert(newSession, at: 0)
        print("  - 新会话已添加到列表顶部。")

        // 4. 保存更新后的会话列表
        saveChatSessions(chatSessions)

        // 5. 切换到新的分支会话
        currentSession = newSession
        print("  - 当前会话已切换到新的分支。")
        
        // 6. 关闭设置/会话列表视图
        // 在SessionListView中，我们会调用 dismiss()
        // onSessionSelected(newSession) // 这行代码现在由 SessionListView 的 onSessionSelected 回调处理
    }
    
    /// 判断是否应该为某条消息显示"重试"按钮
    /// - Parameter message: 要检查的消息
    /// - Returns: 是否可以重试该消息
    ///
    /// 支持的重试场景:
    /// - 最后一条是AI回复: 可以重试最后两条消息
    /// - 最后一条是用户提问: 可以重试最后一条消息
    func canRetry(message: ChatMessage) -> Bool {
        guard let lastMessage = messages.last else { return false }
        
        // 场景A: 最后一条是AI回复或错误提示 -> 最后两条都可以重试
        if lastMessage.role == "assistant" || lastMessage.role == "error" {
            guard messages.count >= 2 else { return false }
            let secondLastMessage = messages[messages.count - 2]
            // 必须是用户提问 + AI回答/错误的组合
            guard secondLastMessage.role == "user" else { return false }
            return message.id == lastMessage.id || message.id == secondLastMessage.id
        }
        // 场景B: 最后一条是用户提问 (例如AI未应答时退出) -> 只有这条可以重试
        else if lastMessage.role == "user" {
            return message.id == lastMessage.id
        }
        
        return false
    }

    /// 重新生成最后一条 AI 消息
    ///
    /// 功能:
    /// - 移除之前的消息
    /// - 重新发送用户问题
    /// - 触发新的AI回复
    func retryLastMessage() {
        guard let lastMessage = messages.last else { return }
        
        var userQuery = ""
        
        // 如果最后一条是AI回复或错误，则移除用户和AI/错误的两条消息
        if (lastMessage.role == "assistant" || lastMessage.role == "error") && messages.count >= 2 && messages[messages.count - 2].role == "user" {
            userQuery = messages[messages.count - 2].content
            messages.removeLast(2)
        }
        // 如果最后一条是用户提问，则只移除用户消息
        else if lastMessage.role == "user" {
            userQuery = lastMessage.content
            messages.removeLast()
        }
        
        // 如果找到了有效的用户问题，则重新发送
        if !userQuery.isEmpty {
            Task {
                await sendAndProcessMessage(content: userQuery)
            }
        }
    }
    
    // MARK: - 屏幕常亮管理
    // ============================================================================
    
    /// 启动一个 watchOS 延长运行时间的会话，以在等待AI响应时保持屏幕常亮
    private func startExtendedSession() {
        // 如果已有会话在运行，先停止它
        if extendedSession != nil {
            stopExtendedSession()
        }
        
        print("🔆 [Session] 正在启动屏幕常亮会话...")
        extendedSession = WKExtendedRuntimeSession()
        extendedSession?.start()
    }
    
    /// 停止当前的延长运行时间会话
    private func stopExtendedSession() {
        if let session = extendedSession, session.state == .running {
            print("🔆 [Session] 正在停止屏幕常亮会话。")
            session.invalidate()
            extendedSession = nil
        }
    }
   
   // MARK: - 导出函数
   // ============================================================================
   
    /// 通过网络将指定的会话导出到目标IP地址
    /// - Parameters:
    ///   - session: 要导出的会话
    ///   - ipAddress: 目标 IP:Port 字符串
    ///   - completion: 用于更新UI状态的回调
    func exportSessionViaNetwork(session: ChatSession, ipAddress: String, completion: @escaping (ExportStatus) -> Void) {
        print("🚀 [Export] 准备通过网络导出...")
        print("  - 目标会话: \(session.name) (\(session.id.uuidString))")
        print("  - 目标地址: \(ipAddress)")

        // 1. 准备数据
        let messagesToExport = loadMessages(for: session.id)
        let exportableMessages = messagesToExport.map {
            ExportableChatMessage(role: $0.role, content: $0.content, reasoningContent: $0.reasoningContent)
        }
        let promptsToExport = ExportPrompts(
            globalSystemPrompt: self.systemPrompt.isEmpty ? nil : self.systemPrompt,
            topicPrompt: session.topicPrompt,
            enhancedPrompt: session.enhancedPrompt
        )
        let fullExportData = FullExportData(prompts: promptsToExport, history: exportableMessages)

        // 2. 编码为JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let jsonData = try? encoder.encode(fullExportData) else {
            print("  - ❌ 错误: 无法将消息编码为JSON。")
            completion(.failed("无法编码JSON"))
            return
        }

        // 3. 创建URL和请求
        guard let url = URL(string: "http://\(ipAddress)") else {
            print("  - ❌ 错误: 无效的IP地址格式。")
            completion(.failed("无效的IP地址格式"))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 60 // 设置60秒超时

        // 4. 发送请求
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("  - ❌ 网络错误: \(error.localizedDescription)")
                    completion(.failed("网络错误: \(error.localizedDescription)"))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("  - ❌ 服务器错误: 状态码 \(statusCode)")
                    completion(.failed("服务器错误: 状态码 \(statusCode)"))
                    return
                }
                
                print("  - ✅ 导出成功！")
                completion(.success)
            }
        }.resume()
    }
}



// MARK: - 辅助视图
// ============================================================================

// MARK: - 编辑消息视图 

/// 用于编辑单条消息内容的视图
struct EditMessageView: View {
    @Binding var message: ChatMessage
    var onSave: (ChatMessage) -> Void // 保存时的回调
    @Environment(\.dismiss) var dismiss

    @State private var newContent: String

    // 自定义初始化器，用于从绑定中设置初始状态
    init(message: Binding<ChatMessage>, onSave: @escaping (ChatMessage) -> Void) {
        _message = message
        self.onSave = onSave
        _newContent = State(initialValue: message.wrappedValue.content)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // 使用 TextField 并设置 axis 为 .vertical 来允许多行输入
                TextField("编辑消息", text: $newContent, axis: .vertical)
                    .lineLimit(5...15) // 限制显示的行数范围
                    .textFieldStyle(.plain)
                    .padding()

                Button("保存") {
                    message.content = newContent
                    onSave(message) // 调用回调来触发保存
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("编辑消息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 聊天气泡视图 

/// 聊天消息气泡组件
/// 显示单条聊天消息，支持AI思考过程的展开/折叠功能
/// watchOS兼容版本，使用Button替代DisclosureGroup
///
/// 特性:
/// - 支持用户和AI消息的不同样式
/// - 可展开的思考过程显示
/// - Markdown内容渲染支持
struct ChatBubble: View {
    let message: ChatMessage  // 要显示的消息
    let enableMarkdown: Bool  // 是否启用Markdown渲染
    let enableBackground: Bool // 是否启用背景
    
    // 每个气泡独立管理自己的思考过程展开状态
    @State private var isReasoningExpanded: Bool = false
    
    var body: some View {
        HStack {
            if message.role == "user" {
                // 用户消息：右对齐，蓝色背景
                Spacer()
                renderContent(message.content)
                    .padding(10)
                    .background(enableBackground ? Color.blue.opacity(0.7) : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            } else if message.role == "error" {
                // 错误消息
                Text(message.content)
                    .padding(10)
                    .background(enableBackground ? Color.red.opacity(0.7) : Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                Spacer()
            } else {
                // AI消息或加载指示器：左对齐
                VStack(alignment: .leading, spacing: 5) {
                    // 思考过程：只要有reasoningContent就显示灯泡
                    if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                        Button(action: { withAnimation { isReasoningExpanded.toggle() } }) {
                            Label("显示思考过程", systemImage: isReasoningExpanded ? "lightbulb.slash.fill" : "lightbulb.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 4)

                        if isReasoningExpanded {
                            Text(reasoning)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(10)
                                .background(enableBackground ? Color.black.opacity(0.2) : Color(white: 0.15))
                                .cornerRadius(12)
                                .transition(.opacity)
                        }
                    }
                    
                    // 消息内容：只要有content就显示
                    if !message.content.isEmpty {
                        renderContent(message.content)
                    }

                    // 加载指示器：当isLoading为true时显示
                    if message.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在思考...")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(enableBackground ? Color.black.opacity(0.3) : Color(white: 0.3))
                .cornerRadius(12)
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    /// 根据设置动态渲染内容
    /// - Parameter content: 要渲染的文本内容
    /// - Returns: 渲染后的视图
    ///
    /// 根据enableMarkdown设置决定使用Markdown渲染还是普通文本
    @ViewBuilder
    private func renderContent(_ content: String) -> some View {
        if enableMarkdown {
            Markdown(content)
        } else {
            Text(content)
        }
    }
}

// MARK: - 设置视图 

/// 设置视图
/// 提供模型选择和多会话管理功能
///
/// 包含功能:
/// - AI模型选择和高级参数设置
/// - 会话管理和历史记录查看
/// - 显示偏好设置调整
/// - 背景图片选择和自定义
struct SettingsView: View {
    @Binding var selectedModel: AIModelConfig
    let allModels: [AIModelConfig]
    
    @Binding var sessions: [ChatSession]
    @Binding var currentSession: ChatSession?
    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
    @Binding var systemPrompt: String
    @Binding var maxChatHistory: Int
    @Binding var enableStreaming: Bool // 接收绑定
    @Binding var enableMarkdown: Bool
    @Binding var enableBackground: Bool
    @Binding var backgroundBlur: Double
    @Binding var backgroundOpacity: Double
    let allBackgrounds: [String] // 传递所有背景图片名称
    @Binding var currentBackgroundImage: String // 传递当前背景图的绑定
    @Binding var enableAutoRotateBackground: Bool // 传递自动轮换开关的绑定
    let deleteAction: (IndexSet) -> Void
    let branchAction: (ChatSession, Bool) -> Void
    let exportAction: (ChatSession) -> Void // 新增：导出操作
    
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                // 模型选择区域
                Section(header: Text("模型设置")) {
                    Picker("当前模型", selection: $selectedModel) {
                        ForEach(allModels) { config in
                            Text(config.name).tag(config)
                        }
                    }
                    
                    // 只有在当前会话存在时才显示高级设置
                    if currentSession != nil {
                        NavigationLink(destination: ModelAdvancedSettingsView(
                            aiTemperature: $aiTemperature,
                            aiTopP: $aiTopP,
                            systemPrompt: $systemPrompt,
                            maxChatHistory: $maxChatHistory,
                            enableStreaming: $enableStreaming,
                            // 传递当前会话的绑定，以便修改话题提示词
                            currentSession: $currentSession
                        )) {
                            Text("高级设置")
                        }
                    }
                }
                
                // 对话管理区域
                Section(header: Text("对话管理")) {
                    NavigationLink(destination: SessionListView(
                        sessions: $sessions,
                        currentSession: $currentSession,
                        deleteAction: deleteAction,
                        branchAction: branchAction,
                        exportAction: exportAction, // 传递导出操作
                        onSessionSelected: { selectedSession in
                            currentSession = selectedSession
                            dismiss()
                        }
                    )) {
                        Text("历史会话")
                    }
                    
                    Button("开启新对话") {
                        let newSession = ChatSession(id: UUID(), name: "新的对话", topicPrompt: nil, enhancedPrompt: nil, isTemporary: true)
                        sessions.insert(newSession, at: 0)
                        currentSession = newSession
                        dismiss()
                    }
                    
                }

                // 显示设置区域
                Section(header: Text("显示设置")) {
                    Toggle("渲染 Markdown", isOn: $enableMarkdown)
                    Toggle("显示背景", isOn: $enableBackground)
                    
                    if enableBackground {
                        VStack(alignment: .leading) {
                            Text("背景模糊: \(String(format: "%.1f", backgroundBlur))")
                            Slider(value: $backgroundBlur, in: 0...25, step: 0.5)
                        }
                        
                        VStack(alignment: .leading) {
                            Text("背景不透明度: \(String(format: "%.2f", backgroundOpacity))")
                            Slider(value: $backgroundOpacity, in: 0.1...1.0, step: 0.05)
                        }
                        
                        Toggle("背景随机轮换", isOn: $enableAutoRotateBackground)
                        
                        if !enableAutoRotateBackground {
                            NavigationLink(destination: BackgroundPickerView(
                                allBackgrounds: allBackgrounds,
                                selectedBackground: $currentBackgroundImage
                            )) {
                                Text("选择背景")
                            }
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                Button("完成") { dismiss() }
            }
        }
    }
}

// MARK: - 会话管理视图

/// 会话历史列表视图
/// 在一个独立的页面显示所有历史会话，并处理选择和删除操作
///
/// 功能:
/// - 显示所有保存的会话
/// - 支持会话切换和删除
/// - 提供会话分享功能
// 新增：用于编辑会话名称的视图
struct EditSessionNameView: View {
    @Binding var session: ChatSession
    @Binding var sessions: [ChatSession]
    @Environment(\.dismiss) var dismiss

    @State private var newName: String

    // 自定义初始化器，用于从绑定中设置初始状态
    init(session: Binding<ChatSession>, sessions: Binding<[ChatSession]>) {
        _session = session
        _sessions = sessions
        _newName = State(initialValue: session.wrappedValue.name)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TextField("输入新名称", text: $newName)
                    .textFieldStyle(.plain)
                    .padding()

                Button("保存") {
                    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                        sessions[index].name = newName
                        saveChatSessions(sessions) // 直接调用全局函数
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("编辑话题")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}


struct SessionListView: View {
    @Binding var sessions: [ChatSession]
    @Binding var currentSession: ChatSession?
    let deleteAction: (IndexSet) -> Void
    let branchAction: (ChatSession, Bool) -> Void
    let exportAction: (ChatSession) -> Void // 新增：接收导出操作
    let onSessionSelected: (ChatSession) -> Void
    
    // 用于删除确认的状态
    @State private var showDeleteSessionConfirm: Bool = false
    @State private var sessionIndexToDelete: IndexSet?
    
    // 用于编辑会话名称的状态
    @State private var sessionToEdit: ChatSession?
    
    // 新增：用于分支功能的状态
    @State private var showBranchOptions: Bool = false
    @State private var sessionToBranch: ChatSession?
    
    var body: some View {
        List {
            ForEach(sessions) { session in
                Button(action: {
                    onSessionSelected(session)
                }) {
                    HStack {
                        Text(session.name)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if currentSession?.id == session.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .swipeActions(edge: .leading) { // 改为右滑
                    NavigationLink {
                        // 导航到新的二级菜单页面
                        SessionActionsView(
                            session: session,
                            sessionToEdit: $sessionToEdit,
                            sessionToBranch: $sessionToBranch,
                            showBranchOptions: $showBranchOptions,
                            sessionIndexToDelete: $sessionIndexToDelete,
                            showDeleteSessionConfirm: $showDeleteSessionConfirm,
                            sessions: $sessions,
                            onExport: {
                                exportAction(session)
                                // 导出后不需要关闭此页面，由ContentView管理sheet
                            }
                        )
                    } label: {
                        Label("更多", systemImage: "ellipsis.circle.fill")
                    }
                    .tint(.gray)
                }
            }
        }
        .navigationTitle("历史会话")
        .sheet(item: $sessionToEdit) { sessionToEdit in
            // sessionToEdit 现在是闭包的参数，不再是可选类型
            if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionToEdit.id }) {
                
                let sessionBinding = $sessions[sessionIndex]
                
                EditSessionNameView(session: sessionBinding, sessions: $sessions)
            }
        }
        // 会话删除确认对话框
        .confirmationDialog("确认删除", isPresented: $showDeleteSessionConfirm, titleVisibility: .visible) {
            Button("删除会话", role: .destructive) {
                if let indexSet = sessionIndexToDelete {
                    deleteAction(indexSet)
                }
                sessionIndexToDelete = nil
            }
            Button("取消", role: .cancel) {
                sessionIndexToDelete = nil
            }
        } message: {
            Text("您确定要删除这个会话及其所有消息吗？此操作无法撤销。")
        }
        // 新增：分支选项对话框
        .confirmationDialog("创建分支", isPresented: $showBranchOptions, titleVisibility: .visible) {
            Button("仅分支提示词") {
                if let session = sessionToBranch {
                    branchAction(session, false)
                    // 找到新创建的分支会话并切换过去
                    if let newSession = sessions.first(where: { $0.name == "分支: \(session.name)" && $0.id != session.id }) {
                        onSessionSelected(newSession)
                    }
                }
            }
            Button("分支提示词和对话记录") {
                if let session = sessionToBranch {
                    branchAction(session, true)
                    // 找到新创建的分支会话并切换过去
                    if let newSession = sessions.first(where: { $0.name == "分支: \(session.name)" && $0.id != session.id }) {
                        onSessionSelected(newSession)
                    }
                }
            }
            Button("取消", role: .cancel) {
                sessionToBranch = nil
            }
        } message: {
            if let session = sessionToBranch {
                Text("从“\(session.name)”创建新的分支对话。")
            }
        }
    }
}

// MARK: - 背景选择器视图 

/// 背景图片选择器视图
/// 以网格形式展示所有可选的背景图片，并允许用户点击选择
///
/// 布局: 2列网格布局
/// 交互: 点击选择背景，选中状态有边框提示
struct BackgroundPickerView: View {
    let allBackgrounds: [String]
    @Binding var selectedBackground: String
    
    // 定义网格布局
    private let columns: [GridItem] = Array(repeating: .init(.flexible()), count: 2)
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(allBackgrounds, id: \.self) { bgName in
                    Button(action: {
                        selectedBackground = bgName
                    }) {
                        Image(bgName)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 100)
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(selectedBackground == bgName ? Color.blue : Color.clear, lineWidth: 3)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("选择背景")
    }
}

// MARK: - 高级模型设置视图 

/// 高级模型设置视图
/// 提供 Temperature, Top P, 和 System Prompt 的调整功能
///
/// 参数说明:
/// - Temperature: 控制输出的随机性 (0.0-2.0)
/// - Top P: 控制输出的多样性 (0.0-1.0)
/// - System Prompt: 自定义系统提示词
struct ModelAdvancedSettingsView: View {
    @Binding var aiTemperature: Double
    @Binding var aiTopP: Double
    @Binding var systemPrompt: String // 全局系统提示词
    @Binding var maxChatHistory: Int
    @Binding var enableStreaming: Bool
    @Binding var currentSession: ChatSession? // 当前会话
    
    // 用于TextField的Formatter，确保只输入数字
    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }
    
    var body: some View {
        Form {
            Section(header: Text("全局系统提示词")) {
                TextField("自定义全局系统提示词", text: $systemPrompt, axis: .vertical)
                    .lineLimit(5...10)
            }
            
            // 新增：话题提示词编辑区域
            Section(header: Text("当前话题提示词"), footer: Text("仅对当前对话生效。")) {
                // 使用非可选绑定来安全地编辑 topicPrompt
                TextField("自定义话题提示词", text: Binding(
                    get: { currentSession?.topicPrompt ?? "" },
                    set: { currentSession?.topicPrompt = $0 }
                ), axis: .vertical)
                .lineLimit(5...10)
            }
            
            // 新增：增强提示词编辑区域
            Section(header: Text("增强提示词"), footer: Text("该提示词会附加在您的最后一条消息末尾，以增强指令效果。")) {
                TextField("自定义增强提示词", text: Binding(
                    get: { currentSession?.enhancedPrompt ?? "" },
                    set: { currentSession?.enhancedPrompt = $0 }
                ), axis: .vertical)
                .lineLimit(5...10)
            }
            
            Section(header: Text("输出设置")) {
                Toggle("流式输出", isOn: $enableStreaming)
            }
            
            Section(header: Text("参数调整")) {
                VStack(alignment: .leading) {
                    Text("模型温度 (Temperature): \(String(format: "%.2f", aiTemperature))")
                    Slider(value: $aiTemperature, in: 0.0...2.0, step: 0.05)
                        .onChange(of: aiTemperature) {
                            aiTemperature = (aiTemperature * 100).rounded() / 100
                        }
                }
                
                VStack(alignment: .leading) {
                    Text("核采样 (Top P): \(String(format: "%.2f", aiTopP))")
                    Slider(value: $aiTopP, in: 0.0...1.0, step: 0.05)
                        .onChange(of: aiTopP) {
                            aiTopP = (aiTopP * 100).rounded() / 100
                        }
                }
            }
            
            Section(header: Text("上下文管理"), footer: Text("设置发送到模型的最近消息数量。例如，设置为10将只发送最后5条用户消息和5条AI回复。设置为0表示不限制。")) {
                HStack {
                    Text("最大上下文消息数")
                    Spacer() // 添加一个Spacer将输入框推到右边
                    TextField("数量", value: $maxChatHistory, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60) // 限制输入框的最大宽度
                }
            }
        }
        .navigationTitle("高级模型设置")
    }
}

// MARK: - 操作菜单
// ============================================================================

struct MessageActionsView: View {
    let message: ChatMessage
    let canRetry: Bool
    let onEdit: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void
    
    @Environment(\.dismiss) var dismiss

    var body: some View {
        Form {
            Section {
                // 编辑按钮
                Button {
                    onEdit()
                    dismiss()
                } label: {
                    Label("编辑消息", systemImage: "pencil")
                }

                // 重试按钮
                if canRetry {
                    Button {
                        onRetry()
                        dismiss()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
            }
            
            Section {
                // 删除按钮
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("删除消息", systemImage: "trash.fill")
                }
            }
        }
        .navigationTitle("操作")
        .navigationBarTitleDisplayMode(.inline)
    }
}


struct SessionActionsView: View {
    let session: ChatSession
    @Binding var sessionToEdit: ChatSession?
    @Binding var sessionToBranch: ChatSession?
    @Binding var showBranchOptions: Bool
    @Binding var sessionIndexToDelete: IndexSet?
    @Binding var showDeleteSessionConfirm: Bool
    @Binding var sessions: [ChatSession]
    let onExport: () -> Void // 新增：导出闭包
    
    @Environment(\.dismiss) var dismiss

    var body: some View {
        Form {
            Section {
                // 编辑按钮
                Button {
                    sessionToEdit = session
                    dismiss() // 关闭此页面以触发上一页的 .sheet
                } label: {
                    Label("编辑话题", systemImage: "pencil")
                }

                // 分支按钮
                Button {
                    sessionToBranch = session
                    showBranchOptions = true
                    dismiss() // 关闭此页面以触发上一页的 .confirmationDialog
                } label: {
                    Label("创建分支", systemImage: "arrow.branch")
                }

                // 导出按钮
                Button {
                    onExport()
                    dismiss()
                } label: {
                    Label("通过网络导出", systemImage: "wifi")
                }
            }
            
            Section {
                // 删除按钮
                Button(role: .destructive) {
                    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                        sessionIndexToDelete = IndexSet(integer: index)
                        showDeleteSessionConfirm = true
                        dismiss() // 关闭此页面以触发上一页的 .confirmationDialog
                    }
                } label: {
                    Label("删除会话", systemImage: "trash.fill")
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 数据持久化
// ============================================================================

/// 获取用于存储聊天记录的目录URL
/// - Returns: 存储目录的URL路径
func getChatsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let chatsDirectory = paths[0].appendingPathComponent("ChatSessions")
    if !FileManager.default.fileExists(atPath: chatsDirectory.path) {
        print("💾 [Persistence] 聊天记录目录不存在，正在创建: \(chatsDirectory.path)")
        try? FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)
    }
    return chatsDirectory
}

/// 保存所有聊天会话的列表
func saveChatSessions(_ sessions: [ChatSession]) {
    // 在保存前，过滤掉所有临时的会话
    let sessionsToSave = sessions.filter { !$0.isTemporary }
    
    let fileURL = getChatsDirectory().appendingPathComponent("sessions.json")
    print("💾 [Persistence] 准备保存会话列表...")
    print("  - 目标路径: \(fileURL.path)")
    print("  - 将要保存 \(sessionsToSave.count) 个会话。")

    do {
        let data = try JSONEncoder().encode(sessionsToSave)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        print("  - ✅ 会话列表保存成功。")
    } catch {
        print("  - ❌ 保存会话列表失败: \(error.localizedDescription)")
    }
}

/// 加载所有聊天会话的列表
func loadChatSessions() -> [ChatSession] {
    let fileURL = getChatsDirectory().appendingPathComponent("sessions.json")
    print("💾 [Persistence] 准备加载会话列表...")
    print("  - 目标路径: \(fileURL.path)")

    do {
        let data = try Data(contentsOf: fileURL)
        let loadedSessions = try JSONDecoder().decode([ChatSession].self, from: data)
        print("  - ✅ 成功加载了 \(loadedSessions.count) 个会话。")
        return loadedSessions
    } catch {
        print("  - ⚠️ 加载会话列表失败: \(error.localizedDescription)。将返回空列表。")
        return []
    }
}

/// 保存指定会话的聊天消息
func saveMessages(_ messages: [ChatMessage], for sessionID: UUID) {
    let fileURL = getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    print("💾 [Persistence] 准备保存消息...")
    print("  - 会话ID: \(sessionID.uuidString)")
    print("  - 目标路径: \(fileURL.path)")
    print("  - 将要保存 \(messages.count) 条消息。")

    do {
        let data = try JSONEncoder().encode(messages)
        try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        print("  - ✅ 消息保存成功。")
    } catch {
        print("  - ❌ 保存消息失败: \(error.localizedDescription)")
    }
}

/// 加载指定会话的聊天消息
func loadMessages(for sessionID: UUID) -> [ChatMessage] {
    let fileURL = getChatsDirectory().appendingPathComponent("\(sessionID.uuidString).json")
    print("💾 [Persistence] 准备加载消息...")
    print("  - 会话ID: \(sessionID.uuidString)")
    print("  - 目标路径: \(fileURL.path)")

    do {
        let data = try Data(contentsOf: fileURL)
        let loadedMessages = try JSONDecoder().decode([ChatMessage].self, from: data)
        print("  - ✅ 成功加载了 \(loadedMessages.count) 条消息。")
        return loadedMessages
    } catch {
        print("  - ⚠️ 加载消息失败: \(error.localizedDescription)。将返回空列表。")
        return []
    }
}

// MARK: - 导出功能
// ============================================================================

/// 导出状态枚举
enum ExportStatus {
    case idle
    case exporting
    case success
    case failed(String)
}

/// 用于通过网络导出聊天记录的视图
struct ExportView: View {
    let session: ChatSession
    let onExport: (ChatSession, String, @escaping (ExportStatus) -> Void) -> Void
    
    @State private var ipAddress: String = ""
    @State private var status: ExportStatus = .idle
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("导出会话: \(session.name)")
                        .font(.headline)
                        .padding(.bottom, 10)

                    TextField("输入 IP:Port", text: $ipAddress)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)

                    Button(action: export) {
                        Text("发送到电脑")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ipAddress.isEmpty || {
                        if case .exporting = status { return true }
                        return false
                    }())

                    Spacer()

                    statusView
                        .padding(.top, 10)
                }
                .padding()
            }
            .navigationTitle("网络导出")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    /// 根据当前状态显示不同的视图
    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Text("请输入您电脑上接收端的 IP 地址和端口号。")
                .font(.caption)
                .foregroundColor(.secondary)
        case .exporting:
            ProgressView("正在导出...")
        case .success:
            VStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.green)
                Text("导出成功！")
            }
        case .failed(let error):
            VStack {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.red)
                Text("导出失败")
                    .font(.headline)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    /// 执行导出操作
    private func export() {
        status = .exporting
        // 调用 onExport 闭包，并传递一个回调来更新状态
        onExport(session, ipAddress) { newStatus in
            self.status = newStatus
        }
    }
}

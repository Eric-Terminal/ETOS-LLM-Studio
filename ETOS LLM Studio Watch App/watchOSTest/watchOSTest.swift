//
//  watchOSTest.swift
//  watchOSTest
//
//  Created by Eric on 2025/10/6.
//
//  ============================================================================
//  ChatViewModel Unit Tests
//  ============================================================================
//  本文件包含针对 ChatViewModel 的单元测试。
//
//  测试策略:
//  - **模拟依赖**: 使用一个模拟的 `MockChatService` 来隔离 `ChatViewModel`，
//    使其不受网络或文件系统等外部依赖的影响。
//  - **行为验证**: 验证当调用 `ChatViewModel` 的方法时，它是否正确地
//    调用了 `ChatService` 的相应方法。
//  - **状态验证**: 验证 `ChatViewModel` 的 `@Published` 属性（UI状态）
//    是否根据业务逻辑正确更新。
//  ============================================================================

import Testing
import Combine
import Foundation
@testable import Shared // 允许我们访问 Shared 模块中的 internal 类型
@testable import ETOS_LLM_Studio_Watch_App_Watch_App // 允许我们访问 App 的 internal 类型

// MARK: - MockChatService

/// 这是一个模拟的 ChatService，用于在测试中隔离 ChatViewModel。
/// 它允许我们控制 `sendMessage` 的行为，而无需实际进行网络调用。
class MockChatService: ChatService {
    
    /// 一个可配置的闭包，用于在 `sendAndProcessMessage` 被调用时执行自定义逻辑。
    var sendMessageHandler: ((String) -> Void)?
    
    /// 重写 `sendAndProcessMessage` 方法。
    /// 当测试代码调用 `viewModel.sendMessage()` 时，这个方法会被执行。
    override func sendAndProcessMessage(
        content: String,
        aiTemperature: Double,
        aiTopP: Double,
        systemPrompt: String,
        maxChatHistory: Int,
        enableStreaming: Bool,
        enhancedPrompt: String?,
        enableMemory: Bool,
        enableMemoryWrite: Bool,
        includeSystemTime: Bool,
        audioAttachment: AudioAttachment? = nil
    ) async {
        // 调用我们自定义的处理程序，以便在测试中验证行为。
        sendMessageHandler?(content)
    }
}


// MARK: - ChatViewModelTests

@MainActor
@Suite("ChatViewModel Tests")
struct ChatViewModelTests {

    var viewModel: ChatViewModel!
    var mockChatService: MockChatService!
    var cancellables: Set<AnyCancellable>!

    init() {
        // 在每个测试运行前，重置所有状态
        cancellables = []
        
        // 1. 创建模拟服务
        mockChatService = MockChatService(adapters: [:], memoryManager: .shared, urlSession: .shared)
        
        // 2. 使用新的初始化方法注入模拟服务
        viewModel = ChatViewModel(chatService: mockChatService)
    }

    @Test("Test sendMessage - Success Case")
    func testSendMessageSuccess() async throws {
        // --- 准备 (Arrange) ---
        
        let testMessage = "你好，世界！"
        viewModel.userInput = testMessage
        
        // 使用 withCheckedContinuation 等待异步回调
        let receivedContent = await withCheckedContinuation { continuation in
            // 设置模拟服务的处理程序
            mockChatService.sendMessageHandler = { content in
                // 当回调被触发时，恢复挂起的测试并返回值
                continuation.resume(returning: content)
            }
            
            // --- 执行 (Act) ---
            viewModel.sendMessage()
        }

        // --- 断言 (Assert) ---
        
        // 验证传递给服务层的消息内容是否正确
        #expect(receivedContent == testMessage, "传递给服务层的消息内容应与用户输入一致")
        
        // 验证用户的输入框在发送后是否被清空
        #expect(viewModel.userInput.isEmpty, "发送消息后，用户输入框应该被清空")
    }
    
    @Test("Test sendMessage - Empty Input")
    func testSendMessageWithEmptyInput() {
        // --- 准备 (Arrange) ---
        
        viewModel.userInput = ""
        
        // 设置一个标志，如果 `sendAndProcessMessage` 被意外调用，就将其设为 true
        var sendMessageWasCalled = false
        mockChatService.sendMessageHandler = { _ in
            sendMessageWasCalled = true
        }

        // --- 执行 (Act) ---
        
        viewModel.sendMessage()

        // --- 断言 (Assert) ---
        
        // 验证 `sendAndProcessMessage` 从未被调用
        #expect(!sendMessageWasCalled, "当输入为空时，不应该调用发送消息的方法")
    }
    
    @Test("Test ViewModel Initialization - Subscriptions and Initial State")
    func testViewModelInitialization() async {
        // --- 准备 (Arrange) ---
        
        let initialSessions = [ChatSession(id: UUID(), name: "初始会话")]
        let initialProviders = [Provider(name: "初始提供商", baseURL: "", apiKeys: [], apiFormat: "")]
        
        // --- 执行 (Act) ---
        
        // 模拟来自 ChatService 的数据更新
        mockChatService.chatSessionsSubject.send(initialSessions)
        mockChatService.providersSubject.send(initialProviders)
        
        // 关键修复：等待一个 run loop 周期，让 Combine 的 .receive(on: DispatchQueue.main) 生效
        await Task.yield()
        
        // --- 断言 (Assert) ---
        
        // 现在断言应该会成功
        #expect(viewModel.chatSessions.count == initialSessions.count, "ViewModel 应该订阅并接收来自 ChatService 的会话更新")
        #expect(viewModel.chatSessions.first?.name == "初始会话", "会话数据应该匹配")
        
        #expect(viewModel.providers.count == initialProviders.count, "ViewModel 应该订阅并接收提供商的更新")
        #expect(viewModel.providers.first?.name == "初始提供商", "提供商数据应该匹配")
    }
}

// ============================================================================
// SharedTests.swift
// ============================================================================
// SharedTests 测试文件
// - 覆盖相关模块的行为与回归测试
// - 保障迭代过程中的稳定性
// ============================================================================

//
//  SharedTests.swift
//  SharedTests
//
//  Created by Eric on 2025/10/5.
//

import Testing
import Foundation
@testable import Shared
import Combine
import SwiftUI
import SQLite3

@Suite("聊天界面架构默认值测试")

@Suite("ChatService Integration Tests")
struct ChatServiceTests {
    
    // 在所有测试之间共享的变量
    var memoryManager: MemoryManager!
    var mockAdapter: MockAPIAdapter! 
    var chatService: ChatService! 
    var dummyModel: RunnableModel! 

    // swift-testing 的初始化方法，在每个测试运行前被调用
    init() async {
        for provider in ConfigLoader.loadProviders() {
            ConfigLoader.deleteProvider(provider)
        }
        let seededProviders = [
            Provider(
                name: "Chat Service Test Primary",
                baseURL: "https://fake.url",
                apiKeys: ["key-primary"],
                apiFormat: "openai-compatible",
                models: [
                    Model(modelName: "test-model", displayName: "Test Model", isActivated: true)
                ]
            ),
            Provider(
                name: "Chat Service Test Secondary",
                baseURL: "https://fake.url",
                apiKeys: ["key-secondary"],
                apiFormat: "openai-compatible",
                models: [
                    Model(modelName: "title-model", displayName: "Title Model", isActivated: true)
                ]
            )
        ]
        for provider in seededProviders {
            ConfigLoader.saveProvider(provider)
        }
        ShortcutToolStore.saveTools([])
        await MainActor.run {
            ShortcutToolManager.shared.reloadFromDisk()
            ShortcutToolManager.shared.setChatToolsEnabled(false)
        }

        memoryManager = MemoryManager(embeddingGenerator: MemoryManagerTests.MockEmbeddingGenerator())
        await memoryManager.waitForInitialization()
        
        mockAdapter = MockAPIAdapter()

        // --- 新增：设置模拟网络会话 ---
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self] // 使用我们的模拟协议
        let mockSession = URLSession(configuration: config)
        // --- 结束设置 ---

        // 将模拟会话和适配器注入 ChatService
        chatService = ChatService(adapters: ["openai-compatible": mockAdapter], memoryManager: memoryManager, urlSession: mockSession)
        
        dummyModel = RunnableModel(
            provider: seededProviders[0],
            model: seededProviders[0].models[0]
        )
        chatService.setSelectedModel(dummyModel)
    }
}

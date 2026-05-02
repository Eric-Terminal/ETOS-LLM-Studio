// ============================================================================
// SharedTests+OpenAIAdapterTests.swift
// ============================================================================
// OpenAIAdapterTests 的共享适配器实例与基础测试夹具。
// ============================================================================

import Testing
import Foundation
@testable import Shared
import Combine
import SwiftUI
import SQLite3

@Suite("聊天界面架构默认值测试")

// MARK: - OpenAIAdapter Tests

@Suite("OpenAIAdapter Tests")
struct OpenAIAdapterTests {

    let adapter = OpenAIAdapter()
    let dummyModel = RunnableModel(
        provider: Provider(
            id: UUID(),
            name: "Test Provider",
            baseURL: "https://api.test.com/v1",
            apiKeys: ["test-key"],
            apiFormat: "openai-compatible"
        ),
        model: Model(modelName: "test-model")
    )
}

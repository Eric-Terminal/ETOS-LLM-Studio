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

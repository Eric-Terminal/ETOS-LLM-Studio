// ============================================================================
// MessageVersionTests.swift
// ============================================================================
// 测试多版本历史消息功能
// - 验证旧格式数据的兼容性
// - 验证新格式数据的读写
// - 验证版本切换功能
// ============================================================================

import XCTest
@testable import Shared

final class MessageVersionTests: XCTestCase {
    
    // MARK: - 兼容性测试
    
    /// 测试旧格式（单字符串 content）的反序列化
    func testDecodeLegacyFormat() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "role": "user",
            "content": "Hello, world!"
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let message = try decoder.decode(ChatMessage.self, from: data)
        
        XCTAssertEqual(message.content, "Hello, world!")
        XCTAssertEqual(message.getAllVersions(), ["Hello, world!"])
        XCTAssertEqual(message.getCurrentVersionIndex(), 0)
        XCTAssertFalse(message.hasMultipleVersions)
    }
    
    /// 测试新格式（多版本数组）的反序列化
    func testDecodeNewFormat() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "role": "assistant",
            "content": ["First version", "Second version", "Third version"],
            "currentVersionIndex": 1
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let message = try decoder.decode(ChatMessage.self, from: data)
        
        XCTAssertEqual(message.content, "Second version")
        XCTAssertEqual(message.getAllVersions(), ["First version", "Second version", "Third version"])
        XCTAssertEqual(message.getCurrentVersionIndex(), 1)
        XCTAssertTrue(message.hasMultipleVersions)
    }
    
    /// 测试新格式序列化
    func testEncodeNewFormat() throws {
        var message = ChatMessage(
            role: .assistant,
            content: "Initial content"
        )
        message.addVersion("Updated content")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(message)
        let jsonString = String(data: data, encoding: .utf8)!
        
        XCTAssertTrue(jsonString.contains("\"content\""))
        XCTAssertTrue(jsonString.contains("currentVersionIndex"))
        XCTAssertTrue(jsonString.contains("Initial content"))
        XCTAssertTrue(jsonString.contains("Updated content"))
    }
    
    // MARK: - 版本管理功能测试
    
    /// 测试添加版本
    func testAddVersion() {
        var message = ChatMessage(role: .user, content: "Version 1")
        
        XCTAssertEqual(message.getAllVersions().count, 1)
        XCTAssertFalse(message.hasMultipleVersions)
        
        message.addVersion("Version 2")
        
        XCTAssertEqual(message.getAllVersions().count, 2)
        XCTAssertTrue(message.hasMultipleVersions)
        XCTAssertEqual(message.content, "Version 2")
        XCTAssertEqual(message.getCurrentVersionIndex(), 1)
        
        message.addVersion("Version 3")
        
        XCTAssertEqual(message.getAllVersions().count, 3)
        XCTAssertEqual(message.content, "Version 3")
        XCTAssertEqual(message.getCurrentVersionIndex(), 2)
    }
    
    /// 测试切换版本
    func testSwitchVersion() {
        var message = ChatMessage(role: .assistant, content: "V1")
        message.addVersion("V2")
        message.addVersion("V3")
        
        XCTAssertEqual(message.getCurrentVersionIndex(), 2)
        XCTAssertEqual(message.content, "V3")
        
        message.switchToVersion(0)
        XCTAssertEqual(message.getCurrentVersionIndex(), 0)
        XCTAssertEqual(message.content, "V1")
        
        message.switchToVersion(1)
        XCTAssertEqual(message.getCurrentVersionIndex(), 1)
        XCTAssertEqual(message.content, "V2")
        
        // 无效索引应该被忽略
        message.switchToVersion(10)
        XCTAssertEqual(message.getCurrentVersionIndex(), 1)
        XCTAssertEqual(message.content, "V2")
    }
    
    /// 测试删除版本
    func testRemoveVersion() {
        var message = ChatMessage(role: .user, content: "V1")
        message.addVersion("V2")
        message.addVersion("V3")
        
        // 删除当前版本（V3）
        message.removeVersion(at: 2)
        XCTAssertEqual(message.getAllVersions().count, 2)
        XCTAssertEqual(message.getCurrentVersionIndex(), 1)
        XCTAssertEqual(message.content, "V2")
        
        // 删除中间版本
        message.addVersion("V3 again")
        message.switchToVersion(0)
        message.removeVersion(at: 1)
        XCTAssertEqual(message.getAllVersions().count, 2)
        XCTAssertEqual(message.getCurrentVersionIndex(), 0)
        XCTAssertEqual(message.content, "V1")
        
        // 尝试删除最后一个版本（应该保留）
        message.removeVersion(at: 0)
        XCTAssertEqual(message.getAllVersions().count, 1)
    }
    
    /// 测试修改 content 属性
    func testModifyContent() {
        var message = ChatMessage(role: .user, content: "Original")
        message.addVersion("Version 2")
        
        XCTAssertEqual(message.content, "Version 2")
        
        // 修改当前版本的内容
        message.content = "Modified Version 2"
        
        XCTAssertEqual(message.content, "Modified Version 2")
        let versions = message.getAllVersions()
        XCTAssertEqual(versions[1], "Modified Version 2")
        XCTAssertEqual(versions[0], "Original")
    }
    
    // MARK: - 边界条件测试
    
    /// 测试空内容
    func testEmptyContent() {
        var message = ChatMessage(role: .system, content: "")
        
        XCTAssertEqual(message.content, "")
        XCTAssertEqual(message.getAllVersions(), [""])
        
        message.addVersion("Non-empty")
        XCTAssertEqual(message.getAllVersions().count, 2)
        XCTAssertEqual(message.content, "Non-empty")
    }
    
    /// 测试只有一个版本时的行为
    func testSingleVersionBehavior() {
        var message = ChatMessage(role: .user, content: "Only one")
        
        XCTAssertFalse(message.hasMultipleVersions)
        
        // 切换到同一个索引
        message.switchToVersion(0)
        XCTAssertEqual(message.content, "Only one")
        
        // 尝试删除唯一版本
        message.removeVersion(at: 0)
        XCTAssertEqual(message.getAllVersions().count, 1)
    }
    
    // MARK: - 序列化往返测试
    
    /// 测试完整的序列化和反序列化往返
    func testSerializationRoundTrip() throws {
        var original = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "First",
            reasoningContent: "Thinking...",
            toolCalls: nil,
            tokenUsage: MessageTokenUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30)
        )
        original.addVersion("Second")
        original.addVersion("Third")
        original.switchToVersion(1)
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChatMessage.self, from: data)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, "Second")
        XCTAssertEqual(decoded.getAllVersions(), ["First", "Second", "Third"])
        XCTAssertEqual(decoded.getCurrentVersionIndex(), 1)
        XCTAssertEqual(decoded.reasoningContent, original.reasoningContent)
        XCTAssertEqual(decoded.tokenUsage?.totalTokens, 30)
    }

    /// 测试响应测速字段的序列化和反序列化
    func testResponseMetricsRoundTrip() throws {
        let metrics = MessageResponseMetrics(
            requestStartedAt: Date(timeIntervalSince1970: 1000),
            responseCompletedAt: Date(timeIntervalSince1970: 1002),
            totalResponseDuration: 2.0,
            timeToFirstToken: 0.45,
            completionTokensForSpeed: 120,
            tokenPerSecond: 60.0,
            isTokenPerSecondEstimated: false
        )
        let original = ChatMessage(
            role: .assistant,
            content: "测速测试",
            responseMetrics: metrics
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ChatMessage.self, from: data)

        let decodedMetrics = try XCTUnwrap(decoded.responseMetrics)
        XCTAssertEqual(decodedMetrics.schemaVersion, MessageResponseMetrics.currentSchemaVersion)
        XCTAssertEqual(try XCTUnwrap(decodedMetrics.totalResponseDuration), 2.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(decodedMetrics.timeToFirstToken), 0.45, accuracy: 0.0001)
        XCTAssertEqual(decodedMetrics.completionTokensForSpeed, 120)
        XCTAssertEqual(try XCTUnwrap(decodedMetrics.tokenPerSecond), 60.0, accuracy: 0.0001)
        XCTAssertEqual(decodedMetrics.isTokenPerSecondEstimated, false)
    }
    
    /// 测试旧数据升级后的序列化
    func testLegacyUpgradeAndSerialize() throws {
        // 1. 反序列化旧格式
        let legacyJSON = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "role": "user",
            "content": "Legacy content"
        }
        """
        
        let decoder = JSONDecoder()
        var message = try decoder.decode(ChatMessage.self, from: legacyJSON.data(using: .utf8)!)
        
        // 2. 添加新版本
        message.addVersion("New version")
        
        // 3. 重新序列化
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        
        // 4. 再次反序列化验证
        let finalMessage = try decoder.decode(ChatMessage.self, from: data)
        
        XCTAssertEqual(finalMessage.getAllVersions(), ["Legacy content", "New version"])
        XCTAssertEqual(finalMessage.getCurrentVersionIndex(), 1)
        XCTAssertEqual(finalMessage.content, "New version")
    }
}

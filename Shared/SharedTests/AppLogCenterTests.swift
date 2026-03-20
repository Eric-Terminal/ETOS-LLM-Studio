// ============================================================================
// AppLogCenterTests.swift
// ============================================================================
// SharedTests
//
// 覆盖内容:
// - 用户日志脱敏策略
// - 循环缓冲区边界行为
// - 持久化 7 天保留策略
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("AppLogCenter Tests")
struct AppLogCenterTests {
    @Test("用户日志 message 字段统一占位")
    func testUserMessageAlwaysRedacted() {
        let redacted = AppLogRedactor.redactedMessage("任意内容")
        #expect(redacted == "[已隐藏]")

        let empty = AppLogRedactor.redactedMessage("   ")
        #expect(empty == "[已隐藏]")

        let nilCase = AppLogRedactor.redactedMessage(nil)
        #expect(nilCase == "[已隐藏]")
    }

    @Test("敏感 payload 字段会被占位")
    func testSensitivePayloadRedacted() {
        let source: [String: String] = [
            "message": "用户原文",
            "content": "assistant 原文",
            "sessionID": "abc",
            "model": "gpt"
        ]

        let output = AppLogRedactor.redactPayload(source)

        #expect(output?["message"] == "[已隐藏]")
        #expect(output?["content"] == "[已隐藏]")
        #expect(output?["sessionID"] == "abc")
        #expect(output?["model"] == "gpt")
    }

    @Test("请求体日志会隐藏消息字段并保留参数字段")
    func testRequestBodySanitizationForLogs() {
        let source: [String: Any] = [
            "model": "gpt-5",
            "temperature": 0.6,
            "messages": [
                ["role": "user", "content": "你好"]
            ],
            "tools": [["type": "function"]]
        ]

        let output = AppLogRedactor.sanitizeRequestBodyForLog(source, maxLength: 2_000)
        #expect(output != nil)
        #expect(output?.contains("\"model\" : \"gpt-5\"") == true)
        #expect(output?.contains("\"messages\" : \"[已隐藏数组") == true)
        #expect(output?.contains("你好") == false)
    }

    @Test("请求 URL 日志会隐藏敏感查询参数")
    func testRequestURLSanitizationForLogs() {
        let url = URL(string: "https://api.example.com/v1/chat?key=abc123&mode=debug")
        let output = AppLogRedactor.sanitizeURLForLog(url)
        #expect(output.contains("key=%5B%E5%B7%B2%E9%9A%90%E8%97%8F%5D"))
        #expect(output.contains("mode=debug"))
    }

    @Test("请求头日志会隐藏鉴权字段")
    func testRequestHeaderSanitizationForLogs() {
        let headers: [String: String] = [
            "Authorization": "Bearer secret-token",
            "Content-Type": "application/json",
            "X-API-Key": "abc"
        ]

        let output = AppLogRedactor.sanitizeHeadersForLog(headers)
        #expect(output?.contains("Authorization: [已隐藏]") == true)
        #expect(output?.contains("X-API-Key: [已隐藏]") == true)
        #expect(output?.contains("Content-Type: application/json") == true)
    }

    @Test("循环缓冲区仅保留最近 N 条")
    func testRingBufferKeepsLatestN() {
        var buffer = AppLogRingBuffer(capacity: 3)

        for index in 1...5 {
            buffer.append(
                AppLogEvent(
                    channel: .developer,
                    level: .info,
                    category: "test",
                    action: "append",
                    message: "#\(index)",
                    payload: nil
                )
            )
        }

        #expect(buffer.values.count == 3)
        #expect(buffer.values.map(\.message) == ["#3", "#4", "#5"])
    }

    @Test("按天持久化仅保留最近 7 天")
    func testFileStoreKeepsLatestSevenDays() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("app-log-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_772_848_800) // 2026-03-07 12:00:00 UTC
        let store = AppLogFileStore(baseDirectory: tempDirectory, retentionDays: 7, calendar: calendar)

        for offset in 0..<10 {
            let day = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let event = AppLogEvent(
                timestamp: day,
                channel: .user,
                level: .info,
                category: "操作",
                action: "测试",
                message: "[已隐藏]",
                payload: ["dayOffset": "\(offset)"]
            )
            await store.append(event)
        }

        let recent = await store.loadRecentEvents(now: now)
        #expect(recent.count == 7)

        let remainingFiles = try fileManager.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("app-log-") && $0.pathExtension == "jsonl" }
        #expect(remainingFiles.count == 7)
    }
}

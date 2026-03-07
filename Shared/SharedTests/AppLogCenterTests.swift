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

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

    @Test("自由文本日志会隐藏常见密钥并截断长内容")
    func testFreeTextSanitizationForLogs() {
        let raw = """
        Authorization: Bearer secret-token
        api_key=abc123
        {"access_token":"json-secret"}
        body=\(String(repeating: "x", count: 260))
        """

        let output = AppLogRedactor.sanitizeFreeTextForLog(raw, maxLength: 200)

        #expect(output.contains("secret-token") == false)
        #expect(output.contains("abc123") == false)
        #expect(output.contains("json-secret") == false)
        #expect(output.contains("Authorization: Bearer ***"))
        #expect(output.contains("api_key=***"))
        #expect(output.contains(#""access_token":"***""#))
        #expect(output.contains("已截断"))
    }

    @Test("日志来源上下文会生成可反馈的定位字段")
    func testSourceContextPayloadFields() {
        let source = AppLogSourceContext(
            fileID: "Shared/ChatService.swift",
            function: "sendMessage()",
            line: 42,
            capturedOnMainThread: false
        )

        #expect(source.payloadFields["来源文件"] == "Shared/ChatService.swift")
        #expect(source.payloadFields["来源函数"] == "sendMessage()")
        #expect(source.payloadFields["来源行"] == "42")
        #expect(source.payloadFields["捕获线程"] == "background")
    }

    @Test("反馈诊断日志会合并请求摘要和最近 AppLog")
    func testFeedbackDiagnosticFormatterIncludesRecentLogs() {
        let requestedAt = Date(timeIntervalSince1970: 1_772_848_800)
        let finishedAt = requestedAt.addingTimeInterval(1.25)
        let requestID = UUID()
        let requestLog = RequestLogEntry(
            requestID: requestID,
            sessionID: UUID(),
            providerID: UUID(),
            providerName: "providerA",
            modelID: "model-a",
            requestedAt: requestedAt,
            finishedAt: finishedAt,
            isStreaming: true,
            status: .failed,
            tokenUsage: MessageTokenUsage(promptTokens: 12, completionTokens: 3, totalTokens: 15)
        )
        let appLog = AppLogEvent(
            timestamp: finishedAt,
            channel: .developer,
            level: .error,
            category: "网络",
            action: "HTTP错误响应体",
            message: "Authorization: Bearer secret-token",
            payload: ["响应体摘要": "api_key=abc123"]
        )
        var summary = RequestLogSummary()
        summary.totalRequests = 1
        summary.failedCount = 1
        summary.tokenTotals.totalTokens = 15

        let lines = FeedbackDiagnosticLogFormatter.build(
            baseLines: ["timestamp=2026-03-07T12:00:00Z"],
            requestSummary: summary,
            requestLogs: [requestLog],
            appLogs: [appLog],
            requestLogLimit: 20,
            appLogLimit: 80
        )
        let joined = lines.joined(separator: "\n")

        #expect(joined.contains("request_summary_7d total=1"))
        #expect(joined.contains("request_id=\(requestID.uuidString)"))
        #expect(joined.contains("category=网络"))
        #expect(joined.contains("secret-token") == false)
        #expect(joined.contains("abc123") == false)
    }

    @Test("日志筛选器支持按等级过滤")
    func testLogFilterByLevel() {
        let events = makeFilterFixtureEvents()
        let filtered = AppLogFilterEngine.filter(
            events,
            with: AppLogFilter(level: .error)
        )

        #expect(filtered.count == 1)
        #expect(filtered.first?.level == .error)
    }

    @Test("日志筛选器支持按分类与关键词过滤")
    func testLogFilterByCategoryAndKeyword() {
        let events = makeFilterFixtureEvents()
        let filtered = AppLogFilterEngine.filter(
            events,
            with: AppLogFilter(
                keyword: "providerA",
                categoryKeyword: "配置"
            )
        )

        #expect(filtered.count == 1)
        #expect(filtered.first?.category == "配置")
        #expect(filtered.first?.payload?["providerName"] == "providerA")
    }

    @Test("日志筛选器支持仅查看配置变更")
    func testLogFilterConfigChangesOnly() {
        let events = makeFilterFixtureEvents()
        let filtered = AppLogFilterEngine.filter(
            events,
            with: AppLogFilter(configChangesOnly: true)
        )

        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.category == "配置" || $0.category.lowercased() == "config" })
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

    @Test("按天目录持久化仅保留最近 7 天")
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

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
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.timeZone = calendar.timeZone
            dayFormatter.dateFormat = "yyyy-MM-dd"
            let dayFolder = tempDirectory.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
            try fileManager.createDirectory(at: dayFolder, withIntermediateDirectories: true)

            let fileURL = dayFolder.appendingPathComponent("run-\(offset).jsonl", isDirectory: false)
            let data = try encoder.encode(event)
            var line = Data()
            line.append(data)
            line.append(0x0A)
            try line.write(to: fileURL, options: .atomic)
        }

        let recent = await store.loadRecentEvents(now: now)
        #expect(recent.count == 7)

        let dayFolders = await store.loadDayFolders(now: now)
        #expect(dayFolders.count == 7)
        #expect(dayFolders.allSatisfy { $0.runs.count == 1 })
    }

    @Test("同一次应用运行写入同一个日志文件")
    func testSingleRunUsesSingleLogFile() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("app-log-single-run-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let store = AppLogFileStore(baseDirectory: tempDirectory, retentionDays: 7)

        for index in 0..<3 {
            let event = AppLogEvent(
                channel: index % 2 == 0 ? .developer : .user,
                level: .info,
                category: "测试",
                action: "写入",
                message: "第\(index)条",
                payload: nil
            )
            await store.append(event)
        }

        let dayFolders = await store.loadDayFolders()
        #expect(dayFolders.count == 1)
        #expect(dayFolders.first?.runs.count == 1)
        #expect(dayFolders.first?.runs.first?.totalEventCount == 3)
    }

    @Test("可以删除单个运行日志文件")
    func testDeleteSingleRunFile() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("app-log-delete-run-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let store = AppLogFileStore(baseDirectory: tempDirectory, retentionDays: 30)
        let dayDirectory = tempDirectory.appendingPathComponent("2026-03-07", isDirectory: true)
        try fileManager.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        let runA = dayDirectory.appendingPathComponent("run-a.jsonl", isDirectory: false)
        let runB = dayDirectory.appendingPathComponent("run-b.jsonl", isDirectory: false)
        try writeEvents([
            AppLogEvent(channel: .developer, level: .info, category: "测试", action: "A", message: "A", payload: nil)
        ], to: runA)
        try writeEvents([
            AppLogEvent(channel: .user, level: .info, category: "测试", action: "B", message: "[已隐藏]", payload: nil)
        ], to: runB)

        await store.deleteRunFile(relativePath: "2026-03-07/run-a.jsonl")

        let folders = await store.loadDayFolders()
        #expect(folders.count == 1)
        #expect(folders.first?.day == "2026-03-07")
        #expect(folders.first?.runs.count == 1)
        #expect(folders.first?.runs.first?.fileName == "run-b.jsonl")
    }

    @Test("可以删除整个日期日志目录")
    func testDeleteDayFolder() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("app-log-delete-day-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let store = AppLogFileStore(baseDirectory: tempDirectory, retentionDays: 30)

        let dayA = tempDirectory.appendingPathComponent("2026-03-07", isDirectory: true)
        let dayB = tempDirectory.appendingPathComponent("2026-03-08", isDirectory: true)
        try fileManager.createDirectory(at: dayA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dayB, withIntermediateDirectories: true)

        try writeEvents([
            AppLogEvent(channel: .developer, level: .info, category: "测试", action: "A", message: "A", payload: nil)
        ], to: dayA.appendingPathComponent("run-a.jsonl", isDirectory: false))
        try writeEvents([
            AppLogEvent(channel: .user, level: .warning, category: "测试", action: "B", message: "[已隐藏]", payload: nil)
        ], to: dayB.appendingPathComponent("run-b.jsonl", isDirectory: false))

        await store.deleteDayFolder(day: "2026-03-07")

        let folders = await store.loadDayFolders()
        #expect(folders.count == 1)
        #expect(folders.first?.day == "2026-03-08")
    }

    private func makeFilterFixtureEvents() -> [AppLogEvent] {
        [
            AppLogEvent(
                channel: .developer,
                level: .info,
                category: "配置",
                action: "更新提供商配置",
                message: "配置已更新",
                payload: ["providerName": "providerA"]
            ),
            AppLogEvent(
                channel: .developer,
                level: .error,
                category: "请求",
                action: "构建请求失败",
                message: "网络错误",
                payload: nil
            ),
            AppLogEvent(
                channel: .user,
                level: .info,
                category: "config",
                action: "删除提供商配置",
                message: "[已隐藏]",
                payload: ["providerName": "providerB"]
            )
        ]
    }

    private func writeEvents(_ events: [AppLogEvent], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var content = Data()
        for event in events {
            let data = try encoder.encode(event)
            content.append(data)
            content.append(0x0A)
        }
        try content.write(to: fileURL, options: .atomic)
    }
}

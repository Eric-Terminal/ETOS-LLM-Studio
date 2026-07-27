// ============================================================================
// AppLogCenterTests.swift
// ============================================================================
// ETOSCoreTests
//
// 覆盖内容:
// - 用户日志脱敏策略
// - 循环缓冲区边界行为
// - 持久化默认与自定义保留策略
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

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

        let output = AppLogRedactor.sanitizeRequestBodyForLog(
            source,
            exposesMessageFields: false
        )
        #expect(output != nil)
        #expect(output?.contains("\"model\" : \"gpt-5\"") == true)
        #expect(output?.contains("\"messages\" : \"[已隐藏数组") == true)
        #expect(output?.contains("你好") == false)
    }

    @Test("开启明文消息后请求体日志保留文本并隐藏二进制内容")
    func testRequestBodyPlainMessagesKeepTextAndHideBinaryPayloads() {
        let source: [String: Any] = [
            "model": "gpt-5",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "你好"],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/png;base64,abcdef"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let output = AppLogRedactor.sanitizeRequestBodyForLog(
            source,
            exposesMessageFields: true
        )
        #expect(output != nil)
        #expect(output?.contains("你好") == true)
        #expect(output?.contains("data:image/png;base64,abcdef") == false)
        #expect(output?.contains("[二进制内容已隐藏") == true)
    }

    @Test("请求体日志写入完整内容不提前截断")
    func testRequestBodySanitizationKeepsFullText() {
        let longText = String(repeating: "长文本", count: 3_000)
        let source: [String: Any] = [
            "messages": [
                ["role": "user", "content": longText]
            ]
        ]

        let output = AppLogRedactor.sanitizeRequestBodyForLog(source, exposesMessageFields: true)

        #expect(output?.contains(longText) == true)
        #expect(output?.contains("已截断") == false)
    }

    @Test("响应体默认隐藏模型文本但保留结构和用量")
    func testResponseBodySanitizationHidesTextByDefault() {
        let source = """
        {
          "id": "response-1",
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "这是模型回复原文"
              }
            }
          ],
          "usage": {
            "prompt_tokens": 12,
            "completion_tokens": 8
          }
        }
        """

        let output = AppLogRedactor.sanitizeResponseBodyForLog(
            source,
            exposesMessageFields: false
        )

        #expect(output.contains("这是模型回复原文") == false)
        #expect(output.contains("[已隐藏") == true)
        #expect(output.contains("\"prompt_tokens\" : 12") == true)
        #expect(output.contains("\"id\" : \"response-1\"") == true)
    }

    @Test("响应体明文开关开启后保留文本并隐藏 Base64")
    func testResponseBodySanitizationKeepsTextAndHidesBinary() {
        let source = """
        {
          "output_text": "完整回复",
          "data": "SGVsbG8=",
          "image_url": "data:image/png;base64,abcdef"
        }
        """

        let output = AppLogRedactor.sanitizeResponseBodyForLog(
            source,
            exposesMessageFields: true
        )

        #expect(output.contains("完整回复") == true)
        #expect(output.contains("SGVsbG8=") == false)
        #expect(output.contains("data:image/png;base64,abcdef") == false)
        #expect(output.contains("[二进制内容已隐藏") == true)
    }

    @Test("流式响应逐行脱敏并保留协议边界")
    func testStreamingResponseSanitization() {
        let source = """
        event: message
        data: {"choices":[{"delta":{"content":"流式秘密"}}]}

        data: [DONE]
        """

        let output = AppLogRedactor.sanitizeResponseBodyForLog(
            source,
            exposesMessageFields: false
        )

        #expect(output.contains("event: message"))
        #expect(output.contains("data: [DONE]"))
        #expect(output.contains("流式秘密") == false)
        #expect(output.contains("[已隐藏") == true)
    }

    @Test("日志长文本会按四千字符分页")
    func testAppLogTextPaginatorSplitsByFourThousandCharacters() {
        let text = String(repeating: "a", count: 8_001)

        let pages = AppLogTextPaginator.paginate(text)

        #expect(pages.count == 3)
        #expect(pages[0].content.count == 4_000)
        #expect(pages[0].startCharacterNumber == 1)
        #expect(pages[0].endCharacterNumber == 4_000)
        #expect(pages[1].startCharacterNumber == 4_001)
        #expect(pages[1].endCharacterNumber == 8_000)
        #expect(pages[2].content.count == 1)
        #expect(pages[2].startCharacterNumber == 8_001)
        #expect(pages[2].endCharacterNumber == 8_001)
    }

    @Test("日志长文本分页不会切坏组合字符")
    func testAppLogTextPaginatorKeepsCharacterBoundaries() {
        let text = String(repeating: "👩‍💻", count: 4_001)

        let pages = AppLogTextPaginator.paginate(text)

        #expect(pages.count == 2)
        #expect(pages[0].content.count == 4_000)
        #expect(pages[1].content == "👩‍💻")
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

    @Test("请求事务编码一次并按同一事件投影两种格式")
    func testRequestTransactionUsesSingleCanonicalEvent() throws {
        let event = AppLogEvent(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            channel: .developer,
            level: .info,
            category: "HTTP",
            action: "success",
            message: "POST /v1/chat → 200",
            payload: [
                "method": "POST",
                "request_body": "安全请求体",
                "response_body": "安全响应体",
                "request_id": "request-1",
                "token_usage": #"{"total_tokens":9}"#
            ],
            presentation: .requestTransaction
        )

        let user = try #require(event.presented(in: .user))
        let developer = try #require(event.presented(in: .developer))

        #expect(user.id == event.id)
        #expect(developer.id == event.id)
        #expect(user.presentedID != developer.presentedID)
        #expect(user.payload?["request_body"] == "安全请求体")
        #expect(user.payload?["response_body"] == "安全响应体")
        #expect(user.payload?["request_id"] == nil)
        #expect(user.payload?["token_usage"] == nil)
        #expect(developer.payload?["request_id"] == "request-1")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppLogEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("旧日志缺少投影字段时仍可读取")
    func testLegacyEventWithoutPresentationStillDecodes() throws {
        let legacyJSON = #"""
        {
          "id": "EFC62D61-DBAE-454B-B68B-BECB50A1B309",
          "timestamp": "2026-07-26T12:00:00Z",
          "channel": "user",
          "level": "info",
          "category": "操作",
          "action": "旧日志",
          "message": "[已隐藏]"
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let event = try decoder.decode(AppLogEvent.self, from: Data(legacyJSON.utf8))

        #expect(event.presentation == nil)
        #expect(event.channel == .user)
        #expect(event.presented(in: .developer) == nil)
    }

    @Test("清除一种请求日志格式会保留另一种格式")
    func testClearingOneTransactionPresentationKeepsTheOther() throws {
        let event = AppLogEvent(
            channel: .developer,
            level: .info,
            category: "HTTP",
            action: "success",
            message: "POST /v1/chat → 200",
            payload: [
                "request_body": "安全请求体",
                "request_id": "request-1"
            ],
            presentation: .requestTransaction
        )

        let withoutUser = try #require(event.removingVisibility(in: .user))
        #expect(withoutUser.channel == .developer)
        #expect(withoutUser.presentation == nil)
        #expect(withoutUser.payload?["request_id"] == "request-1")
        #expect(withoutUser.presented(in: .user) == nil)

        let withoutDeveloper = try #require(event.removingVisibility(in: .developer))
        #expect(withoutDeveloper.channel == .user)
        #expect(withoutDeveloper.presentation == nil)
        #expect(withoutDeveloper.payload?["request_body"] == "安全请求体")
        #expect(withoutDeveloper.payload?["request_id"] == nil)
        #expect(withoutDeveloper.presented(in: .developer) == nil)
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

    @Test("应用日志默认仅保留最近 15 天")
    func testFileStoreDefaultRetentionKeepsLatestFifteenDays() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("app-log-default-retention-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_772_848_800) // 2026-03-07 12:00:00 UTC
        let store = AppLogFileStore(baseDirectory: tempDirectory, calendar: calendar)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        for offset in 0..<20 {
            let day = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            let dayFolder = tempDirectory.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
            try fileManager.createDirectory(at: dayFolder, withIntermediateDirectories: true)
            try writeEvents([
                AppLogEvent(
                    timestamp: day,
                    channel: .developer,
                    level: .info,
                    category: "测试",
                    action: "默认保留",
                    message: "#\(offset)",
                    payload: nil
                )
            ], to: dayFolder.appendingPathComponent("run-\(offset).jsonl", isDirectory: false))
        }

        let recent = await store.loadRecentEvents(now: now)
        #expect(recent.count == 15)

        let dayFolders = await store.loadDayFolders(now: now)
        #expect(dayFolders.count == 15)
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

    @Test("清除全部日志会等待先前写入且不会被旧任务恢复")
    @MainActor
    func testClearAllSerializesPendingPersistence() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("app-log-clear-order-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let store = AppLogFileStore(baseDirectory: tempDirectory)
        let center = AppLogCenter(fileStore: store, shouldAutoLoad: false)

        center.logDeveloper(
            category: "HTTP",
            action: "旧请求",
            message: "清除前等待落盘的请求日志"
        )
        center.clearAll()
        await center.waitForPendingPersistence()

        let persistedEvents = await store.loadRecentEvents()
        #expect(persistedEvents.isEmpty)
        #expect(center.mergedLogs.isEmpty)
        #expect(center.logDayFolders.isEmpty)
    }

    @Test("追加日志直接返回增量运行摘要")
    func testAppendReturnsIncrementalRunSummary() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("app-log-incremental-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let store = AppLogFileStore(baseDirectory: tempDirectory, retentionDays: 7)
        let transaction = AppLogEvent(
            channel: .developer,
            level: .info,
            category: "HTTP",
            action: "success",
            message: "POST /v1/chat → 200",
            payload: ["method": "POST", "request_id": "request-1"],
            presentation: .requestTransaction
        )
        let userEvent = AppLogEvent(
            channel: .user,
            level: .info,
            category: "操作",
            action: "测试",
            message: "[已隐藏]"
        )

        let firstResult = await store.append(transaction)
        let secondResult = await store.append(userEvent)
        let first = try #require(firstResult)
        let second = try #require(secondResult)

        #expect(first.totalEventCount == 1)
        #expect(first.developerEventCount == 1)
        #expect(first.userEventCount == 1)
        #expect(second.totalEventCount == 2)
        #expect(second.developerEventCount == 1)
        #expect(second.userEventCount == 2)
        #expect(second.fileSizeBytes > first.fileSizeBytes)

        let events = await store.loadEvents(for: second)
        #expect(events.count == 2)
        #expect(events.first?.presentation == .requestTransaction)
    }

    @Test("文件存储清除一种请求日志格式后保留另一种")
    func testFileStoreClearKeepsOtherTransactionPresentation() async throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("app-log-clear-presentation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let store = AppLogFileStore(baseDirectory: tempDirectory, retentionDays: 7)
        let transaction = AppLogEvent(
            channel: .developer,
            level: .info,
            category: "HTTP",
            action: "success",
            message: "POST /v1/chat → 200",
            payload: [
                "request_body": "安全请求体",
                "request_id": "request-1"
            ],
            presentation: .requestTransaction
        )

        let appended = try #require(await store.append(transaction))
        await store.clear(channel: .user)

        let developerOnlyEvents = await store.loadEvents(for: appended)
        let developerOnly = try #require(developerOnlyEvents.first)
        #expect(developerOnlyEvents.count == 1)
        #expect(developerOnly.presentation == nil)
        #expect(developerOnly.channel == .developer)
        #expect(developerOnly.payload?["request_id"] == "request-1")
        #expect(developerOnly.presented(in: .user) == nil)

        await store.clear(channel: .developer)
        let clearedEvents = await store.loadEvents(for: appended)
        #expect(clearedEvents.isEmpty)
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

        let now = try #require(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z"))
        let folders = await store.loadDayFolders(now: now)
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

        let now = try #require(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z"))
        let folders = await store.loadDayFolders(now: now)
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

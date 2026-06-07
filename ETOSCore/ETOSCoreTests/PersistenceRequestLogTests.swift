// ============================================================================
// PersistenceRequestLogTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责请求日志的追加、汇总与保留策略测试。
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

extension PersistenceTests {
    @Test("Append and Load Request Logs")
    func testAppendAndLoadRequestLogs() {
        cleanup(sessions: [])

        let requestA = RequestLogEntry(
            requestID: UUID(),
            sessionID: UUID(),
            providerID: UUID(),
            providerName: "OpenAI",
            modelID: "gpt-5",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_002),
            isStreaming: true,
            status: .success,
            tokenUsage: MessageTokenUsage(
                promptTokens: 100,
                completionTokens: 50,
                totalTokens: 150,
                thinkingTokens: 10,
                cacheWriteTokens: 0,
                cacheReadTokens: 0
            )
        )
        let requestB = RequestLogEntry(
            requestID: UUID(),
            sessionID: UUID(),
            providerID: UUID(),
            providerName: "Anthropic",
            modelID: "claude-sonnet-4",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_010),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_012),
            isStreaming: false,
            status: .failed,
            tokenUsage: nil
        )

        Persistence.appendRequestLog(requestA)
        Persistence.appendRequestLog(requestB)

        let queryWindow = RequestLogQuery(
            from: Date(timeIntervalSince1970: 1_699_999_999),
            to: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let loaded = Persistence.loadRequestLogs(query: queryWindow)
        #expect(loaded.count == 2)
        #expect(loaded.first?.providerName == "Anthropic")
        #expect(loaded.last?.providerName == "OpenAI")
        #expect(loaded.last?.tokenUsage?.thinkingTokens == 10)

        let successOnly = Persistence.loadRequestLogs(
            query: .init(
                from: queryWindow.from,
                to: queryWindow.to,
                statuses: Set([.success])
            )
        )
        #expect(successOnly.count == 1)
        #expect(successOnly.first?.modelID == "gpt-5")

        cleanup(sessions: [])
    }

    @Test("Summarize Request Logs")
    func testSummarizeRequestLogs() {
        cleanup(sessions: [])

        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let entries: [RequestLogEntry] = [
            .init(
                requestID: UUID(),
                sessionID: UUID(),
                providerID: UUID(),
                providerName: "OpenAI",
                modelID: "gpt-5",
                requestedAt: now,
                finishedAt: now.addingTimeInterval(1),
                isStreaming: true,
                status: .success,
                tokenUsage: .init(
                    promptTokens: 10,
                    completionTokens: 20,
                    totalTokens: 30,
                    thinkingTokens: 2,
                    cacheWriteTokens: nil,
                    cacheReadTokens: nil
                )
            ),
            .init(
                requestID: UUID(),
                sessionID: UUID(),
                providerID: UUID(),
                providerName: "OpenAI",
                modelID: "gpt-5",
                requestedAt: now.addingTimeInterval(2),
                finishedAt: now.addingTimeInterval(3),
                isStreaming: true,
                status: .failed,
                tokenUsage: nil
            ),
            .init(
                requestID: UUID(),
                sessionID: UUID(),
                providerID: UUID(),
                providerName: "Anthropic",
                modelID: "claude-sonnet-4",
                requestedAt: now.addingTimeInterval(4),
                finishedAt: now.addingTimeInterval(5),
                isStreaming: false,
                status: .cancelled,
                tokenUsage: .init(
                    promptTokens: 5,
                    completionTokens: 7,
                    totalTokens: nil,
                    thinkingTokens: nil,
                    cacheWriteTokens: 3,
                    cacheReadTokens: 4
                )
            )
        ]

        for entry in entries {
            Persistence.appendRequestLog(entry)
        }

        let summary = Persistence.summarizeRequestLogs(
            query: .init(
                from: now.addingTimeInterval(-1),
                to: now.addingTimeInterval(10)
            )
        )
        #expect(summary.totalRequests == 3)
        #expect(summary.successCount == 1)
        #expect(summary.failedCount == 1)
        #expect(summary.cancelledCount == 1)
        #expect(summary.tokenTotals.sentTokens == 15)
        #expect(summary.tokenTotals.receivedTokens == 27)
        #expect(summary.tokenTotals.thinkingTokens == 2)
        #expect(summary.tokenTotals.cacheWriteTokens == 3)
        #expect(summary.tokenTotals.cacheReadTokens == 4)
        #expect(summary.tokenTotals.totalTokens == 30)
        #expect(summary.byProvider.count == 2)
        #expect(summary.byModel.count == 2)

        cleanup(sessions: [])
    }

    @Test("Request Logs Retention Limit")
    func testRequestLogsRetentionLimit() {
        cleanup(sessions: [])

        let retentionLimit = 100
        Persistence.requestLogRetentionLimitOverride = retentionLimit
        defer { Persistence.requestLogRetentionLimitOverride = nil }

        let total = 120
        let dropped = total - retentionLimit
        let baseDate = Date(timeIntervalSince1970: 1_700_200_000)
        for index in 0..<total {
            let time = baseDate.addingTimeInterval(TimeInterval(index))
            Persistence.appendRequestLog(
                .init(
                    requestID: UUID(),
                    sessionID: UUID(),
                    providerID: UUID(),
                    providerName: "Retention",
                    modelID: "model-\(index)",
                    requestedAt: time,
                    finishedAt: time.addingTimeInterval(0.1),
                    isStreaming: false,
                    status: .success,
                    tokenUsage: nil
                )
            )
        }

        let loaded = Persistence.loadRequestLogs(
            query: .init(
                from: baseDate.addingTimeInterval(-1),
                to: baseDate.addingTimeInterval(TimeInterval(total + 1))
            )
        )
        #expect(loaded.count == retentionLimit)
        #expect(loaded.first?.modelID == "model-\(total - 1)")
        #expect(loaded.last?.modelID == "model-\(dropped)")

        cleanup(sessions: [])
    }
}

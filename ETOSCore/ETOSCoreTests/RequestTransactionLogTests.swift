// ============================================================================
// RequestTransactionLogTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证请求构建、响应快照与最终状态只生成成对的完整事务日志。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("请求事务日志", .serialized)
struct RequestTransactionLogTests {
    @Test("一次 HTTP 请求生成用户与开发两种事务格式")
    @MainActor
    func requestAndResponseAreAggregatedIntoTwoFormats() async throws {
        let previousEnabled = AppConfigStore.boolValue(for: .requestLogEnabled)
        let previousPlaintext = AppConfigStore.boolValue(for: .requestLogPlainMessageEnabled)
        AppConfigStore.persistSynchronously(.bool(true), for: .requestLogEnabled)
        AppConfigStore.persistSynchronously(.bool(false), for: .requestLogPlainMessageEnabled)
        defer {
            AppConfigStore.persistSynchronously(.bool(previousEnabled), for: .requestLogEnabled)
            AppConfigStore.persistSynchronously(.bool(previousPlaintext), for: .requestLogPlainMessageEnabled)
        }

        let requestID = UUID()
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let payload: [String: Any] = [
            "model": "test-model",
            "messages": [["role": "user", "content": "不应出现在日志里的原文"]],
            "temperature": 0.7
        ]
        var request = URLRequest(
            url: URL(string: "https://api.example.com/v1/chat?api_key=secret")!
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        logChatRequestSnapshot(
            adapterName: "测试适配器",
            request: request,
            payload: payload
        )
        RequestTransactionLogRegistry.bindRequest(
            request,
            requestID: requestID,
            requestedAt: requestedAt,
            providerName: "测试提供商",
            modelID: "test-model",
            isStreaming: false
        )
        RequestTransactionLogRegistry.stageResponse(
            requestID: requestID,
            request: request,
            requestedAt: requestedAt,
            providerName: "测试提供商",
            modelID: "test-model",
            isStreaming: false,
            sanitizedBody: AppLogRedactor.sanitizeResponseBodyForLog(
                #"{"choices":[{"message":{"content":"也不应落盘"}}],"usage":{"total_tokens":9}}"#,
                exposesMessageFields: false
            ),
            bodyBytes: 82,
            statusCode: 200,
            isPartial: false
        )
        RequestTransactionLogRegistry.finalize(
            requestID: requestID,
            status: .success,
            finishedAt: requestedAt.addingTimeInterval(1.25),
            httpStatusCode: 200,
            errorKind: nil,
            tokenUsage: MessageTokenUsage(
                promptTokens: 4,
                completionTokens: 5,
                totalTokens: 9
            )
        )

        for _ in 0..<20 {
            if AppLogCenter.shared.developerLogs.contains(where: {
                $0.payload?["request_id"] == requestID.uuidString
            }) {
                break
            }
            await Task.yield()
        }

        let developer = try #require(
            AppLogCenter.shared.developerLogs.last(where: {
                $0.payload?["request_id"] == requestID.uuidString
            })
        )
        let user = try #require(
            AppLogCenter.shared.userLogs.last(where: {
                $0.category == "HTTP" &&
                $0.message == developer.message
            })
        )

        #expect(developer.category == "HTTP")
        #expect(developer.payload?["attempt_count"] == "1")
        #expect(developer.payload?["response_snapshot_count"] == "1")
        #expect(developer.payload?["duration_ms"] == "1250")
        #expect(developer.payload?["token_usage"]?.contains(#""totalTokens":9"#) == true)
        #expect(developer.payload?.values.contains { $0.contains("不应出现在日志里的原文") } == false)
        #expect(developer.payload?.values.contains { $0.contains("也不应落盘") } == false)
        #expect(developer.payload?.values.contains { $0.contains("secret") } == false)

        #expect(user.payload?["request_id"] == nil)
        #expect(user.payload?["request_body"]?.contains("[已隐藏数组") == true)
        #expect(user.payload?["response_body"]?.contains("[已隐藏") == true)
        #expect(user.payload?["http_status"] == "200")
    }
}

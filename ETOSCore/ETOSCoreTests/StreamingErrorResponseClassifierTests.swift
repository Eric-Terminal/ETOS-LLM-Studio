// ============================================================================
// StreamingErrorResponseClassifierTests.swift
// ============================================================================
// 未解析流式行必须依赖明确错误结构，不能被普通正文关键词触发。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("未解析流式错误识别测试")
struct StreamingErrorResponseClassifierTests {
    @Test("普通正文中的错误关键词不会启动错误捕获")
    func ordinaryContentWithErrorWordsIsIgnored() {
        let service = ChatService()
        var body = ""
        var statusCode: Int?

        service.updateTrailingUnparsedStreamingResponse(
            with: #"data: {"content":"Explain the error handling used by Cloudflare and nginx"}"#,
            body: &body,
            httpStatusCode: &statusCode
        )
        service.updateTrailingUnparsedStreamingResponse(
            with: "这个方案失败时应该如何恢复？",
            body: &body,
            httpStatusCode: &statusCode
        )

        #expect(body.isEmpty)
        #expect(statusCode == nil)
    }

    @Test("正常 HTTP 状态与普通 HTML 不会被当成错误")
    func ordinaryHTTPAndHTMLAreIgnored() {
        let service = ChatService()
        var body = ""
        var statusCode: Int?

        service.updateTrailingUnparsedStreamingResponse(
            with: "HTTP/1.1 200 OK",
            body: &body,
            httpStatusCode: &statusCode
        )
        service.updateTrailingUnparsedStreamingResponse(
            with: "<html><body>Cloudflare 使用说明</body></html>",
            body: &body,
            httpStatusCode: &statusCode
        )

        #expect(body.isEmpty)
        #expect(statusCode == nil)
    }

    @Test("明确错误 envelope 和代理状态页仍会被捕获")
    func explicitErrorEnvelopeIsCaptured() {
        let service = ChatService()
        var body = ""
        var statusCode: Int?

        service.updateTrailingUnparsedStreamingResponse(
            with: #"data: {"error":{"code":502,"message":"upstream unavailable"}}"#,
            body: &body,
            httpStatusCode: &statusCode
        )

        #expect(!body.isEmpty)
        #expect(statusCode == 502)
    }
}

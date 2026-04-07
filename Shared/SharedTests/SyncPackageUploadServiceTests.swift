// ============================================================================
// SyncPackageUploadServiceTests.swift
// ============================================================================
// SyncPackageUploadService 上传行为测试
// - 验证成功上传时的请求构建与返回值
// - 验证非 2xx 状态码与无效响应的错误处理
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("同步数据包上传服务测试")
struct SyncPackageUploadServiceTests {

    @Test("上传成功时会返回状态码与响应预览")
    func testUploadSuccess() async throws {
        let endpoint = try #require(URL(string: "https://example.com/backup"))

        var capturedRequest: URLRequest?
        var capturedBody: Data?

        let result = try await SyncPackageUploadService.upload(
            exportData: Data("{}".utf8),
            suggestedFileName: "ETOS-数据导出.json",
            to: endpoint,
            transport: { request, body in
                capturedRequest = request
                capturedBody = body
                let response = try #require(
                    HTTPURLResponse(url: endpoint, statusCode: 201, httpVersion: nil, headerFields: nil)
                )
                return (Data("ok".utf8), response)
            }
        )

        #expect(result.statusCode == 201)
        #expect(result.responseBodyPreview == "ok")
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-ETOS-Backup-FileName") == "ETOS-数据导出.json")
        #expect(capturedBody == Data("{}".utf8))
    }

    @Test("非 2xx 响应会抛出状态码错误")
    func testUploadThrowsForUnexpectedStatusCode() async throws {
        let endpoint = try #require(URL(string: "https://example.com/backup"))

        do {
            _ = try await SyncPackageUploadService.upload(
                exportData: Data("{}".utf8),
                suggestedFileName: "demo.json",
                to: endpoint,
                transport: { _, _ in
                    let response = try #require(
                        HTTPURLResponse(url: endpoint, statusCode: 500, httpVersion: nil, headerFields: nil)
                    )
                    return (Data("server error".utf8), response)
                }
            )
            Issue.record("预期应抛出 unexpectedStatusCode。")
        } catch let error as SyncPackageUploadError {
            switch error {
            case .unexpectedStatusCode(let statusCode, let preview):
                #expect(statusCode == 500)
                #expect(preview == "server error")
            default:
                Issue.record("错误类型不符合预期：\(error.localizedDescription)")
            }
        }
    }

    @Test("非 HTTP 响应会抛出 invalidHTTPResponse")
    func testUploadThrowsForInvalidResponse() async throws {
        let endpoint = try #require(URL(string: "https://example.com/backup"))

        do {
            _ = try await SyncPackageUploadService.upload(
                exportData: Data(),
                suggestedFileName: "demo.json",
                to: endpoint,
                transport: { _, _ in
                    let response = URLResponse(
                        url: endpoint,
                        mimeType: "application/json",
                        expectedContentLength: 0,
                        textEncodingName: "utf-8"
                    )
                    return (Data(), response)
                }
            )
            Issue.record("预期应抛出 invalidHTTPResponse。")
        } catch let error as SyncPackageUploadError {
            switch error {
            case .invalidHTTPResponse:
                #expect(true)
            default:
                Issue.record("错误类型不符合预期：\(error.localizedDescription)")
            }
        }
    }
}

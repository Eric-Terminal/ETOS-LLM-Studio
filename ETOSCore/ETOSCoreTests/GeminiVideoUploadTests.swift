// ============================================================================
// GeminiVideoUploadTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 验证 Gemini Files API 的可恢复上传、状态轮询与 URI 复用。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("Gemini 视频上传", .serialized)
struct GeminiVideoUploadTests {
    @Test("原生视频通过 Files API 上传并复用 URI")
    func uploadsVideoAndReusesURI() async throws {
        GeminiVideoUploadURLProtocol.reset()
        defer { GeminiVideoUploadURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiVideoUploadURLProtocol.self]
        let service = ChatService(urlSession: URLSession(configuration: configuration))
        let provider = Provider(
            id: UUID(),
            name: "Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKeys: ["video-key"],
            apiFormat: "gemini"
        )
        let messageID = UUID()
        let video = FileAttachment(
            data: Data([0x01, 0x02, 0x03, 0x04]),
            mimeType: "video/mp4",
            fileName: "sample.mp4"
        )

        let first = try await service.prepareGeminiNativeVideoAttachments(
            [messageID: [video]],
            provider: provider,
            adapter: GeminiAdapter()
        )
        let second = try await service.prepareGeminiNativeVideoAttachments(
            [messageID: [video]],
            provider: provider,
            adapter: GeminiAdapter()
        )
        let firstAttachment = try #require(first.attachments[messageID]?.first)
        let secondAttachment = try #require(second.attachments[messageID]?.first)
        let requests = GeminiVideoUploadURLProtocol.capturedRequests()

        #expect(first.apiKey == "video-key")
        #expect(firstAttachment.remoteFileURI == "https://generativelanguage.googleapis.com/v1beta/files/video-1")
        #expect(secondAttachment.remoteFileURI == firstAttachment.remoteFileURI)
        #expect(requests.count == 3)
        #expect(requests[0].url?.path == "/upload/v1beta/files")
        #expect(requests[0].value(forHTTPHeaderField: "X-Goog-Upload-Protocol") == "resumable")
        #expect(requests[1].url?.host == "upload.test")
        #expect(requests[1].value(forHTTPHeaderField: "X-Goog-Upload-Command") == "upload, finalize")
        #expect(requests[2].url?.path == "/v1beta/files/video-1")
    }

    @Test("自定义 Gemini 路径会保留前缀")
    func preservesCustomGeminiPathPrefix() throws {
        let baseURL = try #require(URL(string: "https://proxy.example/google/v1beta"))
        let uploadURL = GeminiVideoUploadRequestBuilder.uploadStartURL(from: baseURL)
        let statusURL = GeminiVideoUploadRequestBuilder.statusURL(
            from: baseURL,
            fileName: "files/example"
        )

        #expect(uploadURL?.absoluteString == "https://proxy.example/google/upload/v1beta/files")
        #expect(statusURL?.absoluteString == "https://proxy.example/google/v1beta/files/example")
    }
}

private final class GeminiVideoUploadURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        requests.removeAll()
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()

        guard let url = request.url else {
            return
        }
        let responseBody: Data
        let responseHeaders: [String: String]
        if request.value(forHTTPHeaderField: "X-Goog-Upload-Command") == "start" {
            responseBody = Data()
            responseHeaders = ["x-goog-upload-url": "https://upload.test/session-1"]
        } else if url.host == "upload.test" {
            responseBody = Data("""
            {
              "file": {
                "name": "files/video-1",
                "uri": "https://generativelanguage.googleapis.com/v1beta/files/video-1",
                "state": "PROCESSING"
              }
            }
            """.utf8)
            responseHeaders = ["Content-Type": "application/json"]
        } else {
            responseBody = Data("""
            {
              "name": "files/video-1",
              "uri": "https://generativelanguage.googleapis.com/v1beta/files/video-1",
              "state": "ACTIVE"
            }
            """.utf8)
            responseHeaders = ["Content-Type": "application/json"]
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: responseHeaders
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
    }
}

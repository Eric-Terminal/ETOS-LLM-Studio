// ============================================================================
// GeminiVideoUpload.swift
// ============================================================================
// ETOS LLM Studio
//
// 通过 Gemini Files API 上传原生视频，并缓存短期可复用的文件 URI。
// ============================================================================

import CryptoKit
import Foundation

final class GeminiVideoUploadCache: @unchecked Sendable {
    private struct Entry {
        let uri: String
        let expirationDate: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func uri(for key: String, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.expirationDate > now else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.uri
    }

    func store(uri: String, for key: String, now: Date = Date()) {
        lock.lock()
        entries[key] = Entry(
            uri: uri,
            expirationDate: now.addingTimeInterval(47 * 60 * 60)
        )
        lock.unlock()
    }
}

enum GeminiVideoUploadError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey
    case missingUploadURL
    case invalidResponse
    case processingFailed(String)
    case processingTimedOut
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return NSLocalizedString("Gemini 视频上传地址无效。", comment: "Gemini video upload invalid URL")
        case .missingAPIKey:
            return NSLocalizedString("Gemini 提供商未配置有效的 API Key。", comment: "Gemini video upload missing API key")
        case .missingUploadURL:
            return NSLocalizedString("Gemini 未返回视频上传地址。", comment: "Gemini video upload URL missing")
        case .invalidResponse:
            return NSLocalizedString("Gemini 返回的视频文件信息无法解析。", comment: "Gemini video upload response invalid")
        case .processingFailed(let message):
            return String(
                format: NSLocalizedString("Gemini 视频处理失败：%@", comment: "Gemini video processing failed"),
                message
            )
        case .processingTimedOut:
            return NSLocalizedString("等待 Gemini 处理视频超时。", comment: "Gemini video processing timed out")
        case .serverError(let statusCode, let message):
            return String(
                format: NSLocalizedString("Gemini 视频上传失败（%d）：%@", comment: "Gemini video upload server error"),
                statusCode,
                message
            )
        }
    }
}

private struct GeminiUploadedFile {
    let name: String
    let uri: String?
    let state: String
    let errorMessage: String?
}

extension ChatService {
    func prepareGeminiNativeVideoAttachments(
        _ attachmentsByMessage: [UUID: [FileAttachment]],
        provider: Provider,
        adapter: GeminiAdapter
    ) async throws -> (
        attachments: [UUID: [FileAttachment]],
        apiKey: String?
    ) {
        let containsVideo = attachmentsByMessage.values.contains { attachments in
            attachments.contains(where: VideoAttachmentSupport.isVideo)
        }
        guard containsVideo else {
            return (attachmentsByMessage, nil)
        }

        guard let apiKey = provider.apiKeys.filter({ !$0.isEmpty }).randomElement() else {
            throw GeminiVideoUploadError.missingAPIKey
        }
        guard let baseURL = adapter.normalizedGeminiBaseURL(from: provider.baseURL) else {
            throw GeminiVideoUploadError.invalidBaseURL
        }

        var preparedAttachments = attachmentsByMessage
        for (messageID, attachments) in attachmentsByMessage {
            var preparedForMessage: [FileAttachment] = []
            preparedForMessage.reserveCapacity(attachments.count)
            for attachment in attachments {
                guard VideoAttachmentSupport.isVideo(attachment) else {
                    preparedForMessage.append(attachment)
                    continue
                }
                let uri = try await geminiVideoFileURI(
                    for: attachment,
                    provider: provider,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
                preparedForMessage.append(FileAttachment(
                    id: attachment.id,
                    data: attachment.data,
                    mimeType: attachment.mimeType,
                    fileName: attachment.fileName,
                    remoteFileURI: uri
                ))
            }
            preparedAttachments[messageID] = preparedForMessage
        }
        return (preparedAttachments, apiKey)
    }

    private func geminiVideoFileURI(
        for attachment: FileAttachment,
        provider: Provider,
        baseURL: URL,
        apiKey: String
    ) async throws -> String {
        let cacheKey = await Task.detached(priority: .utility) {
            let contentDigest = SHA256.hash(data: attachment.data)
                .map { String(format: "%02x", $0) }
                .joined()
            let keyDigest = SHA256.hash(data: Data(apiKey.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "\(provider.id.uuidString)|\(baseURL.absoluteString)|\(keyDigest)|\(contentDigest)"
        }.value
        if let cachedURI = geminiVideoUploadCache.uri(for: cacheKey) {
            return cachedURI
        }

        let uploadedFile = try await uploadGeminiVideo(
            attachment,
            provider: provider,
            baseURL: baseURL,
            apiKey: apiKey
        )
        geminiVideoUploadCache.store(uri: uploadedFile.uri, for: cacheKey)
        return uploadedFile.uri
    }

    private func uploadGeminiVideo(
        _ attachment: FileAttachment,
        provider: Provider,
        baseURL: URL,
        apiKey: String
    ) async throws -> (uri: String, name: String) {
        let startRequest = try GeminiVideoUploadRequestBuilder.startRequest(
            baseURL: baseURL,
            attachment: attachment,
            apiKey: apiKey,
            headerOverrides: provider.headerOverrides
        )
        let (startData, startResponse) = try await requestData(
            for: startRequest,
            provider: provider
        )
        let startHTTPResponse = try validatedGeminiVideoResponse(
            data: startData,
            response: startResponse
        )
        guard let uploadURLValue = startHTTPResponse.value(
            forHTTPHeaderField: "x-goog-upload-url"
        ),
              let uploadURL = URL(string: uploadURLValue) else {
            throw GeminiVideoUploadError.missingUploadURL
        }

        let uploadRequest = GeminiVideoUploadRequestBuilder.uploadRequest(
            uploadURL: uploadURL,
            attachment: attachment,
            apiKey: apiKey,
            headerOverrides: provider.headerOverrides
        )
        let (uploadData, uploadResponse) = try await requestData(
            for: uploadRequest,
            provider: provider
        )
        _ = try validatedGeminiVideoResponse(data: uploadData, response: uploadResponse)
        var file = try parseGeminiUploadedFile(from: uploadData)

        for _ in 0..<150 {
            switch file.state {
            case "ACTIVE":
                guard let uri = file.uri, !uri.isEmpty else {
                    throw GeminiVideoUploadError.invalidResponse
                }
                return (uri, file.name)
            case "FAILED":
                throw GeminiVideoUploadError.processingFailed(
                    file.errorMessage ?? NSLocalizedString("服务器未提供失败原因。", comment: "Gemini video processing unknown failure")
                )
            default:
                try await Task.sleep(for: .seconds(2))
                let statusRequest = try GeminiVideoUploadRequestBuilder.statusRequest(
                    baseURL: baseURL,
                    fileName: file.name,
                    apiKey: apiKey,
                    headerOverrides: provider.headerOverrides
                )
                let (statusData, statusResponse) = try await requestData(
                    for: statusRequest,
                    provider: provider
                )
                _ = try validatedGeminiVideoResponse(
                    data: statusData,
                    response: statusResponse
                )
                file = try parseGeminiUploadedFile(from: statusData)
            }
        }
        throw GeminiVideoUploadError.processingTimedOut
    }

    @discardableResult
    private func validatedGeminiVideoResponse(
        data: Data,
        response: URLResponse
    ) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiVideoUploadError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GeminiVideoUploadError.serverError(
                httpResponse.statusCode,
                body?.isEmpty == false
                    ? body!
                    : NSLocalizedString("响应体为空。", comment: "Empty response body")
            )
        }
        return httpResponse
    }

    private func parseGeminiUploadedFile(from data: Data) throws -> GeminiUploadedFile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiVideoUploadError.invalidResponse
        }
        let file = root["file"] as? [String: Any] ?? root
        guard let name = file["name"] as? String,
              !name.isEmpty else {
            throw GeminiVideoUploadError.invalidResponse
        }
        let errorObject = file["error"] as? [String: Any]
        return GeminiUploadedFile(
            name: name,
            uri: file["uri"] as? String,
            state: (file["state"] as? String ?? "PROCESSING").uppercased(),
            errorMessage: errorObject?["message"] as? String
        )
    }
}

enum GeminiVideoUploadRequestBuilder {
    static func startRequest(
        baseURL: URL,
        attachment: FileAttachment,
        apiKey: String,
        headerOverrides: [String: String]
    ) throws -> URLRequest {
        guard let url = uploadStartURL(from: baseURL) else {
            throw GeminiVideoUploadError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(
            String(attachment.data.count),
            forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length"
        )
        request.setValue(
            attachment.mimeType,
            forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": attachment.fileName]]
        )
        applyHeaderOverrides(headerOverrides, apiKey: apiKey, to: &request)
        return request
    }

    static func uploadRequest(
        uploadURL: URL,
        attachment: FileAttachment,
        apiKey: String,
        headerOverrides: [String: String]
    ) -> URLRequest {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        request.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(attachment.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(attachment.data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = attachment.data
        applyHeaderOverrides(headerOverrides, apiKey: apiKey, to: &request)
        return request
    }

    static func statusRequest(
        baseURL: URL,
        fileName: String,
        apiKey: String,
        headerOverrides: [String: String]
    ) throws -> URLRequest {
        guard let url = statusURL(from: baseURL, fileName: fileName) else {
            throw GeminiVideoUploadError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        applyHeaderOverrides(headerOverrides, apiKey: apiKey, to: &request)
        return request
    }

    static func uploadStartURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        var pathParts = components.path.split(separator: "/").map(String.init)
        if let versionIndex = pathParts.lastIndex(where: isGeminiAPIVersion) {
            pathParts.insert("upload", at: versionIndex)
            pathParts.append("files")
        } else {
            pathParts.append(contentsOf: ["upload", "v1beta", "files"])
        }
        components.path = "/" + pathParts.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func statusURL(from baseURL: URL, fileName: String) -> URL? {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        var pathParts = components.path.split(separator: "/").map(String.init)
        pathParts.append(contentsOf: fileName.split(separator: "/").map(String.init))
        components.path = "/" + pathParts.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isGeminiAPIVersion(_ component: String) -> Bool {
        let normalized = component.lowercased()
        return normalized == "v1" || normalized == "v1beta"
    }
}

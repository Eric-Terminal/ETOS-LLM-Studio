// ============================================================================
// SyncPackageUploadService.swift
// ============================================================================
// 同步数据包上传服务
// - 将导出的 JSON 数据包通过 HTTP POST 上传到指定地址
// - 统一处理状态码与错误信息，供 iOS/watchOS 复用
// ============================================================================

import Foundation

public struct SyncPackageUploadResult: Sendable {
    public let statusCode: Int
    public let responseBodyPreview: String?

    public init(statusCode: Int, responseBodyPreview: String?) {
        self.statusCode = statusCode
        self.responseBodyPreview = responseBodyPreview
    }
}

public enum SyncPackageUploadError: LocalizedError {
    case invalidHTTPResponse
    case unexpectedStatusCode(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "上传失败：服务端返回了无效响应。"
        case .unexpectedStatusCode(let statusCode, let preview):
            if let preview, !preview.isEmpty {
                return "上传失败：HTTP \(statusCode)，响应：\(preview)"
            }
            return "上传失败：HTTP \(statusCode)。"
        }
    }
}

public enum SyncPackageUploadService {
    public typealias Transport = (_ request: URLRequest, _ body: Data) async throws -> (Data, URLResponse)
    public typealias FileTransport = (_ request: URLRequest, _ fileURL: URL) async throws -> (Data, URLResponse)

    /// 直接上传导出数据。
    public static func upload(
        exportData: Data,
        suggestedFileName: String,
        to endpoint: URL,
        timeout: TimeInterval = 30,
        transport: Transport? = nil
    ) async throws -> SyncPackageUploadResult {
        let request = makeUploadRequest(
            suggestedFileName: suggestedFileName,
            endpoint: endpoint,
            timeout: timeout
        )

        let sender = transport ?? { request, body in
            var req = request
            req.httpBody = body
            return try await NetworkSessionConfiguration.shared.data(for: req)
        }
        let (responseData, response) = try await sender(request, exportData)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncPackageUploadError.invalidHTTPResponse
        }

        let preview = responsePreview(from: responseData)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SyncPackageUploadError.unexpectedStatusCode(httpResponse.statusCode, preview)
        }

        return SyncPackageUploadResult(
            statusCode: httpResponse.statusCode,
            responseBodyPreview: preview
        )
    }

    /// 直接从导出文件上传，避免把完整备份包放入 HTTP body 内存。
    public static func upload(
        exportFileURL: URL,
        suggestedFileName: String,
        to endpoint: URL,
        timeout: TimeInterval = 30,
        transport: FileTransport? = nil
    ) async throws -> SyncPackageUploadResult {
        let request = makeUploadRequest(
            suggestedFileName: suggestedFileName,
            endpoint: endpoint,
            timeout: timeout
        )

        let sender = transport ?? { request, fileURL in
            try await NetworkSessionConfiguration.shared.upload(for: request, fromFile: fileURL)
        }
        let (responseData, response) = try await sender(request, exportFileURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncPackageUploadError.invalidHTTPResponse
        }

        let preview = responsePreview(from: responseData)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SyncPackageUploadError.unexpectedStatusCode(httpResponse.statusCode, preview)
        }

        return SyncPackageUploadResult(
            statusCode: httpResponse.statusCode,
            responseBodyPreview: preview
        )
    }

    /// 上传加密快照文件（.elsbackup），使用流式文件传输避免占用过多内存。
    /// - Parameters:
    ///   - backupFileURL: .elsbackup 文件 URL（明文 ZIP 或加密 ZIP 均可）
    ///   - endpoint: 上传目标 URL（R2 / 自有服务器等）
    ///   - timeout: 超时时间（默认 60 秒，快照文件通常比 JSON 包大）
    ///   - transport: 可选自定义传输层，主要用于单元测试
    public static func uploadBackup(
        backupFileURL: URL,
        to endpoint: URL,
        timeout: TimeInterval = 60,
        transport: FileTransport? = nil
    ) async throws -> SyncPackageUploadResult {
        let request = makeBackupUploadRequest(
            fileName: backupFileURL.lastPathComponent,
            endpoint: endpoint,
            timeout: timeout
        )

        let sender = transport ?? { request, fileURL in
            try await NetworkSessionConfiguration.shared.upload(for: request, fromFile: fileURL)
        }
        let (responseData, response) = try await sender(request, backupFileURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncPackageUploadError.invalidHTTPResponse
        }

        let preview = responsePreview(from: responseData)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SyncPackageUploadError.unexpectedStatusCode(httpResponse.statusCode, preview)
        }

        return SyncPackageUploadResult(
            statusCode: httpResponse.statusCode,
            responseBodyPreview: preview
        )
    }

    /// 从同步包导出后直接上传。
    public static func upload(
        package: SyncPackage,
        to endpoint: URL,
        timeout: TimeInterval = 30,
        transport: Transport? = nil
    ) async throws -> SyncPackageUploadResult {
        if let transport {
            let output = try SyncPackageTransferService.exportPackage(package)
            return try await upload(
                exportData: output.data,
                suggestedFileName: output.suggestedFileName,
                to: endpoint,
                timeout: timeout,
                transport: transport
            )
        }

        let output = try SyncPackageTransferService.exportPackageToTemporaryFile(package)
        defer { try? FileManager.default.removeItem(at: output.fileURL) }
        return try await upload(
            exportFileURL: output.fileURL,
            suggestedFileName: output.suggestedFileName,
            to: endpoint,
            timeout: timeout
        )
    }
}

private extension SyncPackageUploadService {
    static func makeUploadRequest(
        suggestedFileName: String,
        endpoint: URL,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(suggestedFileName, forHTTPHeaderField: "X-ETOS-Backup-FileName")
        request.setValue("\(SyncPackageTransferService.currentSchemaVersion)", forHTTPHeaderField: "X-ETOS-Backup-Schema")
        return request
    }

    /// 构造 .elsbackup 上传请求（二进制流，Content-Type: application/octet-stream）。
    static func makeBackupUploadRequest(
        fileName: String,
        endpoint: URL,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(fileName, forHTTPHeaderField: "X-ETOS-Backup-FileName")
        return request
    }

    static func responsePreview(from data: Data, maxBytes: Int = 256) -> String? {
        guard !data.isEmpty else { return nil }
        let clipped = data.prefix(maxBytes)
        guard let text = String(data: clipped, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}

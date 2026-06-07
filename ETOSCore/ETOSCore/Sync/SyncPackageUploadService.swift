// ============================================================================
// SyncPackageUploadService.swift
// ============================================================================
// 同步数据包上传服务
// - 将导出的 JSON 数据包通过 HTTP POST 上传到指定地址
// - 将离线 .elsbackup 快照上传到旧版 HTTP 端点或 S3 兼容对象存储
// - 统一处理状态码与错误信息，供 iOS/watchOS 复用
// ============================================================================

import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct S3CompatibleUploadConfiguration: Equatable, Sendable {
    public let endpoint: URL
    public let region: String
    public let bucket: String
    public let keyPrefix: String
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?

    public init(
        endpoint: URL,
        region: String,
        bucket: String,
        keyPrefix: String = "",
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil
    ) {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.keyPrefix = keyPrefix
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

public struct S3CompatibleRemoteSnapshot: Equatable, Identifiable, Sendable {
    public let key: String
    public let fileName: String
    public let byteSize: Int64?
    public let lastModified: Date?

    public var id: String { key }

    public init(key: String, fileName: String, byteSize: Int64?, lastModified: Date?) {
        self.key = key
        self.fileName = fileName
        self.byteSize = byteSize
        self.lastModified = lastModified
    }
}

public struct SyncPackageUploadResult: Sendable {
    public let statusCode: Int
    public let responseBodyPreview: String?

    public init(statusCode: Int, responseBodyPreview: String?) {
        self.statusCode = statusCode
        self.responseBodyPreview = responseBodyPreview
    }
}

public struct SyncPackageUploadProgress: Equatable, Sendable {
    public let bytesSent: Int64
    public let totalBytes: Int64

    public init(bytesSent: Int64, totalBytes: Int64) {
        let normalizedTotalBytes = max(0, totalBytes)
        let normalizedBytesSent = max(0, bytesSent)
        self.totalBytes = normalizedTotalBytes
        self.bytesSent = normalizedTotalBytes > 0
            ? min(normalizedBytesSent, normalizedTotalBytes)
            : normalizedBytesSent
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesSent) / Double(totalBytes), 0), 1)
    }
}

public struct SyncPackageDownloadProgress: Equatable, Sendable {
    public let bytesReceived: Int64
    public let totalBytes: Int64

    public init(bytesReceived: Int64, totalBytes: Int64) {
        let normalizedTotalBytes = max(0, totalBytes)
        let normalizedBytesReceived = max(0, bytesReceived)
        self.totalBytes = normalizedTotalBytes
        self.bytesReceived = normalizedTotalBytes > 0
            ? min(normalizedBytesReceived, normalizedTotalBytes)
            : normalizedBytesReceived
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
    }
}

public enum SyncPackageUploadError: LocalizedError {
    case invalidHTTPResponse
    case unexpectedStatusCode(Int, String?)
    case invalidS3Configuration(String)
    case invalidS3ListResponse
    case fileHashFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return NSLocalizedString("上传失败：服务端返回了无效响应。", comment: "")
        case .unexpectedStatusCode(let statusCode, let preview):
            if let preview, !preview.isEmpty {
                return String(
                    format: NSLocalizedString("上传失败：HTTP %d，响应：%@", comment: ""),
                    statusCode,
                    preview
                )
            }
            return String(format: NSLocalizedString("上传失败：HTTP %d。", comment: ""), statusCode)
        case .invalidS3Configuration(let reason):
            return reason
        case .invalidS3ListResponse:
            return NSLocalizedString("远端快照列表解析失败。", comment: "")
        case .fileHashFailed(let reason):
            return String(format: NSLocalizedString("计算备份文件校验值失败：%@", comment: ""), reason)
        }
    }
}

public enum SyncPackageUploadService {
    public typealias Transport = (_ request: URLRequest, _ body: Data) async throws -> (Data, URLResponse)
    public typealias FileTransport = (_ request: URLRequest, _ fileURL: URL) async throws -> (Data, URLResponse)
    public typealias RequestTransport = (_ request: URLRequest) async throws -> (Data, URLResponse)
    public typealias DownloadTransport = (_ request: URLRequest) async throws -> (URL, URLResponse)
    public typealias ProgressHandler = @Sendable (SyncPackageUploadProgress) -> Void
    public typealias DownloadProgressHandler = @Sendable (SyncPackageDownloadProgress) -> Void

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
        transport: FileTransport? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> SyncPackageUploadResult {
        let request = makeUploadRequest(
            suggestedFileName: suggestedFileName,
            endpoint: endpoint,
            timeout: timeout
        )

        reportInitialProgress(for: exportFileURL, progress: progress)
        let sender = transport ?? { request, fileURL in
            try await uploadFile(request: request, fileURL: fileURL, progress: progress)
        }
        let (responseData, response) = try await sender(request, exportFileURL)
        reportCompletedProgress(for: exportFileURL, progress: progress)

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

    /// 旧版 HTTP POST 快照上传，保留给测试与内部兼容路径。
    public static func uploadSnapshot(
        fileURL: URL,
        suggestedFileName: String? = nil,
        to endpoint: URL,
        timeout: TimeInterval = 30,
        transport: FileTransport? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> SyncPackageUploadResult {
        let fileName = suggestedFileName ?? fileURL.lastPathComponent
        let request = makeUploadRequest(
            suggestedFileName: fileName.isEmpty ? "ETOS-Snapshot.\(SnapshotBuilder.fileExtension)" : fileName,
            endpoint: endpoint,
            timeout: timeout,
            contentType: "application/octet-stream",
            schemaVersion: nil
        )

        reportInitialProgress(for: fileURL, progress: progress)
        let sender = transport ?? { request, fileURL in
            try await uploadFile(request: request, fileURL: fileURL, progress: progress)
        }
        let (responseData, response) = try await sender(request, fileURL)
        reportCompletedProgress(for: fileURL, progress: progress)

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

    /// 使用 S3 Signature V4 上传离线快照，兼容 AWS S3、Cloudflare R2 与常见 S3 API 对象存储。
    public static func uploadSnapshot(
        fileURL: URL,
        suggestedFileName: String? = nil,
        s3 configuration: S3CompatibleUploadConfiguration,
        timeout: TimeInterval = 30,
        now: Date = Date(),
        transport: FileTransport? = nil,
        progress: ProgressHandler? = nil
    ) async throws -> SyncPackageUploadResult {
        let fileName = suggestedFileName ?? fileURL.lastPathComponent
        reportInitialProgress(for: fileURL, progress: progress)
        let request = try makeS3UploadRequest(
            fileURL: fileURL,
            suggestedFileName: fileName.isEmpty ? "ETOS-Snapshot.\(SnapshotBuilder.fileExtension)" : fileName,
            configuration: configuration,
            timeout: timeout,
            now: now
        )

        let sender = transport ?? { request, fileURL in
            try await uploadFile(request: request, fileURL: fileURL, progress: progress)
        }
        let (responseData, response) = try await sender(request, fileURL)
        reportCompletedProgress(for: fileURL, progress: progress)

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

    public static func listRemoteSnapshots(
        s3 configuration: S3CompatibleUploadConfiguration,
        timeout: TimeInterval = 30,
        now: Date = Date(),
        transport: RequestTransport? = nil
    ) async throws -> [S3CompatibleRemoteSnapshot] {
        let request = try makeS3ListObjectsRequest(
            configuration: configuration,
            timeout: timeout,
            now: now
        )
        let sender = transport ?? { request in
            try await NetworkSessionConfiguration.shared.data(for: request)
        }
        let (responseData, response) = try await sender(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncPackageUploadError.invalidHTTPResponse
        }

        let preview = responsePreview(from: responseData)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SyncPackageUploadError.unexpectedStatusCode(httpResponse.statusCode, preview)
        }

        return try parseS3RemoteSnapshots(from: responseData)
    }

    public static func downloadRemoteSnapshot(
        objectKey: String,
        s3 configuration: S3CompatibleUploadConfiguration,
        destinationDirectory: URL = FileManager.default.temporaryDirectory,
        timeout: TimeInterval = 180,
        now: Date = Date(),
        transport: DownloadTransport? = nil,
        progress: DownloadProgressHandler? = nil
    ) async throws -> URL {
        let request = try makeS3GetObjectRequest(
            objectKey: objectKey,
            configuration: configuration,
            timeout: timeout,
            now: now
        )
        let downloader = transport ?? { request in
            try await downloadTemporaryFile(request: request, progress: progress)
        }
        let (downloadedURL, response) = try await downloader(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncPackageUploadError.invalidHTTPResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SyncPackageUploadError.unexpectedStatusCode(httpResponse.statusCode, nil)
        }

        reportCompletedDownloadProgress(for: downloadedURL, response: response, progress: progress)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let fileName = normalizedSnapshotFileName(for: objectKey)
        let destinationURL = destinationDirectory
            .appendingPathComponent("Remote-\(UUID().uuidString)-\(fileName)", isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: downloadedURL, to: destinationURL)
        return destinationURL
    }

    public static func downloadTemporaryFile(
        request: URLRequest,
        progress: DownloadProgressHandler? = nil
    ) async throws -> (URL, URLResponse) {
        try await downloadFile(request: request, progress: progress)
    }
}

private extension SyncPackageUploadService {
    static let s3Algorithm = "AWS4-HMAC-SHA256"
    static let s3Service = "s3"
    static let s3RequestTerminator = "aws4_request"

    static func uploadFile(
        request: URLRequest,
        fileURL: URL,
        progress: ProgressHandler?
    ) async throws -> (Data, URLResponse) {
        let totalBytes = fileSizeInBytes(at: fileURL)
        let delegate = UploadProgressDelegate(totalBytes: totalBytes, progress: progress)
        return try await NetworkSessionConfiguration.shared.upload(
            for: request,
            fromFile: fileURL,
            delegate: delegate
        )
    }

    static func downloadFile(
        request: URLRequest,
        progress: DownloadProgressHandler?
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate(progress: progress)
        return try await NetworkSessionConfiguration.shared.download(
            for: request,
            delegate: delegate
        )
    }

    static func reportInitialProgress(for fileURL: URL, progress: ProgressHandler?) {
        guard let progress else { return }
        progress(SyncPackageUploadProgress(bytesSent: 0, totalBytes: fileSizeInBytes(at: fileURL)))
    }

    static func reportCompletedProgress(for fileURL: URL, progress: ProgressHandler?) {
        guard let progress else { return }
        let totalBytes = fileSizeInBytes(at: fileURL)
        progress(SyncPackageUploadProgress(bytesSent: totalBytes, totalBytes: totalBytes))
    }

    static func fileSizeInBytes(at fileURL: URL) -> Int64 {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func reportCompletedDownloadProgress(
        for fileURL: URL,
        response: URLResponse,
        progress: DownloadProgressHandler?
    ) {
        guard let progress else { return }
        let receivedBytes = fileSizeInBytes(at: fileURL)
        let expectedBytes = response.expectedContentLength > 0
            ? response.expectedContentLength
            : receivedBytes
        progress(SyncPackageDownloadProgress(bytesReceived: receivedBytes, totalBytes: expectedBytes))
    }

    static func makeUploadRequest(
        suggestedFileName: String,
        endpoint: URL,
        timeout: TimeInterval,
        contentType: String = "application/json",
        schemaVersion: Int? = SyncPackageTransferService.currentSchemaVersion
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(suggestedFileName, forHTTPHeaderField: "X-ETOS-Backup-FileName")
        if let schemaVersion {
            request.setValue("\(schemaVersion)", forHTTPHeaderField: "X-ETOS-Backup-Schema")
        }
        return request
    }

    static func makeS3UploadRequest(
        fileURL: URL,
        suggestedFileName: String,
        configuration: S3CompatibleUploadConfiguration,
        timeout: TimeInterval,
        now: Date
    ) throws -> URLRequest {
        let normalized = try normalizedS3Configuration(configuration)
        let objectKey = makeObjectKey(prefix: normalized.keyPrefix, suggestedFileName: suggestedFileName)
        let uploadURL = try makeS3PathStyleURL(
            endpoint: normalized.endpoint,
            bucket: normalized.bucket,
            objectKey: objectKey
        )
        let payloadHash = try sha256Hex(forFileAt: fileURL)
        let amzDate = s3Timestamp(from: now)
        let dateStamp = s3DateStamp(from: now)
        let contentType = "application/octet-stream"

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = timeout
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        if let sessionToken = normalized.sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
        }

        let authorization = try s3AuthorizationHeader(
            method: "PUT",
            url: uploadURL,
            payloadHash: payloadHash,
            amzDate: amzDate,
            dateStamp: dateStamp,
            configuration: normalized,
            signedHeaderValues: ["content-type": contentType]
        )
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    static func makeS3ListObjectsRequest(
        configuration: S3CompatibleUploadConfiguration,
        timeout: TimeInterval,
        now: Date
    ) throws -> URLRequest {
        let normalized = try normalizedS3Configuration(configuration)
        var listURL = try makeS3PathStyleURL(
            endpoint: normalized.endpoint,
            bucket: normalized.bucket,
            objectKey: ""
        )
        guard var components = URLComponents(url: listURL, resolvingAgainstBaseURL: false) else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("无法生成对象存储列表地址。", comment: "")
            )
        }
        let prefix = normalized.keyPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var queryItems = [
            ("list-type", "2"),
            ("max-keys", "1000")
        ]
        if !prefix.isEmpty {
            queryItems.append(("prefix", prefix + "/"))
        }
        components.percentEncodedQuery = queryItems
            .sorted { $0.0 < $1.0 }
            .map { "\(s3URIEncode($0.0))=\(s3URIEncode($0.1))" }
            .joined(separator: "&")
        guard let url = components.url else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("无法生成对象存储列表地址。", comment: "")
            )
        }
        listURL = url
        return try makeS3SignedRequest(
            method: "GET",
            url: listURL,
            timeout: timeout,
            configuration: normalized,
            now: now
        )
    }

    static func makeS3GetObjectRequest(
        objectKey: String,
        configuration: S3CompatibleUploadConfiguration,
        timeout: TimeInterval,
        now: Date
    ) throws -> URLRequest {
        let normalized = try normalizedS3Configuration(configuration)
        let cleanedObjectKey = objectKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanedObjectKey.isEmpty else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("远端快照路径为空。", comment: "")
            )
        }
        let objectURL = try makeS3PathStyleURL(
            endpoint: normalized.endpoint,
            bucket: normalized.bucket,
            objectKey: cleanedObjectKey
        )
        return try makeS3SignedRequest(
            method: "GET",
            url: objectURL,
            timeout: timeout,
            configuration: normalized,
            now: now
        )
    }

    static func makeS3SignedRequest(
        method: String,
        url: URL,
        timeout: TimeInterval,
        configuration: S3CompatibleUploadConfiguration,
        now: Date
    ) throws -> URLRequest {
        let payloadHash = sha256Hex(Data())
        let amzDate = s3Timestamp(from: now)
        let dateStamp = s3DateStamp(from: now)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        if let sessionToken = configuration.sessionToken {
            request.setValue(sessionToken, forHTTPHeaderField: "x-amz-security-token")
        }
        let authorization = try s3AuthorizationHeader(
            method: method,
            url: url,
            payloadHash: payloadHash,
            amzDate: amzDate,
            dateStamp: dateStamp,
            configuration: configuration,
            signedHeaderValues: [:]
        )
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    static func normalizedS3Configuration(
        _ configuration: S3CompatibleUploadConfiguration
    ) throws -> S3CompatibleUploadConfiguration {
        guard let scheme = configuration.endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              configuration.endpoint.host?.isEmpty == false else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("对象存储 Endpoint 必须是完整的 http/https URL。", comment: "")
            )
        }
        guard configuration.endpoint.query == nil,
              configuration.endpoint.fragment == nil else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("对象存储 Endpoint 不能包含查询参数或片段。", comment: "")
            )
        }

        let region = configuration.region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("请填写对象存储 Region；R2 通常填写 auto，AWS S3 填写实际区域。", comment: "")
            )
        }

        let bucket = configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bucket.isEmpty else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("请填写存储桶名称。", comment: "")
            )
        }

        let accessKeyID = configuration.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKeyID.isEmpty else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("请填写 Access Key ID。", comment: "")
            )
        }

        let secretAccessKey = configuration.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secretAccessKey.isEmpty else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("请填写 Secret Access Key。", comment: "")
            )
        }

        let sessionToken = configuration.sessionToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return S3CompatibleUploadConfiguration(
            endpoint: configuration.endpoint,
            region: region,
            bucket: bucket,
            keyPrefix: configuration.keyPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken
        )
    }

    static func makeObjectKey(prefix: String, suggestedFileName: String) -> String {
        let cleanedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanedFileName = suggestedFileName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanedPrefix.isEmpty else { return cleanedFileName }
        return "\(cleanedPrefix)/\(cleanedFileName)"
    }

    static func makeS3PathStyleURL(endpoint: URL, bucket: String, objectKey: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("对象存储 Endpoint 必须是完整的 http/https URL。", comment: "")
            )
        }

        let basePath = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let rawPath = [basePath, bucket, objectKey]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.percentEncodedPath = "/" + rawPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { s3URIEncode(String($0)) }
            .joined(separator: "/")
        components.percentEncodedQuery = nil
        components.fragment = nil

        guard let url = components.url else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("无法生成对象存储上传地址。", comment: "")
            )
        }
        return url
    }

    static func s3AuthorizationHeader(
        method: String,
        url: URL,
        payloadHash: String,
        amzDate: String,
        dateStamp: String,
        configuration: S3CompatibleUploadConfiguration,
        signedHeaderValues: [String: String]
    ) throws -> String {
        let credentialScope = "\(dateStamp)/\(configuration.region)/\(s3Service)/\(s3RequestTerminator)"
        var headers = signedHeaderValues.reduce(into: [String: String]()) { partialResult, item in
            partialResult[item.key.lowercased()] = item.value
        }
        headers.merge([
            "host": try hostHeaderValue(for: url),
            "x-amz-content-sha256": payloadHash,
            "x-amz-date": amzDate
        ]) { _, newValue in newValue }
        if let sessionToken = configuration.sessionToken {
            headers["x-amz-security-token"] = sessionToken
        }

        let sortedHeaderNames = headers.keys.sorted()
        let canonicalHeaders = sortedHeaderNames
            .map { "\($0):\(normalizedHeaderValue(headers[$0] ?? ""))" }
            .joined(separator: "\n") + "\n"
        let signedHeaders = sortedHeaderNames.joined(separator: ";")
        let canonicalRequest = [
            method,
            canonicalPath(for: url),
            canonicalQuery(for: url),
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        let stringToSign = [
            s3Algorithm,
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")
        let signature = s3Signature(
            stringToSign: stringToSign,
            secretAccessKey: configuration.secretAccessKey,
            dateStamp: dateStamp,
            region: configuration.region
        )

        return "\(s3Algorithm) Credential=\(configuration.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    static func canonicalPath(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !components.percentEncodedPath.isEmpty else {
            return "/"
        }
        return components.percentEncodedPath
    }

    static func canonicalQuery(for url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    }

    static func s3Signature(
        stringToSign: String,
        secretAccessKey: String,
        dateStamp: String,
        region: String
    ) -> String {
        let dateKey = hmacSHA256(Data(dateStamp.utf8), key: Data("AWS4\(secretAccessKey)".utf8))
        let regionKey = hmacSHA256(Data(region.utf8), key: dateKey)
        let serviceKey = hmacSHA256(Data(s3Service.utf8), key: regionKey)
        let signingKey = hmacSHA256(Data(s3RequestTerminator.utf8), key: serviceKey)
        return hexString(hmacSHA256(Data(stringToSign.utf8), key: signingKey))
    }

    static func hmacSHA256(_ data: Data, key: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let digest = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(digest)
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return hexString(Data(digest))
    }

    static func sha256Hex(forFileAt fileURL: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hexString(Data(hasher.finalize()))
        } catch {
            throw SyncPackageUploadError.fileHashFailed(error.localizedDescription)
        }
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func s3URIEncode(_ value: String) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        var encoded = ""
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    static func hostHeaderValue(for url: URL) throws -> String {
        guard var host = url.host?.lowercased(), !host.isEmpty else {
            throw SyncPackageUploadError.invalidS3Configuration(
                NSLocalizedString("对象存储 Endpoint 必须包含主机名。", comment: "")
            )
        }
        if let port = url.port,
           !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            host += ":\(port)"
        }
        return host
    }

    static func parseS3RemoteSnapshots(from data: Data) throws -> [S3CompatibleRemoteSnapshot] {
        let parserDelegate = S3ListObjectsV2Parser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw SyncPackageUploadError.invalidS3ListResponse
        }
        return parserDelegate.objects
            .filter { $0.key.pathExtensionCaseInsensitive == SnapshotBuilder.fileExtension }
            .sorted { lhs, rhs in
                switch (lhs.lastModified, rhs.lastModified) {
                case let (lhsDate?, rhsDate?):
                    return lhsDate > rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.key > rhs.key
                }
            }
    }

    static func normalizedSnapshotFileName(for objectKey: String) -> String {
        let fileName = URL(fileURLWithPath: objectKey).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty else {
            return "Remote-Snapshot.\(SnapshotBuilder.fileExtension)"
        }
        guard fileName.pathExtensionCaseInsensitive == SnapshotBuilder.fileExtension else {
            return fileName.appending(".\(SnapshotBuilder.fileExtension)")
        }
        return fileName
    }

    static func normalizedHeaderValue(_ value: String) -> String {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    static func s3Timestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func s3DateStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
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

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let totalBytes: Int64
    private let progress: SyncPackageUploadService.ProgressHandler?

    init(totalBytes: Int64, progress: SyncPackageUploadService.ProgressHandler?) {
        self.totalBytes = totalBytes
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let expectedBytes = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : totalBytes
        progress?(SyncPackageUploadProgress(bytesSent: totalBytesSent, totalBytes: expectedBytes))
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progress: SyncPackageUploadService.DownloadProgressHandler?

    init(progress: SyncPackageUploadService.DownloadProgressHandler?) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        progress?(SyncPackageDownloadProgress(bytesReceived: totalBytesWritten, totalBytes: expectedBytes))
    }
}

private final class S3ListObjectsV2Parser: NSObject, XMLParserDelegate {
    struct PartialObject {
        var key = ""
        var byteSize: Int64?
        var lastModified: Date?
    }

    private(set) var objects: [S3CompatibleRemoteSnapshot] = []
    private var currentObject: PartialObject?
    private var currentElement = ""
    private var currentText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" {
            currentObject = PartialObject()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key":
            currentObject?.key = text
        case "Size":
            currentObject?.byteSize = Int64(text)
        case "LastModified":
            currentObject?.lastModified = Self.lastModifiedFormatter.date(from: text)
                ?? Self.lastModifiedFormatterWithoutFractions.date(from: text)
        case "Contents":
            if let object = currentObject, !object.key.isEmpty {
                objects.append(
                    S3CompatibleRemoteSnapshot(
                        key: object.key,
                        fileName: SyncPackageUploadService.normalizedSnapshotFileName(for: object.key),
                        byteSize: object.byteSize,
                        lastModified: object.lastModified
                    )
                )
            }
            currentObject = nil
        default:
            break
        }
        currentElement = ""
        currentText = ""
    }

    private static let lastModifiedFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let lastModifiedFormatterWithoutFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var pathExtensionCaseInsensitive: String {
        URL(fileURLWithPath: self).pathExtension.lowercased()
    }
}

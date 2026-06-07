// ============================================================================
// SyncPackageUploadServiceTests.swift
// ============================================================================
// SyncPackageUploadService 上传行为测试
// - 验证成功上传时的请求构建与返回值
// - 验证非 2xx 状态码与无效响应的错误处理
// ============================================================================

import Foundation
import CryptoKit
import Testing
@testable import ETOSCore

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

    @Test("文件上传会从导出文件读取请求体")
    func testUploadFileSuccess() async throws {
        let endpoint = try #require(URL(string: "https://example.com/backup"))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-upload-\(UUID().uuidString).json")
        try Data("{\"ok\":true}".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var capturedRequest: URLRequest?
        var capturedFileURL: URL?

        let result = try await SyncPackageUploadService.upload(
            exportFileURL: fileURL,
            suggestedFileName: "ETOS-数据导出.json",
            to: endpoint,
            transport: { request, bodyFileURL in
                capturedRequest = request
                capturedFileURL = bodyFileURL
                let response = try #require(
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (Data("received".utf8), response)
            }
        )

        #expect(result.statusCode == 200)
        #expect(result.responseBodyPreview == "received")
        #expect(capturedRequest?.httpBody == nil)
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-ETOS-Backup-FileName") == "ETOS-数据导出.json")
        #expect(capturedFileURL == fileURL)
    }

    @Test("文件上传会向调用方报告初始与完成进度")
    func testUploadFileReportsProgress() async throws {
        let endpoint = try #require(URL(string: "https://example.com/backup"))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-progress-\(UUID().uuidString).json")
        try Data(repeating: 1, count: 4096).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let progressEvents = UploadProgressRecorder()

        _ = try await SyncPackageUploadService.upload(
            exportFileURL: fileURL,
            suggestedFileName: "ETOS-数据导出.json",
            to: endpoint,
            transport: { _, _ in
                let response = try #require(
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (Data(), response)
            },
            progress: { progress in
                progressEvents.append(progress)
            }
        )

        let events = progressEvents.events
        #expect(events.first == SyncPackageUploadProgress(bytesSent: 0, totalBytes: 4096))
        #expect(events.last == SyncPackageUploadProgress(bytesSent: 4096, totalBytes: 4096))
        #expect(events.last?.fractionCompleted == 1)
    }

    @Test("离线快照上传会使用二进制请求头")
    func testUploadSnapshotUsesBinaryRequestHeaders() async throws {
        let endpoint = try #require(URL(string: "https://example.com/backup"))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-snapshot-\(UUID().uuidString).elsbackup")
        try Data("encrypted-backup".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var capturedRequest: URLRequest?
        var capturedFileURL: URL?

        let result = try await SyncPackageUploadService.uploadSnapshot(
            fileURL: fileURL,
            suggestedFileName: "encrypted.elsbackup",
            to: endpoint,
            transport: { request, bodyFileURL in
                capturedRequest = request
                capturedFileURL = bodyFileURL
                let response = try #require(
                    HTTPURLResponse(url: endpoint, statusCode: 202, httpVersion: nil, headerFields: nil)
                )
                return (Data("queued".utf8), response)
            }
        )

        #expect(result.statusCode == 202)
        #expect(result.responseBodyPreview == "queued")
        #expect(capturedRequest?.httpBody == nil)
        #expect(capturedRequest?.httpMethod == "POST")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-ETOS-Backup-FileName") == "encrypted.elsbackup")
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-ETOS-Backup-Schema") == nil)
        #expect(capturedFileURL == fileURL)
    }

    @Test("上传进度会限制在总大小范围内")
    func testUploadProgressClampsValues() {
        let progress = SyncPackageUploadProgress(bytesSent: 2048, totalBytes: 1024)

        #expect(progress.bytesSent == 1024)
        #expect(progress.totalBytes == 1024)
        #expect(progress.fractionCompleted == 1)
    }

    @Test("S3 兼容快照上传会生成 SigV4 PUT 请求")
    func testS3UploadSnapshotBuildsSignedPutRequest() async throws {
        let endpoint = try #require(URL(string: "https://abc123.r2.cloudflarestorage.com"))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-snapshot-\(UUID().uuidString).elsbackup")
        let payload = Data("encrypted-backup".utf8)
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let configuration = S3CompatibleUploadConfiguration(
            endpoint: endpoint,
            region: "auto",
            bucket: "etos-bucket",
            keyPrefix: "mobile backups",
            accessKeyID: "test-access",
            secretAccessKey: "test-secret",
            sessionToken: "test-session-token"
        )
        let now = try #require(ISO8601DateFormatter().date(from: "2024-05-15T12:34:56Z"))
        var capturedRequest: URLRequest?
        var capturedFileURL: URL?

        let result = try await SyncPackageUploadService.uploadSnapshot(
            fileURL: fileURL,
            suggestedFileName: "encrypted.elsbackup",
            s3: configuration,
            now: now,
            transport: { request, bodyFileURL in
                capturedRequest = request
                capturedFileURL = bodyFileURL
                let response = try #require(
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (Data(), response)
            }
        )

        let payloadHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(result.statusCode == 200)
        #expect(capturedRequest?.url?.absoluteString == "https://abc123.r2.cloudflarestorage.com/etos-bucket/mobile%20backups/encrypted.elsbackup")
        #expect(capturedRequest?.httpMethod == "PUT")
        #expect(capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        #expect(capturedRequest?.value(forHTTPHeaderField: "x-amz-content-sha256") == payloadHash)
        #expect(capturedRequest?.value(forHTTPHeaderField: "x-amz-date") == "20240515T123456Z")
        #expect(capturedRequest?.value(forHTTPHeaderField: "x-amz-security-token") == "test-session-token")
        let authorization = try #require(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("AWS4-HMAC-SHA256 Credential=test-access/20240515/auto/s3/aws4_request"))
        #expect(authorization.contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token"))
        #expect(authorization.contains("Signature="))
        #expect(capturedFileURL == fileURL)
    }

    @Test("S3 兼容上传缺少凭据时会在发送前报错")
    func testS3UploadSnapshotRequiresCredentials() async throws {
        let endpoint = try #require(URL(string: "https://s3.us-east-1.amazonaws.com"))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-invalid-\(UUID().uuidString).elsbackup")
        try Data("backup".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try await SyncPackageUploadService.uploadSnapshot(
                fileURL: fileURL,
                s3: S3CompatibleUploadConfiguration(
                    endpoint: endpoint,
                    region: "us-east-1",
                    bucket: "etos-bucket",
                    accessKeyID: "test-access",
                    secretAccessKey: ""
                ),
                transport: { _, _ in
                    Issue.record("缺少 Secret Access Key 时不应发送请求。")
                    let response = try #require(
                        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                    )
                    return (Data(), response)
                }
            )
            Issue.record("预期应抛出 invalidS3Configuration。")
        } catch let error as SyncPackageUploadError {
            switch error {
            case .invalidS3Configuration(let reason):
                #expect(reason == NSLocalizedString("请填写 Secret Access Key。", comment: ""))
            default:
                Issue.record("错误类型不符合预期：\(error.localizedDescription)")
            }
        }
    }

    @Test("S3 兼容远端快照列表会生成 SigV4 ListObjectsV2 请求")
    func testS3ListRemoteSnapshotsBuildsSignedListRequest() async throws {
        let endpoint = try #require(URL(string: "https://abc123.r2.cloudflarestorage.com"))
        let configuration = S3CompatibleUploadConfiguration(
            endpoint: endpoint,
            region: "auto",
            bucket: "etos-bucket",
            keyPrefix: "mobile backups",
            accessKeyID: "test-access",
            secretAccessKey: "test-secret",
            sessionToken: "test-session-token"
        )
        let now = try #require(ISO8601DateFormatter().date(from: "2024-05-15T12:34:56Z"))
        var capturedRequest: URLRequest?
        let responseXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult>
          <Contents>
            <Key>mobile backups/ETOS-Snapshot-a.elsbackup</Key>
            <LastModified>2024-05-15T12:34:56.000Z</LastModified>
            <Size>2048</Size>
          </Contents>
          <Contents>
            <Key>mobile backups/readme.txt</Key>
            <LastModified>2024-05-15T12:00:00.000Z</LastModified>
            <Size>12</Size>
          </Contents>
        </ListBucketResult>
        """

        let snapshots = try await SyncPackageUploadService.listRemoteSnapshots(
            s3: configuration,
            now: now,
            transport: { request in
                capturedRequest = request
                let response = try #require(
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (Data(responseXML.utf8), response)
            }
        )

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.key == "mobile backups/ETOS-Snapshot-a.elsbackup")
        #expect(snapshots.first?.fileName == "ETOS-Snapshot-a.elsbackup")
        #expect(snapshots.first?.byteSize == 2048)
        #expect(capturedRequest?.url?.absoluteString == "https://abc123.r2.cloudflarestorage.com/etos-bucket?list-type=2&max-keys=1000&prefix=mobile%20backups%2F")
        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.value(forHTTPHeaderField: "x-amz-date") == "20240515T123456Z")
        #expect(capturedRequest?.value(forHTTPHeaderField: "x-amz-security-token") == "test-session-token")
        let authorization = try #require(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("AWS4-HMAC-SHA256 Credential=test-access/20240515/auto/s3/aws4_request"))
        #expect(authorization.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token"))
    }

    @Test("S3 兼容远端快照下载会生成 SigV4 GET 请求并写入临时文件")
    func testS3DownloadRemoteSnapshotBuildsSignedGetRequest() async throws {
        let endpoint = try #require(URL(string: "https://abc123.r2.cloudflarestorage.com"))
        let configuration = S3CompatibleUploadConfiguration(
            endpoint: endpoint,
            region: "auto",
            bucket: "etos-bucket",
            keyPrefix: "mobile backups",
            accessKeyID: "test-access",
            secretAccessKey: "test-secret"
        )
        let now = try #require(ISO8601DateFormatter().date(from: "2024-05-15T12:34:56Z"))
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-download-source-\(UUID().uuidString).elsbackup")
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-download-destination-\(UUID().uuidString)", isDirectory: true)
        try Data("snapshot".utf8).write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationDirectory)
        }

        var capturedRequest: URLRequest?
        let downloadedURL = try await SyncPackageUploadService.downloadRemoteSnapshot(
            objectKey: "mobile backups/ETOS-Snapshot-a.elsbackup",
            s3: configuration,
            destinationDirectory: destinationDirectory,
            now: now,
            transport: { request in
                capturedRequest = request
                let response = try #require(
                    HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                )
                return (sourceURL, response)
            }
        )

        #expect(capturedRequest?.url?.absoluteString == "https://abc123.r2.cloudflarestorage.com/etos-bucket/mobile%20backups/ETOS-Snapshot-a.elsbackup")
        #expect(capturedRequest?.httpMethod == "GET")
        #expect(capturedRequest?.value(forHTTPHeaderField: "x-amz-date") == "20240515T123456Z")
        let authorization = try #require(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        #expect(try Data(contentsOf: downloadedURL) == Data("snapshot".utf8))
        #expect(downloadedURL.lastPathComponent.hasSuffix("ETOS-Snapshot-a.elsbackup"))
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
                break
            default:
                Issue.record("错误类型不符合预期：\(error.localizedDescription)")
            }
        }
    }
}

private final class UploadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [SyncPackageUploadProgress] = []

    var events: [SyncPackageUploadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func append(_ progress: SyncPackageUploadProgress) {
        lock.lock()
        recordedEvents.append(progress)
        lock.unlock()
    }
}

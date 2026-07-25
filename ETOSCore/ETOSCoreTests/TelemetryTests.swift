// ============================================================================
// TelemetryTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖遥测信封、独立队列、保留策略、上传确认和固定 Signpost 分桶。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("性能遥测", .serialized)
struct TelemetryTests {
    private let app = TelemetryAppMetadata(
        version: "9.9.9",
        build: "999",
        distribution: .testflight
    )
    private let platform = TelemetryPlatformMetadata(
        name: "ios",
        osVersion: "26.0",
        deviceClass: "iPhone99,1",
        architecture: "arm64"
    )

    @Test("规范化 JSON 生成稳定 payload ID")
    func canonicalPayloadHashIsStable() throws {
        let first = try TelemetryEnvelopeCodec.makeEnvelope(
            kind: .metric,
            rawPayloadData: Data(#"{"b":2,"a":1}"#.utf8),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let second = try TelemetryEnvelopeCodec.makeEnvelope(
            kind: .metric,
            rawPayloadData: Data(#"{"a":1,"b":2}"#.utf8),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )

        #expect(first.payloadID == second.payloadID)
        #expect(first.payloadID.count == 64)
        #expect(first.privacy.isSafeForUpload)
    }

    @Test("信封编码使用稳定字段并保留未知 MetricKit 内容")
    func envelopeRoundTripPreservesPayload() throws {
        let envelope = try makeEnvelope(
            kind: .diagnostic,
            marker: "hang",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let data = try TelemetryEnvelopeCodec.encode(envelope)
        let text = String(decoding: data, as: UTF8.self)
        let decoded = try TelemetryEnvelopeCodec.decode(data)

        #expect(text.contains(#""schema_version":1"#))
        #expect(text.contains(#""contains_chat_content":false"#))
        #expect(text.contains(#""marker":"hang""#))
        #expect(decoded == envelope)
    }

    @Test("非对象 JSON 不会进入遥测队列")
    func nonObjectPayloadIsRejected() {
        #expect(throws: TelemetryEnvelopeError.self) {
            _ = try TelemetryEnvelopeCodec.makeEnvelope(
                kind: .metric,
                rawPayloadData: Data(#"["not-an-object"]"#.utf8),
                periodStart: nil,
                periodEnd: nil,
                app: app,
                platform: platform
            )
        }
    }

    @Test("启动快照冻结后不会包含本次启动新回调")
    func launchSnapshotIsFrozen() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-snapshot")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture)
        let firstDate = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await store.save(
            kind: .metric,
            rawPayloadData: payloadData(marker: "previous"),
            capturedAt: firstDate,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let launchSnapshot = await store.prepareLaunchSnapshot(now: firstDate)

        _ = await store.save(
            kind: .diagnostic,
            rawPayloadData: payloadData(marker: "current"),
            capturedAt: firstDate.addingTimeInterval(1),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let currentSnapshot = await store.loadCurrentSnapshot(now: firstDate.addingTimeInterval(1))

        #expect(launchSnapshot.files.count == 1)
        #expect(launchSnapshot.files.first?.envelope.kind == .metric)
        #expect(currentSnapshot.files.count == 2)
    }

    @Test("相同 Payload 去重且确认删除只影响精确 ID")
    func storeDeduplicatesAndDeletesPrecisely() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-dedup")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = await store.save(
            kind: .metric,
            rawPayloadData: payloadData(marker: "same"),
            capturedAt: now,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let duplicate = await store.save(
            kind: .metric,
            rawPayloadData: payloadData(marker: "same"),
            capturedAt: now.addingTimeInterval(1),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let other = await store.save(
            kind: .diagnostic,
            rawPayloadData: payloadData(marker: "other"),
            capturedAt: now.addingTimeInterval(2),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )

        #expect(first?.url == duplicate?.url)
        #expect((await store.loadCurrentSnapshot(now: now.addingTimeInterval(2))).files.count == 2)

        if let firstID = first?.envelope.payloadID {
            await store.deleteConfirmed(payloadIDs: [firstID])
        }
        let remaining = await store.loadCurrentSnapshot(now: now.addingTimeInterval(2))
        #expect(remaining.files.map(\.envelope.payloadID) == [other?.envelope.payloadID].compactMap { $0 })
    }

    @Test("容量清理优先保留诊断调用栈")
    func quotaCleanupPrioritizesDiagnostics() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-quota")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(
            baseDirectory: fixture,
            retentionDays: 14,
            maxTotalBytes: 1_100
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await store.save(
            kind: .diagnostic,
            rawPayloadData: payloadData(marker: "diagnostic", padding: 220),
            capturedAt: now,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        _ = await store.save(
            kind: .metric,
            rawPayloadData: payloadData(marker: "metric", padding: 220),
            capturedAt: now.addingTimeInterval(1),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )

        let snapshot = await store.loadCurrentSnapshot(now: now.addingTimeInterval(1))
        #expect(snapshot.totalBytes <= 1_100)
        #expect(snapshot.files.contains { $0.envelope.kind == .diagnostic })
        #expect(snapshot.files.contains { $0.envelope.kind == .metric } == false)
    }

    @Test("过期遥测按捕获时间清理")
    func retentionUsesCapturedTime() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-retention")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture, retentionDays: 14)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = await store.save(
            kind: .metric,
            rawPayloadData: payloadData(marker: "old"),
            capturedAt: now.addingTimeInterval(-15 * 86_400),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        _ = await store.save(
            kind: .diagnostic,
            rawPayloadData: payloadData(marker: "recent"),
            capturedAt: now,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )

        let snapshot = await store.loadCurrentSnapshot(now: now)
        #expect(snapshot.files.count == 1)
        #expect(snapshot.files.first?.envelope.kind == .diagnostic)
    }

    @Test("上传器按 16 项分批并接受 accepted 与 duplicate")
    func uploaderBatchesAndConfirmsServerResults() async throws {
        TelemetryURLProtocol.reset()
        defer { TelemetryURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let uploader = TelemetryUploader(
            session: session,
            endpoint: URL(string: "https://feedback.example/v1/telemetry")!
        )
        let files = try (0..<17).map { index in
            try makeStoredFile(marker: "upload-\(index)", index: index)
        }

        let outcome = await uploader.upload(files)
        let requests = TelemetryURLProtocol.capturedRequests()

        #expect(outcome.errorDescription == nil)
        #expect(outcome.attemptedPayloadIDs.count == 17)
        #expect(outcome.confirmedPayloadIDs.count == 17)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/v1/telemetry" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Content-Encoding") == nil })
    }

    @Test("Signpost 名称由固定枚举和 Markdown 大小分桶决定")
    func signpostBucketsAreStable() {
        #expect(TelemetrySignpost.markdownInterval(characterCount: 0) == .markdownPrepareEmpty)
        #expect(TelemetrySignpost.markdownInterval(characterCount: 1_000) == .markdownPrepareUnder1K)
        #expect(TelemetrySignpost.markdownInterval(characterCount: 1_001) == .markdownPrepareUnder10K)
        #expect(TelemetrySignpost.markdownInterval(characterCount: 100_001) == .markdownPrepareOver100K)
        #expect(TelemetrySignpost.requestInterval(streaming: true) == .modelRequestStreaming)
        #expect(TelemetrySignpost.requestInterval(streaming: false) == .modelRequestStandard)
    }

    private func makeEnvelope(
        kind: TelemetryPayloadKind,
        marker: String,
        capturedAt: Date
    ) throws -> TelemetryEnvelope {
        try TelemetryEnvelopeCodec.makeEnvelope(
            kind: kind,
            rawPayloadData: payloadData(marker: marker),
            capturedAt: capturedAt,
            periodStart: capturedAt.addingTimeInterval(-60),
            periodEnd: capturedAt,
            app: app,
            platform: platform
        )
    }

    private func makeStoredFile(marker: String, index: Int) throws -> TelemetryStoredFile {
        let envelope = try makeEnvelope(
            kind: index.isMultiple(of: 2) ? .metric : .diagnostic,
            marker: marker,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
        )
        let data = try TelemetryEnvelopeCodec.encode(envelope)
        return TelemetryStoredFile(
            url: URL(fileURLWithPath: "/fixture/\(envelope.payloadID).json"),
            relativePath: "2027-01-15/\(envelope.payloadID).json",
            envelope: envelope,
            data: data,
            fileSizeBytes: Int64(data.count)
        )
    }

    private func payloadData(marker: String, padding: Int = 0) -> Data {
        let value: [String: Any] = [
            "marker": marker,
            "padding": String(repeating: "x", count: padding),
            "histogram": ["bucket": 3]
        ]
        return try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class TelemetryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        requests = []
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

        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let envelopes = root?["envelopes"] as? [[String: Any]] ?? []
        let results: [[String: Any]] = envelopes.enumerated().compactMap { index, envelope in
            guard let payloadID = envelope["payload_id"] as? String else { return nil }
            return [
                "payload_id": payloadID,
                "status": index.isMultiple(of: 2) ? "accepted" : "duplicate"
            ]
        }
        let responseBody = try! JSONSerialization.data(
            withJSONObject: [
                "schema_version": 1,
                "results": results
            ],
            options: [.sortedKeys]
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

// ============================================================================
// TelemetryTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖遥测信封、独立队列、保留策略、上传确认和固定 Signpost 分桶。
// ============================================================================

import Foundation
import CryptoKit
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

    @Test("崩溃异常自由文本在哈希与落盘前移除")
    func crashExceptionReasonFreeTextIsRemoved() throws {
        let rawPayload = Data(
            #"""
            {
              "crashDiagnostics": [
                {
                  "callStackTree": {
                    "callStacks": [
                      {
                        "callStackRootFrames": [
                          {
                            "binaryName": "ETOS LLM Studio",
                            "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743",
                            "offsetIntoBinaryTextSegment": 4096
                          }
                        ]
                      }
                    ]
                  },
                  "exceptionReason": {
                    "arguments": ["用户聊天原文", "sk-secret"],
                    "className": "NSException",
                    "composedMessage": "请求 https://private.example 失败：用户聊天原文",
                    "exceptionType": "NSInvalidArgumentException",
                    "formatString": "请求 %@ 失败：%@",
                    "futureFreeText": "未来系统新增的自由文本"
                  },
                  "unknownDiagnosticField": {
                    "value": 7
                  }
                }
              ]
            }
            """#.utf8
        )

        let envelope = try TelemetryEnvelopeCodec.makeEnvelope(
            kind: .diagnostic,
            rawPayloadData: rawPayload,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let encoded = String(decoding: try TelemetryEnvelopeCodec.encode(envelope), as: UTF8.self)

        #expect(encoded.contains("用户聊天原文") == false)
        #expect(encoded.contains("sk-secret") == false)
        #expect(encoded.contains("private.example") == false)
        #expect(encoded.contains("composedMessage") == false)
        #expect(encoded.contains("formatString") == false)
        #expect(encoded.contains("arguments") == false)
        #expect(encoded.contains("futureFreeText") == false)
        #expect(encoded.contains(#""className":"NSException""#))
        #expect(encoded.contains(#""exceptionType":"NSInvalidArgumentException""#))
        #expect(encoded.contains(#""binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743""#))
        #expect(encoded.contains(#""unknownDiagnosticField":{"value":7}"#))

        let canonical = try TelemetryEnvelopeCodec.canonicalPayloadData(envelope.payload)
        let expectedID = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(envelope.payloadID == expectedID)
    }

    @Test("无法识别的异常说明结构整块丢弃")
    func malformedExceptionReasonIsRemoved() throws {
        let envelope = try TelemetryEnvelopeCodec.makeEnvelope(
            kind: .diagnostic,
            rawPayloadData: Data(
                #"{"crashDiagnostics":[{"exceptionReason":"用户聊天原文","signal":6}]}"#.utf8
            ),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let encoded = String(decoding: try TelemetryEnvelopeCodec.encode(envelope), as: UTF8.self)

        #expect(encoded.contains("exceptionReason") == false)
        #expect(encoded.contains("用户聊天原文") == false)
        #expect(encoded.contains(#""signal":6"#))
    }

    @Test("深层诊断调用栈会在编码前安全裁剪")
    func deeplyNestedDiagnosticIsTruncatedBeforeEncoding() throws {
        var nestedFrame = #"{"binaryName":"deepest-frame"}"#
        for index in 0..<400 {
            nestedFrame = #"{"binaryName":"frame-\#(index)","subFrames":[\#(nestedFrame)]}"#
        }
        let rawPayload = Data(
            #"{"crashDiagnostics":[{"callStackTree":{"callStacks":[{"callStackRootFrames":[\#(nestedFrame)]}]}}]}"#.utf8
        )

        let envelope = try TelemetryEnvelopeCodec.makeEnvelope(
            kind: .diagnostic,
            rawPayloadData: rawPayload,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let encoded = try TelemetryEnvelopeCodec.encode(envelope)
        let text = String(decoding: encoded, as: UTF8.self)
        let decoded = try TelemetryEnvelopeCodec.decode(encoded)

        #expect(text.contains("frame-399"))
        #expect(text.contains("deepest-frame") == false)
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

    @Test("损坏或不兼容的遥测文件会立即清理")
    func storeRemovesInvalidFiles() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-invalid")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture)
        let pendingDirectory = fixture
            .appendingPathComponent("Pending", isDirectory: true)
            .appendingPathComponent("2026-07-27", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pendingDirectory,
            withIntermediateDirectories: true
        )

        let corruptURL = pendingDirectory.appendingPathComponent(
            "metric_corrupt.json",
            isDirectory: false
        )
        try Data("{not-json".utf8).write(to: corruptURL)

        let envelope = try makeEnvelope(
            kind: .metric,
            marker: "incompatible",
            capturedAt: Date()
        )
        let encodedEnvelope = try TelemetryEnvelopeCodec.encode(envelope)
        var incompatibleObject = try #require(
            JSONSerialization.jsonObject(with: encodedEnvelope) as? [String: Any]
        )
        incompatibleObject["schema_version"] = 999
        let incompatibleData = try JSONSerialization.data(
            withJSONObject: incompatibleObject,
            options: [.sortedKeys]
        )
        let incompatibleURL = pendingDirectory.appendingPathComponent(
            "metric_\(envelope.payloadID).json",
            isDirectory: false
        )
        try incompatibleData.write(to: incompatibleURL)

        let snapshot = await store.loadCurrentSnapshot()

        #expect(snapshot.files.isEmpty)
        #expect(snapshot.totalBytes == 0)
        #expect(FileManager.default.fileExists(atPath: corruptURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: incompatibleURL.path) == false)
    }

    @Test("同 ID 无效文件不会阻止新遥测落盘")
    func invalidDuplicateFileDoesNotBlockSave() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-invalid-duplicate")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture)
        let capturedAt = Date()
        let rawPayload = payloadData(marker: "replacement")
        let envelope = try TelemetryEnvelopeCodec.makeEnvelope(
            kind: .metric,
            rawPayloadData: rawPayload,
            capturedAt: capturedAt,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let pendingDirectory = fixture
            .appendingPathComponent("Pending", isDirectory: true)
            .appendingPathComponent("2026-07-27", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pendingDirectory,
            withIntermediateDirectories: true
        )
        let invalidURL = pendingDirectory.appendingPathComponent(
            "metric_\(envelope.payloadID).json",
            isDirectory: false
        )
        try Data("{not-json".utf8).write(to: invalidURL)

        let saved = await store.save(
            kind: .metric,
            rawPayloadData: rawPayload,
            capturedAt: capturedAt,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let snapshot = await store.loadCurrentSnapshot()

        #expect(saved?.envelope.payloadID == envelope.payloadID)
        #expect(snapshot.files.count == 1)
        #expect(snapshot.files.first?.rawJSON.contains("replacement") == true)
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

    @Test("上传器只进行一次受限重试并在恢复后确认")
    func uploaderRetriesTransientFailureOnce() async throws {
        TelemetryURLProtocol.reset()
        TelemetryURLProtocol.failNextRequests(1)
        defer { TelemetryURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryURLProtocol.self]
        let uploader = TelemetryUploader(
            session: URLSession(configuration: configuration),
            endpoint: URL(string: "https://feedback.example/v1/telemetry")!,
            maxAttempts: 2,
            retryDelayNanoseconds: 0
        )
        let file = try makeStoredFile(marker: "retry", index: 0)

        let outcome = await uploader.upload([file])

        #expect(outcome.errorDescription == nil)
        #expect(outcome.confirmedPayloadIDs == [file.envelope.payloadID])
        #expect(TelemetryURLProtocol.capturedRequests().count == 2)
    }

    @Test("响应确认不完整时只确认明确成功项")
    func uploaderKeepsUnconfirmedPayloads() async throws {
        TelemetryURLProtocol.reset()
        TelemetryURLProtocol.omitLastResultFromResponses()
        defer { TelemetryURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryURLProtocol.self]
        let uploader = TelemetryUploader(
            session: URLSession(configuration: configuration),
            endpoint: URL(string: "https://feedback.example/v1/telemetry")!,
            maxAttempts: 2,
            retryDelayNanoseconds: 0
        )
        let files = try [
            makeStoredFile(marker: "confirmed", index: 0),
            makeStoredFile(marker: "unconfirmed", index: 1)
        ]

        let outcome = await uploader.upload(files)

        #expect(outcome.confirmedPayloadIDs == [files[0].envelope.payloadID])
        #expect(outcome.attemptedPayloadIDs.count == 2)
        #expect(outcome.errorDescription != nil)
        #expect(TelemetryURLProtocol.capturedRequests().count == 2)
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

    #if os(iOS) && canImport(MetricKit)
    @Test("数据库等待手动解锁时不会读取或启用遥测偏好")
    @MainActor
    func lockedDatabaseSuppressesLaunchTelemetryPreference() {
        var didReadConfiguredValue = false
        let enabledWhileLocked = PerformanceTelemetryCenter.resolveLaunchEnabled(
            requiresManualUnlock: true
        ) {
            didReadConfiguredValue = true
            return true
        }

        #expect(enabledWhileLocked == false)
        #expect(didReadConfiguredValue == false)
        #expect(PerformanceTelemetryCenter.resolveLaunchEnabled(
            requiresManualUnlock: false
        ) {
            true
        })
        #expect(PerformanceTelemetryCenter.resolveLaunchEnabled(
            requiresManualUnlock: false
        ) {
            false
        } == false)
    }

    @Test("首次界面就绪后配置遥测不会重新创建启动区间")
    @MainActor
    func configuringTelemetryAfterFirstInterfaceDoesNotRestartLaunchMeasurement() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-launch-signpost")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let center = PerformanceTelemetryCenter(
            store: TelemetryStore(baseDirectory: fixture),
            uploader: RecordingTelemetryUploader(),
            appMetadata: app,
            platformMetadata: platform,
            uploadDelayNanoseconds: 60_000_000_000,
            subscribesToMetricKit: false
        )

        center.prepareLaunchMeasurement(enabled: true)
        #expect(center.hasActiveLaunchMeasurement)
        center.markFirstInterfaceReady()
        #expect(center.hasActiveLaunchMeasurement == false)

        await center.configure(enabled: true)
        #expect(center.hasActiveLaunchMeasurement == false)

        await center.configure(enabled: false)
    }

    @Test("清除待发送数据会取消尚未开始的启动上传")
    @MainActor
    func clearingPendingDataCancelsDelayedUpload() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-clear-delayed")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture)
        let uploader = RecordingTelemetryUploader()
        let now = Date()
        _ = await store.save(
            kind: .metric,
            rawPayloadData: payloadData(marker: "delayed"),
            capturedAt: now,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let center = PerformanceTelemetryCenter(
            store: store,
            uploader: uploader,
            appMetadata: app,
            platformMetadata: platform,
            uploadDelayNanoseconds: 60_000_000_000,
            subscribesToMetricKit: false
        )

        await center.configure(enabled: true)
        await center.clearPendingData()
        for _ in 0..<10 {
            await Task.yield()
        }

        let uploadCount = await uploader.uploadCount()
        let snapshot = await store.loadCurrentSnapshot()
        #expect(uploadCount == 0)
        #expect(snapshot.files.isEmpty)
        #expect(center.pendingRecords.isEmpty)
        #expect(center.pendingBytes == 0)

        _ = await store.save(
            kind: .metric,
            rawPayloadData: payloadData(marker: "after-clear"),
            capturedAt: now.addingTimeInterval(1),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        await center.refreshVisibleRecords()
        #expect(center.pendingRecords.count == 1)
        #expect(center.pendingRecords.first?.rawJSON.contains("after-clear") == true)

        await center.configure(enabled: false)
    }

    @Test("清除期间迟到的上传结果不会恢复记录或已发送状态")
    @MainActor
    func clearingPendingDataRejectsLateUploadResult() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-clear-in-flight")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture)
        let uploader = SuspendedTelemetryUploader()
        let now = Date()
        _ = await store.save(
            kind: .diagnostic,
            rawPayloadData: payloadData(marker: "in-flight"),
            capturedAt: now,
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let center = PerformanceTelemetryCenter(
            store: store,
            uploader: uploader,
            appMetadata: app,
            platformMetadata: platform,
            uploadDelayNanoseconds: 0,
            subscribesToMetricKit: false
        )

        await center.configure(enabled: true)
        var didStart = false
        for _ in 0..<100 {
            didStart = await uploader.hasStarted()
            if didStart { break }
            await Task.yield()
        }
        #expect(didStart)

        let clearTask = Task { @MainActor in
            await center.clearPendingData()
        }
        var clearDidBegin = false
        for _ in 0..<100 {
            if center.isUploading == false {
                clearDidBegin = true
                break
            }
            await Task.yield()
        }
        #expect(clearDidBegin)
        #expect(center.pendingRecords.isEmpty == false)

        await uploader.finish()
        await clearTask.value

        let snapshot = await store.loadCurrentSnapshot()
        #expect(snapshot.files.isEmpty)
        #expect(center.pendingRecords.isEmpty)
        #expect(center.sentThisLaunchRecords.isEmpty)
        #expect(center.pendingBytes == 0)
        #expect(center.lastUploadError == nil)
        #expect(center.isUploading == false)

        await center.configure(enabled: false)
    }

    @Test("关闭遥测会取消延迟上传并清空全部运行状态")
    @MainActor
    func disablingTelemetryCancelsDelayedUpload() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-disable-delayed")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture)
        let uploader = RecordingTelemetryUploader()
        _ = await store.save(
            kind: .metric,
            rawPayloadData: payloadData(marker: "disable"),
            capturedAt: Date(),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let center = PerformanceTelemetryCenter(
            store: store,
            uploader: uploader,
            appMetadata: app,
            platformMetadata: platform,
            uploadDelayNanoseconds: 60_000_000_000,
            subscribesToMetricKit: false
        )

        await center.configure(enabled: true)
        await center.configure(enabled: false)

        let uploadCount = await uploader.uploadCount()
        let snapshot = await store.loadCurrentSnapshot()
        #expect(uploadCount == 0)
        #expect(snapshot.files.isEmpty)
        #expect(center.isEnabled == false)
        #expect(center.pendingRecords.isEmpty)
        #expect(center.sentThisLaunchRecords.isEmpty)
        #expect(center.pendingBytes == 0)
        #expect(center.isUploading == false)
        #expect(center.lastUploadError == nil)
    }

    @Test("关闭尚未结束时重新开启会等待旧数据清理完成")
    @MainActor
    func reenablingTelemetryWaitsForDisableCleanup() async throws {
        let fixture = try makeTemporaryDirectory(prefix: "telemetry-disable-reenable")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let store = TelemetryStore(baseDirectory: fixture)
        let uploader = SuspendedTelemetryUploader()
        _ = await store.save(
            kind: .diagnostic,
            rawPayloadData: payloadData(marker: "before-disable"),
            capturedAt: Date(),
            periodStart: nil,
            periodEnd: nil,
            app: app,
            platform: platform
        )
        let center = PerformanceTelemetryCenter(
            store: store,
            uploader: uploader,
            appMetadata: app,
            platformMetadata: platform,
            uploadDelayNanoseconds: 0,
            subscribesToMetricKit: false
        )

        await center.configure(enabled: true)
        for _ in 0..<100 {
            if await uploader.hasStarted() { break }
            await Task.yield()
        }
        let uploadStarted = await uploader.hasStarted()
        #expect(uploadStarted)

        let disableTask = Task { @MainActor in
            await center.configure(enabled: false)
        }
        for _ in 0..<100 where center.isEnabled {
            await Task.yield()
        }
        #expect(center.isEnabled == false)

        let enableTask = Task { @MainActor in
            await center.configure(enabled: true)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(center.isEnabled == false)

        await uploader.finish()
        await disableTask.value
        await enableTask.value

        let snapshot = await store.loadCurrentSnapshot()
        #expect(center.isEnabled)
        #expect(snapshot.files.isEmpty)
        #expect(center.pendingRecords.isEmpty)
        #expect(center.sentThisLaunchRecords.isEmpty)
        let uploadCount = await uploader.uploadCount()
        #expect(uploadCount == 1)

        await center.configure(enabled: false)
    }
    #endif

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
            rawJSON: String(decoding: data, as: UTF8.self),
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

#if os(iOS) && canImport(MetricKit)
private actor RecordingTelemetryUploader: TelemetryUploading {
    private var count = 0

    func upload(_ files: [TelemetryStoredFile]) async -> TelemetryUploadOutcome {
        count += 1
        let payloadIDs = Set(files.map(\.envelope.payloadID))
        return TelemetryUploadOutcome(
            confirmedPayloadIDs: payloadIDs,
            attemptedPayloadIDs: payloadIDs,
            errorDescription: nil
        )
    }

    func uploadCount() -> Int {
        count
    }
}

private actor SuspendedTelemetryUploader: TelemetryUploading {
    private var continuation: CheckedContinuation<Void, Never>?
    private var payloadIDs: Set<String> = []
    private var started = false
    private var count = 0

    func upload(_ files: [TelemetryStoredFile]) async -> TelemetryUploadOutcome {
        count += 1
        payloadIDs = Set(files.map(\.envelope.payloadID))
        started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return TelemetryUploadOutcome(
            confirmedPayloadIDs: payloadIDs,
            attemptedPayloadIDs: payloadIDs,
            errorDescription: "迟到的上传结果不应写回界面"
        )
    }

    func hasStarted() -> Bool {
        started
    }

    func uploadCount() -> Int {
        count
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
#endif

private final class TelemetryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private nonisolated(unsafe) static var remainingFailures = 0
    private nonisolated(unsafe) static var omitLastResult = false

    static func reset() {
        lock.lock()
        requests = []
        remainingFailures = 0
        omitLastResult = false
        lock.unlock()
    }

    static func failNextRequests(_ count: Int) {
        lock.lock()
        remainingFailures = max(0, count)
        lock.unlock()
    }

    static func omitLastResultFromResponses() {
        lock.lock()
        omitLastResult = true
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
        let shouldFail = Self.remainingFailures > 0
        if shouldFail {
            Self.remainingFailures -= 1
        }
        let shouldOmitLastResult = Self.omitLastResult
        Self.lock.unlock()

        if shouldFail {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"temporary"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let envelopes = root?["envelopes"] as? [[String: Any]] ?? []
        var results: [[String: Any]] = envelopes.enumerated().compactMap { index, envelope in
            guard let payloadID = envelope["payload_id"] as? String else { return nil }
            return [
                "payload_id": payloadID,
                "status": index.isMultiple(of: 2) ? "accepted" : "duplicate"
            ]
        }
        if shouldOmitLastResult, !results.isEmpty {
            results.removeLast()
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

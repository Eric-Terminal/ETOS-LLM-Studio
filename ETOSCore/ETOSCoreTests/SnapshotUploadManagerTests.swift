import Combine
import Foundation
import SwiftUI
import Testing
@testable import ETOSCore

@Suite("云备份跨页面任务")
@MainActor
struct SnapshotUploadManagerTests {
    private let configuration = S3CompatibleUploadConfiguration(
        endpoint: URL(string: "https://example.com")!,
        region: "auto", bucket: "backups", accessKeyID: "test-key", secretAccessKey: "test-secret"
    )

    @Test("页面停止观察后上传继续，返回仍可读取进度与成功结果")
    func uploadOutlivesPageObservation() async throws {
        let probe = UploadProbe()
        let notifications = Notifications()
        let manager = SnapshotUploadManager(
            operation: { request, progress in
                #expect(!Thread.isMainThread)
                return try await probe.run(request, progress: progress)
            },
            notify: { id, succeeded in notifications.events.append((id, succeeded)) }
        )
        var observation: AnyCancellable? = manager.$state.sink { _ in }
        #expect(manager.start(kind: .full, password: "password", useStrongDerivation: true, configuration: configuration))
        #expect(manager.state == .preparing)
        #expect(!manager.start(kind: .database, password: nil, useStrongDerivation: false, configuration: configuration))
        await probe.waitUntilStarted()

        // 模拟页面销毁观察订阅及页面任务；二者都不得拥有上传的取消权。
        observation?.cancel()
        observation = nil
        let pageTask = Task { await manager.waitForCompletion() }
        pageTask.cancel()
        let progress = SyncPackageUploadProgress(bytesSent: 42, totalBytes: 100)
        await probe.report(progress)
        _ = await manager.$state.values.first { $0 == .uploading(progress) }
        #expect(manager.progress == progress)
        #expect(manager.isUploading)
        manager.clearResult()
        #expect(manager.isUploading)

        let request = try #require(await probe.request)
        #expect(request.kind == .full)
        #expect(request.password == "password")
        #expect(request.useStrongDerivation)
        #expect(request.configuration == configuration)
        await probe.complete(.success(SyncPackageUploadResult(statusCode: 201, responseBodyPreview: nil)))
        await manager.waitForCompletion()
        await pageTask.value
        #expect(manager.state == .succeeded(201, nil))
        #expect(!manager.isUploading)
        #expect(manager.errorMessage == nil)
        #expect(notifications.events.count == 1)
        #expect(notifications.events.first?.1 == true)
    }

    @Test("上传失败保留错误并通知，重试成功后清除旧错误")
    func failureAllowsRetry() async throws {
        let probe = UploadProbe()
        let notifications = Notifications()
        let manager = SnapshotUploadManager(
            operation: { request, progress in try await probe.run(request, progress: progress) },
            notify: { id, succeeded in notifications.events.append((id, succeeded)) }
        )
        #expect(manager.start(kind: .database, password: nil, useStrongDerivation: false, configuration: configuration))
        await probe.waitUntilStarted()
        await probe.complete(.failure(UploadFailure.rejected))
        await manager.waitForCompletion()
        #expect(manager.errorMessage == UploadFailure.rejected.localizedDescription)
        #expect(manager.progress == nil)
        #expect(notifications.events.count == 1)
        #expect(notifications.events.first?.1 == false)

        #expect(manager.start(kind: .database, password: nil, useStrongDerivation: false, configuration: configuration))
        #expect(manager.errorMessage == nil)
        await probe.waitUntilStarted()
        await probe.complete(.success(SyncPackageUploadResult(statusCode: 200, responseBodyPreview: nil)))
        await manager.waitForCompletion()
        #expect(manager.state == .succeeded(200, nil))
        #expect(notifications.events.count == 2)
        #expect(notifications.events.last?.1 == true)
        #expect(notifications.events.first?.0 != notifications.events.last?.0)
        manager.clearResult()
        #expect(manager.state == .idle)
    }

    @Test("备份向导有专属文档且密码与对象存储凭据只写不可读")
    func guideProtectsSecrets() async throws {
        let service = GuideKnowledgeService()
        let documents = await service.search("云备份", limit: 1)
        #expect(documents.first?.id == "snapshot-backup")
        let settings = SnapshotBackupGuideSupport.draftSettings(
            kind: .constant(.database), encrypted: .constant(true), strongDerivation: .constant(false),
            password: .constant("private-password"), confirmation: .constant("private-password")
        )
        let snapshot = GuideDeclarativeSettingsSupport.snapshot(settings: settings)
        for key in ["password", "password_confirmation"] {
            #expect(snapshot.fields[key]?.access == .writeOnly)
            #expect(snapshot.fields[key]?.value == .string(GuideSnapshotField.hiddenValue))
        }
        #expect(snapshot.fields["upload_state"]?.access == .readOnly)
        #expect(snapshot.fields["requires_manual_action"]?.value == .bool(true))
        let storage = GuideDeclarativeSettingsSupport.snapshot(settings: SnapshotBackupGuideSupport.storageSettings)
        for key in ["access_key_id", "secret_access_key", "session_token"] {
            #expect(storage.fields[key]?.access == .writeOnly)
            #expect(storage.fields[key]?.value == .string(GuideSnapshotField.hiddenValue))
        }
    }
}

@MainActor
private final class Notifications {
    var events: [(UUID, Bool)] = []
}

private enum UploadFailure: LocalizedError {
    case rejected
    var errorDescription: String? { "测试上传失败" }
}

/// 用显式续体控制网络完成时机，避免测试依赖睡眠或真实对象存储。
private actor UploadProbe {
    private(set) var request: SnapshotUploadManager.Request?
    private var progress: SyncPackageUploadService.ProgressHandler?
    private var completion: CheckedContinuation<SyncPackageUploadResult, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func run(
        _ request: SnapshotUploadManager.Request,
        progress: @escaping SyncPackageUploadService.ProgressHandler
    ) async throws -> SyncPackageUploadResult {
        self.request = request
        self.progress = progress
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        guard completion == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func report(_ value: SyncPackageUploadProgress) {
        progress?(value)
    }

    func complete(_ result: Result<SyncPackageUploadResult, Error>) {
        let pending = completion
        completion = nil
        pending?.resume(with: result)
    }
}

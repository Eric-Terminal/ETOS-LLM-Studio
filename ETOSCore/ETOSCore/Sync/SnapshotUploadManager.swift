import Foundation
import Combine

/// 上传属于应用生命周期，页面只观察状态；返回上级不会取消任务或删除正在上传的文件。
@MainActor
public final class SnapshotUploadManager: ObservableObject {
    public static let shared = SnapshotUploadManager()

    public enum State: Equatable, Sendable {
        case idle
        case preparing
        case uploading(SyncPackageUploadProgress)
        case succeeded(Int, String?)
        case failed(String)
    }

    struct Request: Sendable {
        let kind: SnapshotBuilder.BackupKind
        let password: String?
        let useStrongDerivation: Bool
        let configuration: S3CompatibleUploadConfiguration
    }

    typealias Operation = @Sendable (Request, @escaping SyncPackageUploadService.ProgressHandler) async throws -> SyncPackageUploadResult
    typealias Notifier = @MainActor @Sendable (UUID, Bool) async -> Void

    @Published public private(set) var state: State = .idle
    private var activeID: UUID?
    private var task: Task<Void, Never>?
    private let operation: Operation
    private let notify: Notifier

    init(
        operation: @escaping Operation = { request, progress in
            try await SnapshotUploadManager.upload(request, progress: progress)
        },
        notify: @escaping Notifier = { id, succeeded in
            #if canImport(UserNotifications)
            await AppLocalNotificationCenter.shared.postSnapshotUploadFinishedNotification(
                operationID: id, succeeded: succeeded
            )
            #endif
        }
    ) {
        self.operation = operation
        self.notify = notify
    }

    public var isUploading: Bool {
        switch state {
        case .preparing, .uploading: return true
        default: return false
        }
    }

    public var progress: SyncPackageUploadProgress? {
        guard case .uploading(let progress) = state else { return nil }
        return progress
    }

    public var statusMessage: String? {
        switch state {
        case .preparing:
            return NSLocalizedString("正在准备上传快照…", comment: "云备份准备状态")
        case .succeeded(let statusCode, let preview):
            if let preview, !preview.isEmpty {
                return String(format: NSLocalizedString("快照已上传（HTTP %d）：%@", comment: ""), statusCode, preview)
            }
            return String(format: NSLocalizedString("快照已上传（HTTP %d）。", comment: ""), statusCode)
        default:
            return nil
        }
    }

    public var errorMessage: String? {
        guard case .failed(let message) = state else { return nil }
        return message
    }

    @discardableResult
    public func start(
        kind: SnapshotBuilder.BackupKind,
        password: String?,
        useStrongDerivation: Bool,
        configuration: S3CompatibleUploadConfiguration
    ) -> Bool {
        guard !isUploading else { return false }
        let id = UUID()
        let request = Request(kind: kind, password: password, useStrongDerivation: useStrongDerivation, configuration: configuration)
        let operation = operation
        activeID = id
        state = .preparing
        // 在点击时捕获配置和密码；之后页面重建或编辑配置都不会改变本次上传。
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: State
            do {
                let result = try await operation(request) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeID == id else { return }
                        self.state = .uploading(progress)
                    }
                }
                outcome = .succeeded(result.statusCode, result.responseBodyPreview)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            await self?.finish(id: id, outcome: outcome)
        }
        return true
    }

    /// 只清除已结束的结果，本地导出或恢复开始时不会影响仍在执行的上传。
    public func clearResult() {
        guard !isUploading else { return }
        state = .idle
    }

    func waitForCompletion() async {
        await task?.value
    }

    private func finish(id: UUID, outcome: State) async {
        guard activeID == id else { return }
        activeID = nil
        state = outcome
        let succeeded: Bool
        if case .succeeded = outcome { succeeded = true } else { succeeded = false }
        await notify(id, succeeded)
    }

    nonisolated private static func upload(
        _ request: Request,
        progress: @escaping SyncPackageUploadService.ProgressHandler
    ) async throws -> SyncPackageUploadResult {
        let diagnostics = SnapshotDiagnostics()
        diagnostics.record("operation.begin", details: [
            "kind": request.kind.rawValue, "destination": "s3", "encrypted": String(request.password != nil)
        ])
        do {
            diagnostics.record("writes.flush.begin")
            await AppConfigStore.shared.flushPendingWrites()
            await Persistence.flushPendingMessageWritesForSyncSnapshotAsync()
            MemoryManager.flushCurrentInstancePersistenceWritesForSnapshot()
            let fileURL = try SnapshotBuilder.buildSnapshot(kind: request.kind, diagnostics: diagnostics)
            // 文件由任务持有，覆盖加密、网络失败和成功三条退出路径。
            defer { try? FileManager.default.removeItem(at: fileURL) }
            if let password = request.password {
                diagnostics.record("encryption.begin", fileURL: fileURL)
                let data = try Data(contentsOf: fileURL)
                let encrypted = try request.useStrongDerivation
                    ? SnapshotEncryptor.encryptStrongPassword(data: data, password: password)
                    : SnapshotEncryptor.encryptSimplePassword(data: data, password: password)
                try encrypted.write(to: fileURL, options: .atomic)
                diagnostics.record("encryption.completed", fileURL: fileURL)
            }
            let result = try await SyncPackageUploadService.uploadSnapshot(
                fileURL: fileURL, s3: request.configuration, progress: progress, diagnostics: diagnostics
            )
            diagnostics.record("operation.completed")
            return result
        } catch {
            diagnostics.recordFailure(error)
            throw error
        }
    }
}

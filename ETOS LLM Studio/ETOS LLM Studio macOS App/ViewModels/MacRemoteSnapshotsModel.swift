import Combine
import ETOSCore
import Foundation

@MainActor
final class MacRemoteSnapshotsModel: ObservableObject {
    struct Row: Identifiable {
        let snapshot: S3CompatibleRemoteSnapshot
        let sizeAndDate: String
        var id: String { snapshot.id }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    func load(_ configuration: S3CompatibleUploadConfiguration) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let snapshots = try await SyncPackageUploadService.listRemoteSnapshots(s3: configuration)
            let rows = await Task.detached(priority: .userInitiated) {
                snapshots.map { snapshot in
                    let size = snapshot.byteSize.map { StorageUtility.formatSize($0) }
                    let date = snapshot.lastModified.map { $0.formatted(date: .abbreviated, time: .shortened) }
                    return Row(snapshot: snapshot, sizeAndDate: [size, date].compactMap { $0 }.joined(separator: " · "))
                }
            }.value
            try Task.checkCancellation()
            self.rows = rows
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

@MainActor
final class MacRemoteSnapshotDownloadModel: ObservableObject {
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: SyncPackageDownloadProgress?
    @Published private(set) var error: String?
    @Published var incoming: MacSnapshotFile?
    private var task: Task<Void, Never>?
    private var operationID = UUID()

    func download(_ snapshot: S3CompatibleRemoteSnapshot, configuration: S3CompatibleUploadConfiguration) {
        guard !isDownloading else { return }
        let id = UUID()
        operationID = id
        isDownloading = true
        progress = nil
        error = nil
        task = Task { [weak self] in
            do {
                let url = try await SyncPackageUploadService.downloadRemoteSnapshot(objectKey: snapshot.key, s3: configuration, progress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationID == id, self.isDownloading else { return }
                        self.progress = progress
                    }
                })
                guard let self, !Task.isCancelled, self.operationID == id else {
                    await Task.detached { try? FileManager.default.removeItem(at: url) }.value
                    return
                }
                incoming = MacSnapshotFile(url: url, removesOnDismiss: true)
            } catch {
                if !Task.isCancelled, self?.operationID == id { self?.error = error.localizedDescription }
            }
            if self?.operationID == id { self?.isDownloading = false }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        operationID = UUID()
        isDownloading = false
    }

    deinit { task?.cancel() }
}

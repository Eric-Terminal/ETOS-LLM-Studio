import Foundation

@MainActor
final class WatchDatabaseSyncIsolation {
    private let cloud: CloudSyncManager
    private(set) var operationID: UUID?
    private var holders = 0

    init(cloud: CloudSyncManager = .shared) {
        self.cloud = cloud
    }

    func begin(_ id: UUID) -> Bool {
        if let operationID {
            guard operationID == id else { return false }
        } else {
            guard cloud.beginLocalDataRestore() else { return false }
        }
        operationID = id
        holders += 1
        return true
    }

    func prepare() async throws {
        await AppConfigStore.shared.flushPendingWrites()
        // 按库裁决生成了新数据组合，旧发布基线不能再用于自动采用云端世代。
        // 即使传输失败，也应重新核对云端，不能假定另一端完全没有安装归档。
        await cloud.savePublishedState(CloudSyncPublishedState())
        try await cloud.safetyBackupCreator()
    }

    func finish(_ id: UUID) {
        guard operationID == id else { return }
        // 对端回执可能在本机安装期间到达；发送与安装分别持有隔离，不能提前放行云同步。
        holders -= 1
        guard holders == 0 else { return }
        operationID = nil
        cloud.endLocalDataRestore(didRestore: true)
    }
}

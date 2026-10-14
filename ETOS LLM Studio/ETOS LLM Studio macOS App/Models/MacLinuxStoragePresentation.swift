import ETOSCore
import Foundation

struct MacLinuxWorkspaceRow: Identifiable, Sendable {
    let workspace: LocalAgentWorkspace
    let title: String
    let size: String
    let activeJobCount: Int
    var id: UUID { workspace.id }

    init(_ workspace: LocalAgentWorkspace, activeJobCount: Int) {
        self.workspace = workspace; self.activeJobCount = activeJobCount
        if let sessionID = workspace.sessionID {
            title = String(format: NSLocalizedString("会话 %@", comment: ""), String(sessionID.uuidString.prefix(8)))
        } else if let profileID = workspace.profileID {
            title = String(format: NSLocalizedString("本地 MCP %@", comment: ""), String(profileID.uuidString.prefix(8)))
        } else if workspace.id == LocalLinuxStorageManager.interactiveUserWorkspaceID {
            title = NSLocalizedString("用户终端", comment: "")
        } else { title = NSLocalizedString("独立工作区", comment: "") }
        size = ByteCountFormatter.string(fromByteCount: Int64(clamping: workspace.sizeBytes), countStyle: .file)
    }
}

struct MacLinuxMountRow: Identifiable, Sendable {
    let record: LocalLinuxMountRecord
    let access: String
    let authorization: String
    let usage: String
    var id: UUID { record.id }

    init(_ record: LocalLinuxMountRecord) {
        self.record = record
        access = record.access.displayName; authorization = record.authorizationState.displayName
        usage = String(format: NSLocalizedString("%lld 个任务正在使用", comment: ""), Int64(clamping: record.activeLeaseCount))
    }
}

struct MacLinuxStorageCatalog: Sendable {
    let workspaces: [MacLinuxWorkspaceRow]
    let mounts: [MacLinuxMountRow]
    let workspaceByID: [UUID: MacLinuxWorkspaceRow]
    let mountByID: [UUID: MacLinuxMountRow]
    let guideWorkspaces: JSONValue
    let guideMounts: JSONValue

    static func prepare(workspaces: [LocalAgentWorkspace], mounts: [LocalLinuxMountRecord], jobs: [LocalLinuxJob]) -> Self {
        let counts = Dictionary(grouping: jobs.filter { !$0.state.isTerminal }, by: \.workspaceID).mapValues(\.count)
        let workspaceRows = workspaces.map { MacLinuxWorkspaceRow($0, activeJobCount: counts[$0.id] ?? 0) }
        let mountRows = mounts.map(MacLinuxMountRow.init)
        return Self(workspaces: workspaceRows, mounts: mountRows,
            workspaceByID: Dictionary(uniqueKeysWithValues: workspaceRows.map { ($0.id, $0) }),
            mountByID: Dictionary(uniqueKeysWithValues: mountRows.map { ($0.id, $0) }),
            guideWorkspaces: .array(workspaceRows.map { .dictionary([
                "id": .string($0.id.uuidString), "session_id": .string($0.workspace.sessionID?.uuidString ?? ""),
                "profile_id": .string($0.workspace.profileID?.uuidString ?? ""), "active_jobs": .int($0.activeJobCount)
            ]) }),
            guideMounts: .array(mountRows.map { .dictionary([
                "id": .string($0.id.uuidString), "access": .string($0.record.access.rawValue),
                "enabled": .bool($0.record.isEnabled), "authorization": .string($0.record.authorizationState.rawValue),
                "active_leases": .int(Int(clamping: $0.record.activeLeaseCount))
            ]) }))
    }
}

/// 确认的是记录身份及目录配置；后台统计和租约计数变化不应误判成另一个目录。
enum MacLinuxStorageIdentity {
    static func matches(_ current: LocalAgentWorkspace, _ expected: LocalAgentWorkspace) -> Bool {
        current.id == expected.id && current.createdAt == expected.createdAt
            && current.hostRelativePath == expected.hostRelativePath
            && current.sessionID == expected.sessionID && current.profileID == expected.profileID
    }

}

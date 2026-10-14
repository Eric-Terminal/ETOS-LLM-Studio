import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacLinuxStoragePresentationTests {
    @Test("向导目录只含身份与状态，不含目录名、路径或书签")
    func catalogHidesDirectoryAuthorization() throws {
        let workspace = LocalAgentWorkspace(sessionID: UUID(), guestPath: "/private/work", hostRelativePath: "Workspaces/private")
        let mount = LocalLinuxMountRecord(displayName: "私人目录", bookmark: Data("授权书签".utf8), access: .readOnly,
            guestPath: "/private/mount", activeLeaseCount: 2)
        let catalog = MacLinuxStorageCatalog.prepare(workspaces: [workspace], mounts: [mount], jobs: [])
        #expect(catalog.workspaceByID[workspace.id]?.workspace == workspace)
        #expect(catalog.mountByID[mount.id]?.record == mount)
        guard case .array(let workspaces) = catalog.guideWorkspaces, case .dictionary(let fields)? = workspaces.first,
              case .array(let mounts) = catalog.guideMounts, case .dictionary(let permissions)? = mounts.first else {
            Issue.record("缺少目录快照"); return
        }
        #expect(Set(fields.keys) == ["id", "session_id", "profile_id", "active_jobs"])
        #expect(Set(permissions.keys) == ["id", "access", "enabled", "authorization", "active_leases"])
        #expect(permissions["active_leases"] == .int(2))
    }

    @Test("统计更新保持工作区身份，重建或改指向使旧确认失效")
    func workspaceIdentityIgnoresOnlyDerivedValues() {
        let original = LocalAgentWorkspace(sessionID: UUID(), guestPath: "/work", hostRelativePath: "Workspaces/one")
        var current = original; current.sizeBytes = 123; current.lastUsedAt = Date().addingTimeInterval(10)
        #expect(MacLinuxStorageIdentity.matches(current, original))
        current.hostRelativePath = "Workspaces/two"
        #expect(!MacLinuxStorageIdentity.matches(current, original))
        current = original; current.sessionID = UUID()
        #expect(!MacLinuxStorageIdentity.matches(current, original))
    }
}

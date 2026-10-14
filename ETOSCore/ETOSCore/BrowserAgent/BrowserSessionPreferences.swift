import Foundation
import GRDB

public enum BrowserSessionPreferencesError: LocalizedError {
    case changed, unavailable

    public var errorDescription: String? {
        switch self {
        case .changed: return NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")
        case .unavailable: return NSLocalizedString("无法保存配置。", comment: "")
        }
    }
}

enum BrowserSessionPreferencesStore {
    /// 只为已保存的会话修改偏好；删除或临时会话不能因修改浏览器设置被重新创建。
    static func save(_ profile: BrowserAgentDataProfile, expected: BrowserAgentDataProfile, sessionID: UUID, in db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)", arguments: [sessionID.uuidString]) == true else {
            throw BrowserSessionPreferencesError.changed
        }
        let stored = try String.fetchOne(db, sql: "SELECT data_profile FROM browser_agent_session_preferences WHERE session_id = ?", arguments: [sessionID.uuidString])
        guard (stored ?? BrowserAgentDataProfile.sessionIsolated.rawValue) == expected.rawValue else {
            throw BrowserSessionPreferencesError.changed
        }
        try db.execute(sql: """
            INSERT INTO browser_agent_session_preferences (session_id, data_profile, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET data_profile = excluded.data_profile, updated_at = excluded.updated_at
            """, arguments: [sessionID.uuidString, profile.rawValue, Date().timeIntervalSince1970])
    }
}

extension PersistenceGRDBStore {
    func saveBrowserProfileDraft(_ profile: BrowserAgentDataProfile, expected: BrowserAgentDataProfile, sessionID: UUID) throws {
        try dbPool.write { try BrowserSessionPreferencesStore.save(profile, expected: expected, sessionID: sessionID, in: $0) }
    }
}

public extension Persistence {
    static func saveBrowserProfileDraft(_ profile: BrowserAgentDataProfile, expected: BrowserAgentDataProfile, sessionID: UUID) throws {
        guard let store = activeGRDBStore() else { throw BrowserSessionPreferencesError.unavailable }
        try store.saveBrowserProfileDraft(profile, expected: expected, sessionID: sessionID)
        WatchDatabaseSyncService.markDatabaseChanged(.chat)
        NotificationCenter.default.post(name: .cloudSyncLocalDataDidChange, object: nil)
    }
}

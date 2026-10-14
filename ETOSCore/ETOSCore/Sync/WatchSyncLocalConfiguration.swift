import Foundation
import GRDB

enum WatchSyncLocalConfiguration {
    static func isDeviceLocalKey(_ rawKey: String) -> Bool {
        if rawKey.hasPrefix("cloudSync.") || rawKey.hasPrefix("sync.delta.") {
            return true
        }
        return AppConfigKey(rawValue: rawKey)?.participatesInSync == false
    }

    /// 整库复制也必须遵守配置同步边界；云端身份、游标与基线不能冒用发送设备的值。
    static func preserve(in incomingDatabase: URL, localRows: [Row]) throws {
        let queue = try DatabaseQueue(path: incomingDatabase.path)
        try queue.write { db in
            let incomingKeys = try String.fetchAll(db, sql: "SELECT key FROM app_config")
            for key in incomingKeys where isDeviceLocalKey(key) {
                try db.execute(sql: "DELETE FROM app_config WHERE key = ?", arguments: [key])
            }
            for row in localRows {
                let key: String = row["key"]
                guard isDeviceLocalKey(key) else { continue }
                try db.execute(sql: """
                    INSERT INTO app_config (key, value_text, value_real, value_integer, type_hint, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: StatementArguments([
                        row["key"] as DatabaseValue, row["value_text"] as DatabaseValue,
                        row["value_real"] as DatabaseValue, row["value_integer"] as DatabaseValue,
                        row["type_hint"] as DatabaseValue, row["updated_at"] as DatabaseValue
                    ]))
            }
        }
    }
}

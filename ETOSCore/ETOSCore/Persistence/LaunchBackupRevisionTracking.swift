import Foundation
import GRDB

/// 标记与业务写入在同一事务内提交，覆盖 WAL 和 SQLCipher；回滚也会撤销标记变化。
/// 标记随 SQLite 一致性副本复制，不依赖进程内计数、文件时间或另写的旁路清单。
enum LaunchBackupRevisionTracking {
    struct Revision: Equatable {
        let generation: String
        let changes: Int64
    }

    private static let tableName = "_etos_launch_backup_revision"

    static func prepare(at url: URL) throws -> Revision {
        let configuration = Persistence.databaseEncryptionHasStoredPassphrase()
            ? Persistence.makeEncryptedDatabaseConfiguration(qos: .background)
            : Persistence.makePlainDatabaseConfiguration(qos: .background)
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.write { db in
            try install(in: db)
            return try read(in: db)!
        }
    }

    static func matches(_ revision: Revision, backupURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: backupURL.path),
              Persistence.isDatabaseHealthy(at: backupURL) else { return false }
        let configuration = Persistence.databaseEncryptionHasStoredPassphrase()
            ? Persistence.makeEncryptedDatabaseConfiguration(qos: .background, readonly: true)
            : Persistence.makePlainDatabaseConfiguration(qos: .background, readonly: true)
        do {
            let queue = try DatabaseQueue(path: backupURL.path, configuration: configuration)
            defer { try? queue.close() }
            return try queue.read { try read(in: $0) == revision }
        } catch {
            // 旧副本没有标记，或密钥与当前库不同，都必须重新生成可验证的副本。
            return false
        }
    }

    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS _etos_launch_backup_revision (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                generation TEXT NOT NULL,
                changes INTEGER NOT NULL,
                schema_version INTEGER NOT NULL
            )
            """)
        try db.execute(sql: """
            INSERT OR IGNORE INTO _etos_launch_backup_revision
                (id, generation, changes, schema_version) VALUES (1, '', 0, -1)
            """)

        let recordedSchema = try Int.fetchOne(db, sql: "SELECT schema_version FROM _etos_launch_backup_revision WHERE id = 1")
        let currentSchema = try Int.fetchOne(db, sql: "PRAGMA schema_version")!
        guard recordedSchema != currentSchema else { return }

        // 迁移、恢复或新表出现时重新覆盖实际业务表；FTS 虚拟表及其 shadow 表可重建。
        let tables = try Row.fetchAll(db, sql: "PRAGMA table_list").filter { row in
            let name: String = row["name"]
            return (row["schema"] as String) == "main" && (row["type"] as String) == "table"
                && !name.hasPrefix("sqlite_") && name != tableName
        }
        for row in tables {
            let name: String = row["name"]
            let quotedTable = name.quotedDatabaseIdentifier
            let columns = try db.columns(in: name)
            let unchanged = columns.map { columnInfo -> String in
                let column = columnInfo.name.quotedDatabaseIdentifier
                // 环境变量名等列使用 NOCASE；大小写变化仍然属于应备份的内容变化。
                return "OLD.\(column) IS NEW.\(column) COLLATE BINARY"
            }.joined(separator: " AND ")
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                let trigger = "_etos_launch_backup_\(name)_\(operation.lowercased())".quotedDatabaseIdentifier
                // 表增删列后 UPDATE 的比较条件也必须更新，避免漏掉新增字段。
                try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
                let condition = operation == "UPDATE" ? "WHEN NOT (\(unchanged))" : ""
                try db.execute(sql: """
                    CREATE TRIGGER \(trigger) AFTER \(operation) ON \(quotedTable)
                    \(condition)
                    BEGIN
                        UPDATE _etos_launch_backup_revision SET changes = changes + 1 WHERE id = 1;
                    END
                    """)
            }
        }
        let installedSchema = try Int.fetchOne(db, sql: "PRAGMA schema_version")!
        // 数据库替换或结构变化产生新代次，不能因两个库恰好有相同计数而误复用。
        try db.execute(
            sql: "UPDATE _etos_launch_backup_revision SET generation = ?, schema_version = ? WHERE id = 1",
            arguments: [UUID().uuidString, installedSchema]
        )
    }

    static func read(in db: Database) throws -> Revision? {
        guard try db.tableExists(tableName),
              let row = try Row.fetchOne(db, sql: "SELECT generation, changes FROM _etos_launch_backup_revision WHERE id = 1") else { return nil }
        return Revision(generation: row["generation"], changes: row["changes"])
    }
}

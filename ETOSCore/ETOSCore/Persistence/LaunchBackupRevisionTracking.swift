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
    private static let formatVersion = 2

    static func prepare(at url: URL) throws -> Revision {
        var configuration = Persistence.databaseEncryptionHasStoredPassphrase()
            ? Persistence.makeEncryptedDatabaseConfiguration(qos: .background)
            : Persistence.makePlainDatabaseConfiguration(qos: .background)
        // 启动后用户可能已开始写入；在后台等待短事务提交，不因瞬时写锁丢掉本次备份。
        configuration.busyMode = .timeout(5)
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
                schema_version INTEGER NOT NULL,
                schema_digest TEXT,
                format_version INTEGER NOT NULL DEFAULT 0
            )
            """)
        let metadataColumns = Set(try db.columns(in: tableName).map(\.name))
        if !metadataColumns.contains("schema_digest") {
            try db.execute(sql: "ALTER TABLE _etos_launch_backup_revision ADD COLUMN schema_digest TEXT")
        }
        if !metadataColumns.contains("format_version") {
            try db.execute(sql: "ALTER TABLE _etos_launch_backup_revision ADD COLUMN format_version INTEGER NOT NULL DEFAULT 0")
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO _etos_launch_backup_revision
                (id, generation, changes, schema_version) VALUES (1, '', 0, -1)
            """)

        let recordedSchema = try Int.fetchOne(db, sql: "SELECT schema_version FROM _etos_launch_backup_revision WHERE id = 1")
        let recordedFormat = try Int.fetchOne(db, sql: "SELECT format_version FROM _etos_launch_backup_revision WHERE id = 1")
        let currentSchema = try Int.fetchOne(db, sql: "PRAGMA schema_version")!
        // 跟踪语义升级也必须换触发器，不能只等待下一次业务表迁移。
        guard recordedSchema != currentSchema || recordedFormat != formatVersion else { return }
        let recordedDigest = try String.fetchOne(db, sql: "SELECT schema_digest FROM _etos_launch_backup_revision WHERE id = 1")
        if recordedFormat == formatVersion, try recordedDigest == schemaDigest(in: db) {
            // GRDB 为创建非空 WAL 会建删 grdb_issue_102，版本号增加但实际结构没有变化。
            // 比较包含跟踪触发器的完整定义；业务表被替换后触发器消失，仍会进入重建分支。
            try db.execute(sql: "UPDATE _etos_launch_backup_revision SET schema_version = ? WHERE id = 1", arguments: [currentSchema])
            return
        }

        // 迁移、恢复或新表出现时重新覆盖实际业务表；FTS 虚拟表及其 shadow 表可重建。
        let tables = try Row.fetchAll(db, sql: "PRAGMA table_list").filter { row in
            let name: String = row["name"]
            return (row["schema"] as String) == "main" && (row["type"] as String) == "table"
                && !name.hasPrefix("sqlite_") && name != tableName
        }
        let triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'")
        for trigger in triggers where trigger.hasPrefix("_etos_launch_backup_") {
            // 表重命名后旧触发器名仍会保留，统一替换避免对同一写入重复计数。
            try db.execute(sql: "DROP TRIGGER \(trigger.quotedDatabaseIdentifier)")
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
                let condition = operation == "UPDATE" ? "WHEN NOT (\(unchanged))" : ""
                // 两台设备可能从同一快照各写一次；随机标记区分这种等计数的内容分叉。
                try db.execute(sql: """
                    CREATE TRIGGER \(trigger) AFTER \(operation) ON \(quotedTable)
                    \(condition)
                    BEGIN
                        UPDATE _etos_launch_backup_revision
                        SET changes = changes + 1, generation = lower(hex(randomblob(16))) WHERE id = 1;
                    END
                    """)
            }
        }
        let installedSchema = try Int.fetchOne(db, sql: "PRAGMA schema_version")!
        let installedDigest = try schemaDigest(in: db)
        // 数据库替换或结构变化产生新代次，不能因两个库恰好有相同计数而误复用。
        try db.execute(
            sql: "UPDATE _etos_launch_backup_revision SET generation = ?, schema_version = ?, schema_digest = ?, format_version = ? WHERE id = 1",
            arguments: [UUID().uuidString, installedSchema, installedDigest, formatVersion]
        )
    }

    private static func schemaDigest(in db: Database) throws -> String {
        let statements = try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name")
        return try JSONEncoder().encode(statements).sha256Hex
    }

    static func read(in db: Database) throws -> Revision? {
        guard try db.tableExists(tableName),
              let row = try Row.fetchOne(db, sql: "SELECT generation, changes FROM _etos_launch_backup_revision WHERE id = 1") else { return nil }
        return Revision(generation: row["generation"], changes: row["changes"])
    }
}

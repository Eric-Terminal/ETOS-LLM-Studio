import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    /// UUID 是 FTS 的 UNINDEXED 列，逐条按 UUID 删除会反复扫描全部历史正文。
    /// 独立整数主键保存 FTS 行号，不依赖可能被 VACUUM 改写的 messages 隐式 rowid。
    static func ensureMessagesFTSObjects(_ db: Database) throws {
        let hadIndex = try db.tableExists("messages_fts")
        let hadRowMap = try db.tableExists("messages_fts_rows")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
            USING fts5(message_id UNINDEXED, session_id UNINDEXED, content, tokenize = 'unicode61')
            """)
        // 不设置级联外键：删除触发器必须先用映射清理 FTS，随后才能移除映射。
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS messages_fts_rows (
                fts_rowid INTEGER PRIMARY KEY,
                message_id TEXT NOT NULL UNIQUE
            )
            """)
        if !hadIndex || !hadRowMap {
            // 旧库只扫描一次已有索引，不重新分词；启动备份缺少 FTS 时清除旧映射。
            try db.execute(sql: "DELETE FROM messages_fts_rows")
            try db.execute(sql: """
                INSERT INTO messages_fts_rows(fts_rowid, message_id)
                SELECT rowid, message_id FROM messages_fts
                """)
        }

        // 迁移、结构修复及备份恢复统一安装同一组触发器，不能恢复成全表扫描版本。
        try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
        try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
        try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")
        try db.execute(sql: """
            CREATE TRIGGER messages_ai AFTER INSERT ON messages
            BEGIN
                INSERT INTO messages_fts_rows(message_id) VALUES (new.id);
                INSERT INTO messages_fts(rowid, message_id, session_id, content)
                VALUES (last_insert_rowid(), new.id, new.session_id, new.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER messages_ad AFTER DELETE ON messages
            BEGIN
                DELETE FROM messages_fts
                WHERE rowid = (SELECT fts_rowid FROM messages_fts_rows WHERE message_id = old.id);
                DELETE FROM messages_fts_rows WHERE message_id = old.id;
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER messages_au
            AFTER UPDATE OF id, session_id, content ON messages
            WHEN old.id IS NOT new.id
                OR old.session_id IS NOT new.session_id
                OR old.content IS NOT new.content
            BEGIN
                DELETE FROM messages_fts
                WHERE rowid = (SELECT fts_rowid FROM messages_fts_rows WHERE message_id = old.id);
                UPDATE messages_fts_rows SET message_id = new.id WHERE message_id = old.id;
                INSERT INTO messages_fts(rowid, message_id, session_id, content)
                SELECT fts_rowid, new.id, new.session_id, new.content
                FROM messages_fts_rows WHERE message_id = new.id;
            END
            """)
    }

    func rebuildMessagesFTSIndex() {
        do {
            try dbPool.write { db in
                try Self.ensureMessagesFTSObjects(db)
                try db.execute(sql: "DELETE FROM messages_fts")
                try db.execute(sql: "DELETE FROM messages_fts_rows")
                try db.execute(sql: """
                    INSERT INTO messages_fts(message_id, session_id, content)
                    SELECT id, session_id, content FROM messages
                    """)
                try db.execute(sql: """
                    INSERT INTO messages_fts_rows(fts_rowid, message_id)
                    SELECT rowid, message_id FROM messages_fts
                    """)
            }
            logger.info("聊天消息 FTS 索引已重建。")
        } catch {
            logger.error("重建聊天消息 FTS 索引失败: \(error.localizedDescription)")
        }
    }
}

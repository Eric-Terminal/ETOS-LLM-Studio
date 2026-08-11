// ============================================================================
// PersistenceSystemEntries.swift
// ETOS LLM Studio
// ============================================================================

import Foundation
import GRDB
import os.log

extension PersistenceGRDBStore {
    func loadSystemEntryReceipt(id: UUID) throws -> ETOSSystemEntryReceipt? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT id, kind, session_id, created_at FROM system_entry_receipts WHERE id = ?",
                arguments: [id.uuidString]
            ),
            let receiptID = UUID(uuidString: row["id"]),
            let kind = ETOSSystemEntryRequestKind(rawValue: row["kind"]) else {
                return nil
            }
            let sessionIDText: String? = row["session_id"]
            let createdAt: Double = row["created_at"]
            return ETOSSystemEntryReceipt(
                id: receiptID,
                kind: kind,
                sessionID: sessionIDText.flatMap(UUID.init(uuidString:)),
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        }
    }

    func saveSystemEntryReceipt(_ receipt: ETOSSystemEntryReceipt) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO system_entry_receipts (id, kind, session_id, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        session_id = COALESCE(system_entry_receipts.session_id, excluded.session_id)
                """,
                arguments: [
                    receipt.id.uuidString,
                    receipt.kind.rawValue,
                    receipt.sessionID?.uuidString,
                    receipt.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    func claimSystemEntryRequest(id: UUID, kind: ETOSSystemEntryRequestKind) throws -> Bool {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO system_entry_receipts (id, kind, session_id, created_at)
                    VALUES (?, ?, NULL, ?)
                """,
                arguments: [id.uuidString, kind.rawValue, Date().timeIntervalSince1970]
            )
            return db.changesCount == 1
        }
    }
}

public extension Persistence {
    static func loadSystemEntryReceipt(id: UUID) -> ETOSSystemEntryReceipt? {
        do {
            return try activeGRDBStore()?.loadSystemEntryReceipt(id: id)
        } catch {
            logger.error("读取系统入口回执失败：\(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    static func saveSystemEntryReceipt(_ receipt: ETOSSystemEntryReceipt) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveSystemEntryReceipt(receipt)
            return true
        } catch {
            logger.error("保存系统入口回执失败：\(error.localizedDescription)")
            return false
        }
    }


    static func claimSystemEntryRequest(id: UUID, kind: ETOSSystemEntryRequestKind) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            return try store.claimSystemEntryRequest(id: id, kind: kind)
        } catch {
            logger.error("领取系统入口请求失败：\(error.localizedDescription)")
            return false
        }
    }
}

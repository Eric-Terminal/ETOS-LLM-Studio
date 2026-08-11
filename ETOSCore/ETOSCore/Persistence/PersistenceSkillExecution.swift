// ============================================================================
// PersistenceSkillExecution.swift
// ETOS LLM Studio
//
// Skill 的执行策略与逐次授权保存在 GRDB；脚本内容仍只存在 Skill 目录。
// ============================================================================

import Foundation
import GRDB

extension PersistenceGRDBStore {
    static func createSkillExecutionGovernanceTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS skill_execution_policies (
                skill_name TEXT PRIMARY KEY NOT NULL,
                policy TEXT NOT NULL CHECK(policy IN ('deny', 'ask_every_time', 'allow_current_version')),
                approved_version_digest TEXT,
                updated_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS skill_script_approvals (
                id TEXT PRIMARY KEY NOT NULL,
                skill_name TEXT NOT NULL,
                version_digest TEXT NOT NULL,
                script_path TEXT NOT NULL,
                script_sha256 TEXT NOT NULL,
                decision TEXT NOT NULL,
                run_id TEXT,
                tool_call_id TEXT,
                approved_at REAL NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_skill_script_approvals_lookup
            ON skill_script_approvals(skill_name, version_digest, script_path, approved_at DESC)
        """)
    }

    func skillExecutionPolicy(skillName: String) throws -> SkillExecutionPolicyRecord? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM skill_execution_policies WHERE skill_name = ?",
                arguments: [skillName]
            ) else {
                return nil
            }
            let policyRawValue: String = row["policy"]
            guard let policy = SkillExecutionPolicy(rawValue: policyRawValue) else { return nil }
            let updatedAt: Double = row["updated_at"]
            return SkillExecutionPolicyRecord(
                skillName: row["skill_name"],
                policy: policy,
                approvedVersionDigest: row["approved_version_digest"],
                updatedAt: Date(timeIntervalSince1970: updatedAt)
            )
        }
    }

    func saveSkillExecutionPolicy(_ record: SkillExecutionPolicyRecord) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO skill_execution_policies (
                        skill_name, policy, approved_version_digest, updated_at
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(skill_name) DO UPDATE SET
                        policy = excluded.policy,
                        approved_version_digest = excluded.approved_version_digest,
                        updated_at = excluded.updated_at
                """,
                arguments: [
                    record.skillName,
                    record.policy.rawValue,
                    record.approvedVersionDigest,
                    record.updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func saveSkillScriptApproval(_ record: SkillScriptApprovalRecord) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO skill_script_approvals (
                        id, skill_name, version_digest, script_path, script_sha256,
                        decision, run_id, tool_call_id, approved_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.id.uuidString,
                    record.skillName,
                    record.versionDigest,
                    record.scriptPath,
                    record.scriptSHA256,
                    record.decision,
                    record.runID?.uuidString,
                    record.toolCallID,
                    record.approvedAt.timeIntervalSince1970
                ]
            )
        }
    }
}

public extension Persistence {
    static func skillExecutionPolicy(skillName: String) -> SkillExecutionPolicyRecord {
        do {
            if let store = activeGRDBStore(),
               let record = try store.skillExecutionPolicy(skillName: skillName) {
                return record
            }
        } catch {
            logger.error("读取 Skill 执行策略失败：\(error.localizedDescription)")
        }
        return SkillExecutionPolicyRecord(skillName: skillName, policy: .askEveryTime)
    }

    @discardableResult
    static func saveSkillExecutionPolicy(_ record: SkillExecutionPolicyRecord) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveSkillExecutionPolicy(record)
            WatchDatabaseSyncService.markDatabaseChanged(.chat)
            return true
        } catch {
            logger.error("保存 Skill 执行策略失败：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func saveSkillScriptApproval(_ record: SkillScriptApprovalRecord) -> Bool {
        do {
            guard let store = activeGRDBStore() else { return false }
            try store.saveSkillScriptApproval(record)
            return true
        } catch {
            logger.error("保存 Skill 脚本授权记录失败：\(error.localizedDescription)")
            return false
        }
    }
}

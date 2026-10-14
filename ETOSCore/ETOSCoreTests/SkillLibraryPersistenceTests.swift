import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct SkillLibraryPersistenceTests {
    @Test("技能单项开关保留未知名称及总开关，重命名尊重关闭状态")
    func incrementalSettingsPreserveOtherEntries() throws {
        let queue = try database()
        let result = try queue.write { db in
            _ = try SkillLibrarySettings.update(.created("future-skill"), in: db)
            _ = try SkillLibrarySettings.update(.created("enabled-skill"), in: db)
            _ = try SkillLibrarySettings.update(.created("still-disabled"), in: db)
            _ = try SkillLibrarySettings.update(.group(false), in: db)
            _ = try SkillLibrarySettings.update(.renamed("disabled-skill", "still-disabled"), in: db)
            _ = try SkillLibrarySettings.update(.renamed("enabled-skill", "renamed-skill"), in: db)
            return try SkillLibrarySettings.update(.enabled("another", true), in: db)
        }
        #expect(result.0 == ["future-skill", "renamed-skill", "another"])
        #expect(!result.1)
        let afterDelete = try queue.write { try SkillLibrarySettings.update(.deleted("renamed-skill"), in: $0) }
        #expect(afterDelete.0 == ["future-skill", "another"] && !afterDelete.1)
    }

    @Test("损坏的启用列表不能被空列表覆盖")
    func malformedSettingsRejectWrites() throws {
        let queue = try database()
        try queue.write { try $0.execute(sql: "INSERT INTO app_config (key, value_text) VALUES ('skills.enabledNames', 'broken')") }
        #expect(throws: SkillLibraryError.self) {
            try queue.write { try SkillLibrarySettings.update(.enabled("example", true), in: $0) }
        }
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config") } == "broken")
    }

    @Test("配置写入失败保留已有启用状态")
    func failedSettingsWriteRollsBack() throws {
        let queue = try database()
        try queue.write {
            _ = try SkillLibrarySettings.update(.created("original"), in: $0)
            try $0.execute(sql: "CREATE TRIGGER reject_write BEFORE UPDATE ON app_config BEGIN SELECT RAISE(ABORT, '拒绝测试写入'); END")
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { try SkillLibrarySettings.update(.renamed("original", "replacement"), in: $0) }
        }
        #expect(try queue.read { try SkillLibrarySettings.read(in: $0).0 } == ["original"])
    }

    @Test("重命名后数据库失败恢复原始目录、二进制文件和执行权限")
    func failedRenameRestoresDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("original"), target = root.appendingPathComponent("renamed")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let bytes = Data([0, 1, 2, 255])
        try bytes.write(to: old.appendingPathComponent("payload.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.appendingPathComponent("payload.bin").path)
        #expect(throws: FixtureError.self) {
            try SkillLibraryFileTransaction.perform(original: old, target: target) {
                try FileManager.default.moveItem(at: old, to: target)
                try Data("changed".utf8).write(to: target.appendingPathComponent("payload.bin"))
                throw FixtureError.writeFailed
            }
        }
        #expect(try Data(contentsOf: old.appendingPathComponent("payload.bin")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: old.appendingPathComponent("payload.bin").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["original"])
    }

    @Test("新增失败清除未完成目录，删除失败恢复原目录")
    func createAndDeleteFailuresRollBack() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("example")
        #expect(throws: FixtureError.self) {
            try SkillLibraryFileTransaction.perform(original: nil, target: target) {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                throw FixtureError.writeFailed
            }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: target.appendingPathComponent("SKILL.md"))
        #expect(throws: FixtureError.self) {
            try SkillLibraryFileTransaction.perform(original: target, target: target) {
                try FileManager.default.removeItem(at: target)
                throw FixtureError.writeFailed
            }
        }
        #expect(try String(contentsOf: target.appendingPathComponent("SKILL.md"), encoding: .utf8) == "body")
    }

    @Test("成功修改清理回滚副本，备份创建失败时不调用写入")
    func successfulWriteCleansBackupAndMissingOriginalStopsWrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("example")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try SkillLibraryFileTransaction.perform(original: original, target: original) {
            try Data("saved".utf8).write(to: original.appendingPathComponent("SKILL.md"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["example"])
        var called = false
        #expect(throws: (any Error).self) {
            try SkillLibraryFileTransaction.perform(original: root.appendingPathComponent("missing"), target: original) { called = true }
        }
        #expect(!called)
        #expect(try String(contentsOf: original.appendingPathComponent("SKILL.md"), encoding: .utf8) == "saved")
    }

    @Test("技能版本变化后拒绝旧编辑、删除和脚本授权")
    func staleVersionCannotMutateOrApprove() async throws {
        let (name, directory, metadata) = try skillFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let version = try SkillRunSnapshotBuilder.build(skill: metadata).versionDigest
        try Data("new body".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let worker = SkillLibraryWorker()
        let changes: [SkillLibraryMutation] = [
            .manifest(originalName: name, expectedVersion: version, content: "old draft", fallbackName: name),
            .file(name: name, expectedVersion: version, path: "notes.txt", creating: false, content: "old draft"),
            .delete(name: name, expectedVersion: version),
            .executionPolicy(name: name, expectedVersion: version,
                             original: SkillExecutionPolicyRecord(skillName: name, policy: .askEveryTime), policy: .allowCurrentVersion)
        ]
        for change in changes {
            await #expect(throws: SkillLibraryError.self) { try await worker.mutate(change) }
        }
        #expect(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8) == "new body")
    }

    @Test("新增文件拒绝覆盖已有资源和越界路径，未确认导入不能替换同名技能")
    func newResourcesAndImportsRequireValidTargets() async throws {
        let (name, directory, metadata) = try skillFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let version = try SkillRunSnapshotBuilder.build(skill: metadata).versionDigest
        let worker = SkillLibraryWorker()
        await #expect(throws: SkillLibraryError.self) {
            try await worker.mutate(.file(name: name, expectedVersion: version, path: "notes.txt", creating: true, content: "replacement"))
        }
        for path in ["../outside.txt", "SKILL.md", "notes.txt#fragment"] {
            await #expect(throws: SkillStoreError.self) {
                try await worker.mutate(.file(name: name, expectedVersion: version, path: path, creating: true, content: "replacement"))
            }
        }
        await #expect(throws: SkillLibraryError.self) {
            try await worker.mutate(.install(SkillImportResult(skillName: name, files: ["SKILL.md": Data("replacement".utf8)]), expectedVersion: nil))
        }
        #expect(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8) == "original")
    }

    private enum FixtureError: Error { case writeFailed }

    private func skillFixture() throws -> (String, URL, SkillMetadata) {
        let name = "library-test-\(UUID().uuidString)"
        let directory = try #require(SkillStore.resolveSkillDir(skillName: name))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\n---\n\nTest fixture".utf8).write(to: directory.appendingPathComponent("SKILL.md"))
        try Data("original".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        return (name, directory, SkillMetadata(name: name, description: "测试技能"))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-transaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { try $0.execute(sql: """
            CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL,
                                     value_integer INTEGER, type_hint TEXT, updated_at REAL)
            """) }
        return queue
    }
}

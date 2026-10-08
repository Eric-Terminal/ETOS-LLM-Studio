import Foundation
import Testing
@testable import ETOSCore

@Suite("调试目录提交后的验证与回滚")
struct LocalDebugDocumentValidationTests {
    @Test("验证新目录期间仍保留原文件，验证成功才清理恢复材料")
    func validationPrecedesRecoveryCleanup() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try fixture.readyReplacement()
        try staged.commit(validateInstalled: {
            #expect(FileManager.default.fileExists(atPath: staged.recoveryDirectory.appendingPathComponent("old.txt").path))
            #expect(FileManager.default.fileExists(atPath: staged.workingDirectory.appendingPathComponent("CommitStarted").path))
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("a-new.txt").path))
            try Data("迁移结果".utf8).write(to: fixture.root.appendingPathComponent("migration.txt"))
        })
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("migration.txt"), encoding: .utf8) == "迁移结果")
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("验证失败时撤回迁移改动与新建目录，再恢复原文件和链接")
    func validationFailureRollsBackAllGeneratedEntries() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), staged = try fixture.readyReplacement()
        #expect(throws: DebugReplacementFailure.injected) {
            try staged.commit(validateInstalled: {
                try Data("已改写".utf8).write(to: fixture.root.appendingPathComponent("a-new.txt"))
                let generated = fixture.root.appendingPathComponent("generated")
                try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: false)
                try Data().write(to: generated.appendingPathComponent("database.sqlite-wal"))
                // 新建内容与原文件同名时，也须先撤回，不能阻止原文件回到原处。
                try Data("新的同名文件".utf8).write(to: fixture.root.appendingPathComponent("old.txt"))
                throw DebugReplacementFailure.injected
            })
        }
        #expect(try fixture.snapshot() == original)
        #expect(!FileManager.default.fileExists(atPath: staged.workingDirectory.path))
    }

    @Test("验证失败后的回滚再次失败时，原文件和新数据都保留")
    func failedRollbackKeepsValidationRecoveryMaterial() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let staged = try fixture.readyReplacement()
        #expect(throws: LocalDebugDocumentReplacementError.rollbackFailed(staged.workingDirectory.path)) {
            try staged.commit(validateInstalled: {
                try Data("新数据库数据".utf8).write(to: fixture.root.appendingPathComponent("a-new.txt"))
                throw DebugReplacementFailure.injected
            }, move: { source, destination in
                if source.path == staged.recoveryDirectory.appendingPathComponent("old.txt").path { throw DebugReplacementFailure.injected }
                try FileManager.default.moveItem(at: source, to: destination)
            })
        }
        staged.discard()
        #expect(try String(contentsOf: staged.recoveryDirectory.appendingPathComponent("old.txt"), encoding: .utf8) == "原内容")
        #expect(try String(contentsOf: staged.incomingDirectory.appendingPathComponent("a-new.txt"), encoding: .utf8) == "新数据库数据")
        #expect(FileManager.default.fileExists(atPath: staged.workingDirectory.appendingPathComponent("CommitStarted").path))
    }

    @Test("移动文件失败时不会调用新目录验证器")
    func partialInstallationDoesNotValidate() throws {
        let fixture = try DebugReplacementFixture()
        defer { fixture.close() }
        let original = try fixture.snapshot(), staged = try fixture.readyReplacement()
        #expect(throws: DebugReplacementFailure.injected) {
            try staged.commit(validateInstalled: { Issue.record("目录尚未安装完整，不应启动验证") }, move: { source, destination in
                if source.path == staged.incomingDirectory.appendingPathComponent("b-new").path { throw DebugReplacementFailure.injected }
                try FileManager.default.moveItem(at: source, to: destination)
            })
        }
        #expect(try fixture.snapshot() == original)
    }
}

import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import ETOSCore

@Suite("Watch 库级覆盖的数据边界")
struct WatchDatabaseOverwriteTests {
    @Test("配置覆盖保留接收端身份、同步基线和本机开关，技能开关采用来源端")
    func preservesReceivingDeviceState() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try configDatabase(at: root.appendingPathComponent("local.sqlite"))
        let incomingURL = root.appendingPathComponent("incoming.sqlite")
        let incoming = try configDatabase(at: incomingURL)
        let localValues = [
            "cloudSync.deviceIdentifier": "iphone-id",
            "cloudSync.publishedRecordState.v3": "iphone-baseline",
            "cloudSync.recordZoneChangeToken.v3": "iphone-token",
            AppConfigKey.syncAutoSyncEnabled.rawValue: "iphone-switch",
            AppConfigKey.cloudSyncEnabled.rawValue: "iphone-cloud-switch",
            AppConfigKey.watchUseThirdPartyKeyboard.rawValue: "local-keyboard",
            AppConfigKey.skillsEnabledNames.rawValue: "iphone-skill"
        ]
        for (key, value) in localValues { try insert(key, value, in: local) }
        for key in localValues.keys { try insert(key, "watch-value", in: incoming) }
        try insert("sync.delta.checkpoint.watch.connectivity", "watch-only-checkpoint", in: incoming)
        let rows = try local.read { try Row.fetchAll($0, sql: "SELECT * FROM app_config") }

        try WatchSyncLocalConfiguration.preserve(in: incomingURL, localRows: rows)

        for (key, value) in localValues where key != AppConfigKey.skillsEnabledNames.rawValue {
            #expect(try read(key, in: incoming) == value)
        }
        #expect(try read(AppConfigKey.skillsEnabledNames.rawValue, in: incoming) == "watch-value")
        #expect(try read("sync.delta.checkpoint.watch.connectivity", in: incoming) == nil)
    }

    @Test("Skills 归档往返保留正文、脚本和二进制资源，安装后不会混入目标端旧技能")
    func skillsRoundTrip() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let files = ["phone-skill/SKILL.md": Data("手机技能".utf8),
                     "phone-skill/scripts/run.sh": Data("#!/bin/sh\nexit 0\n".utf8),
                     "phone-skill/assets/icon.bin": Data([0, 1, 255])]
        for (path, data) in files { try write(data, to: source.appendingPathComponent(path)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.appendingPathComponent("phone-skill/scripts/run.sh").path)
        let archive = try Archive(url: root.appendingPathComponent("skills.zip"), accessMode: .create)
        let paths = try WatchSyncSkillArchive.add(to: archive, directory: source)
        let staged = root.appendingPathComponent("staged")
        try WatchSyncSkillArchive.extract(from: archive, paths: paths, to: staged)
        let target = root.appendingPathComponent("target")
        try write(Data("手表旧技能".utf8), to: target.appendingPathComponent("watch-skill/SKILL.md"))

        try WatchSyncSkillArchive.install(from: staged, to: target) {}

        for (path, data) in files {
            #expect(try Data(contentsOf: target.appendingPathComponent(path)) == data)
            #expect(try Data(contentsOf: source.appendingPathComponent(path)) == data)
        }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("watch-skill").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("phone-skill/scripts/run.sh").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o755)
    }

    @Test("来源端空技能库会清空目标；数据库安装失败时恢复原技能文件")
    func emptyLibraryAndRollback() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let originalFile = target.appendingPathComponent("old/SKILL.md")
        let original = Data("需要保留的原内容".utf8)
        try write(original, to: originalFile)
        let failedSource = root.appendingPathComponent("failed-source")
        try FileManager.default.createDirectory(at: failedSource, withIntermediateDirectories: true)
        #expect(throws: CancellationError.self) {
            try WatchSyncSkillArchive.install(from: failedSource, to: target) { throw CancellationError() }
        }
        #expect(try Data(contentsOf: originalFile) == original)
        let emptySource = root.appendingPathComponent("empty-source")
        try FileManager.default.createDirectory(at: emptySource, withIntermediateDirectories: true)
        try WatchSyncSkillArchive.install(from: emptySource, to: target) {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test("Skills 清单拒绝目录穿越和缺失文件，不改动目标库")
    func rejectsInvalidSkillFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try Archive(url: root.appendingPathComponent("skills.zip"), accessMode: .create)
        for path in ["../outside", "/absolute", "missing/SKILL.md"] {
            #expect(throws: WatchDatabaseSyncService.SyncError.self) {
                try WatchSyncSkillArchive.extract(from: archive, paths: [path], to: root.appendingPathComponent("staged"))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func configDatabase(at url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL,
                                         value_integer INTEGER, type_hint TEXT, updated_at REAL)
                """)
        }
        return queue
    }

    private func insert(_ key: String, _ value: String, in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO app_config (key, value_text, type_hint, updated_at) VALUES (?, ?, 'text', 100)",
                           arguments: [key, value])
        }
    }

    private func read(_ key: String, in queue: DatabaseQueue) throws -> String? {
        try queue.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config WHERE key = ?", arguments: [key]) }
    }
}

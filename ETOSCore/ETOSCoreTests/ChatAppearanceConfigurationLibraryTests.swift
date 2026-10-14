import Foundation
import GRDB
import Testing
@testable import ETOSCore

struct ChatAppearanceConfigurationLibraryTests {
    @Test("颜色配置保存沿用原键与编码，保留文字规则及无关设置")
    func roundTripUsesExistingFormat() throws {
        let original = ChatAppearanceProfileConfiguration()
        let db = try database(original)
        var profile = ChatAppearanceProfile(id: "night", name: "夜间")
        profile.assistantBubble = .init(isEnabled: true, hex: "20203080")
        profile.assistantDarkTextStyles.customRules = [.init(exactText: "保留", colorHex: "FF0088FF")]
        let updated = ChatAppearanceProfileConfiguration(profiles: [.defaultProfile, profile],
            scheduleRules: [.init(profileID: profile.id, startMinuteOfDay: 22 * 60, endMinuteOfDay: 6 * 60)])
        let saved = try db.write { try ChatAppearanceConfigurationTransaction.save(updated, original: original, in: $0) }
        #expect(try read(db) == saved && saved == updated)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_config") } == 2)
        #expect(try db.read { try String.fetchOne($0, sql: "SELECT value_text FROM app_config WHERE key = 'unrelated'") } == "keep")
    }

    @Test("其他窗口只改时间段也会拒绝旧颜色草稿，保留新值")
    func staleWholeConfigurationIsRejected() throws {
        let original = ChatAppearanceProfileConfiguration(), db = try database(.init())
        var updated = original
        updated.scheduleRules = [.init(profileID: "default", startMinuteOfDay: 60, endMinuteOfDay: 120)]
        _ = try db.write { try ChatAppearanceConfigurationTransaction.save(updated, original: original, in: $0) }
        var stale = original; stale.profiles[0].name = "旧窗口"
        #expect(throws: ChatAppearanceConfigurationError.self) {
            try db.write { try ChatAppearanceConfigurationTransaction.save(stale, original: original, in: $0) }
        }
        #expect(try read(db) == updated)
    }

    @Test("重叠、空时间窗或缺失配置的时间段不会被静默丢弃后保存")
    func invalidSchedulesDoNotWrite() throws {
        let original = ChatAppearanceProfileConfiguration(), db = try database(.init())
        for rules in [
            [ChatAppearanceScheduleRule(profileID: "default", startMinuteOfDay: 60, endMinuteOfDay: 60)],
            [.init(profileID: "default", startMinuteOfDay: 60, endMinuteOfDay: 120), .init(profileID: "default", startMinuteOfDay: 90, endMinuteOfDay: 180)],
            [.init(profileID: "missing", startMinuteOfDay: 60, endMinuteOfDay: 120)]
        ] {
            var updated = original; updated.scheduleRules = rules
            #expect(throws: ChatAppearanceProfileError.self) {
                try db.write { try ChatAppearanceConfigurationTransaction.save(updated, original: original, in: $0) }
            }
        }
        #expect(try read(db) == original)
    }

    @Test("空名称与无效颜色在事务内被拒绝，原配置保持完整")
    func invalidProfileDoesNotWrite() throws {
        let original = ChatAppearanceProfileConfiguration(), db = try database(.init())
        var badName = original; badName.profiles[0].name = " \n"
        var badColor = original; badColor.profiles[0].userBubble = .init(isEnabled: true, hex: "invalid")
        for updated in [badName, badColor] {
            #expect(throws: ChatAppearanceConfigurationError.self) {
                try db.write { try ChatAppearanceConfigurationTransaction.save(updated, original: original, in: $0) }
            }
        }
        #expect(try read(db) == original)
    }

    @Test("数据库拒绝写入时颜色与时间段一同回滚")
    func failedWriteRollsBack() throws {
        let original = ChatAppearanceProfileConfiguration(), db = try database(.init())
        try db.write { try $0.execute(sql: "CREATE TRIGGER reject_color BEFORE UPDATE ON app_config BEGIN SELECT RAISE(ABORT, '测试拒绝'); END") }
        var updated = original; updated.profiles[0].name = "新名字"
        #expect(throws: DatabaseError.self) {
            try db.write { try ChatAppearanceConfigurationTransaction.save(updated, original: original, in: $0) }
        }
        #expect(try read(db) == original)
    }

    @Test("夏令时向前跳转后按墙钟时间切换，不把午夜秒数当作时刻")
    func springBoundaryUsesWallClock() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let config = ChatAppearanceProfileConfiguration(scheduleRules: [.init(profileID: "default", startMinuteOfDay: 210, endMinuteOfDay: 270)])
        let before = date("2026-03-08T09:45:00Z"), transition = date("2026-03-08T10:00:00Z")
        #expect(config.nextBoundary(after: before, calendar: calendar) == transition)
        #expect(config.nextBoundary(after: transition, calendar: calendar) == date("2026-03-08T10:30:00Z"))
    }

    @Test("夏令时回拨重新命中重复时段，仍调度第二次起始边界")
    func fallBoundaryIncludesRepeatedHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let profile = ChatAppearanceProfile(id: "morning", name: "清晨")
        let config = ChatAppearanceProfileConfiguration(profiles: [.defaultProfile, profile],
            scheduleRules: [.init(profileID: profile.id, startMinuteOfDay: 75, endMinuteOfDay: 105)])
        let transition = date("2026-11-01T09:00:00Z")
        #expect(config.nextBoundary(after: date("2026-11-01T08:50:00Z"), calendar: calendar) == transition)
        #expect(config.nextBoundary(after: transition, calendar: calendar) == date("2026-11-01T09:15:00Z"))
        #expect(config.activeProfile(at: date("2026-11-01T09:20:00Z"), calendar: calendar).id == profile.id)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func database(_ original: ChatAppearanceProfileConfiguration) throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: "CREATE TABLE app_config (key TEXT PRIMARY KEY, value_text TEXT, value_real REAL, value_integer INTEGER, type_hint TEXT NOT NULL, updated_at REAL NOT NULL)")
            let raw = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
            try db.execute(sql: "INSERT INTO app_config (key, value_text, type_hint, updated_at) VALUES (?, ?, 'text', 0)",
                           arguments: [ChatAppearanceProfileStore.configurationStorageKey, raw])
            try db.execute(sql: "INSERT INTO app_config (key, value_text, type_hint, updated_at) VALUES ('unrelated', 'keep', 'text', 0)")
        }
        return db
    }
    private func read(_ db: DatabaseQueue) throws -> ChatAppearanceProfileConfiguration {
        try db.read { db in
            let raw = try #require(try String.fetchOne(db, sql: "SELECT value_text FROM app_config WHERE key = ?",
                                                      arguments: [ChatAppearanceProfileStore.configurationStorageKey]))
            return try JSONDecoder().decode(ChatAppearanceProfileConfiguration.self, from: Data(raw.utf8))
        }
    }
}

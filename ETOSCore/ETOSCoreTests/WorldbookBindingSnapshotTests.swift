import Foundation
import Testing
@testable import ETOSCore

struct WorldbookBindingSnapshotTests {
    @Test("绑定摘要区分角色来源与手动选择，并保留整本停用和条目启用数量")
    func roleplaySourcesRemainIndependentOfSelection() throws {
        let embedded = Worldbook(name: "角色设定", isEnabled: false, entries: [
            WorldbookEntry(content: "启用条目", keys: []),
            WorldbookEntry(content: "停用条目", keys: [], isEnabled: false)
        ])
        let additional = Worldbook(name: "附加世界书", entries: [])
        let manual = Worldbook(name: "手动选择", entries: [])
        let alice = RoleplayCharacter(name: "Alice", embeddedWorldbookID: embedded.id)
        let bob = RoleplayCharacter(name: "Bob", embeddedWorldbookID: embedded.id)
        let binding = SessionRoleplayBinding(
            sessionID: UUID(), characterIDs: [alice.id, bob.id],
            additionalWorldbookIDs: [embedded.id, additional.id]
        )
        let snapshot = WorldbookBindingSnapshot(
            worldbooks: [manual, embedded, additional], characters: [alice, bob], binding: binding
        )

        #expect(snapshot.roleplayIDs == [embedded.id, additional.id])
        let row = try #require(snapshot.rows.first { $0.id == embedded.id })
        #expect(row.roleplaySource == "Alice, Bob")
        #expect(!row.isEnabled)
        #expect(row.entryCount == 2)
        #expect(row.enabledEntryCount == 1)
        #expect(snapshot.rows.first { $0.id == manual.id }?.roleplaySource == nil)
        #expect(try snapshot.selection(from: .array([])).isEmpty)
        #expect(snapshot.roleplayIDs.contains(embedded.id))
    }

    @Test("没有有效角色时不将附加世界书误标为角色生效来源")
    func missingCharacterDoesNotActivateAdditionalWorldbooks() {
        let book = Worldbook(name: "附加世界书", entries: [])
        let binding = SessionRoleplayBinding(
            sessionID: UUID(), characterIDs: [UUID()], additionalWorldbookIDs: [book.id]
        )
        let snapshot = WorldbookBindingSnapshot(worldbooks: [book], characters: [], binding: binding)
        #expect(snapshot.roleplayIDs.isEmpty)
        #expect(snapshot.rows.first?.roleplaySource == nil)
    }

    @Test("向导绑定只接受当前列表中存在且不重复的世界书 ID")
    func guideSelectionRejectsDeletedAndDuplicateIDs() throws {
        let book = Worldbook(name: "保留的世界书", entries: [])
        let snapshot = WorldbookBindingSnapshot(worldbooks: [book], characters: [], binding: nil)
        let valid = JSONValue.string(book.id.uuidString)
        #expect(try snapshot.selection(from: .array([valid])) == [book.id])
        #expect(throws: GuideError.self) {
            try snapshot.selection(from: .array([.string(UUID().uuidString)]))
        }
        #expect(throws: GuideError.self) {
            try snapshot.selection(from: .array([valid, valid]))
        }
        #expect(throws: GuideError.self) {
            try snapshot.selection(from: .string(book.id.uuidString))
        }
    }
}

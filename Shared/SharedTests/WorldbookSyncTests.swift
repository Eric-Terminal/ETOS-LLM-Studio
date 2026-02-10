import Testing
import Foundation
import Combine
@testable import Shared

@Suite("Worldbook Sync Tests")
struct WorldbookSyncTests {

    @Test("worldbooks are merged when sync option is enabled")
    func testWorldbooksMerged() async {
        let store = WorldbookStore.shared
        let original = store.loadWorldbooks()
        defer {
            store.saveWorldbooks(original)
        }

        store.saveWorldbooks([])

        let incomingBook = Worldbook(
            name: "同步世界书",
            entries: [
                WorldbookEntry(
                    content: "同步条目内容",
                    keys: ["sync"],
                    position: .after,
                    order: 100
                )
            ]
        )

        let package = SyncPackage(
            options: [.worldbooks],
            worldbooks: [incomingBook]
        )

        let summary = await SyncEngine.apply(package: package)
        #expect(summary.importedWorldbooks == 1)

        let merged = store.loadWorldbooks()
        #expect(merged.contains(where: { $0.name == "同步世界书" }))

        let summary2 = await SyncEngine.apply(package: package)
        #expect(summary2.skippedWorldbooks >= 1)
    }

    @Test("same name worldbooks keep both and remap session bindings")
    func testSameNameConflictAndSessionRemap() async {
        let store = WorldbookStore.shared
        let originalBooks = store.loadWorldbooks()
        defer {
            store.saveWorldbooks(originalBooks)
        }

        store.saveWorldbooks([])
        let chatService = ChatService()
        let localBook = Worldbook(
            id: UUID(),
            name: "同名世界书",
            entries: [WorldbookEntry(content: "local content", keys: ["local"])]
        )
        store.saveWorldbooks([localBook])

        let incomingBookID = UUID()
        let incomingBook = Worldbook(
            id: incomingBookID,
            name: "同名世界书",
            entries: [WorldbookEntry(content: "incoming content", keys: ["incoming"])]
        )

        let session = ChatSession(
            id: UUID(),
            name: "同步会话",
            worldbookIDs: [incomingBookID]
        )
        let package = SyncPackage(
            options: [.sessions, .worldbooks],
            sessions: [SyncedSession(session: session, messages: [])],
            worldbooks: [incomingBook]
        )

        let summary = await SyncEngine.apply(package: package, chatService: chatService)
        #expect(summary.importedWorldbooks == 1)

        let mergedBooks = store.loadWorldbooks()
        #expect(mergedBooks.count == 2)
        #expect(mergedBooks.contains(where: { $0.name == "同名世界书（同步）" }))

        let syncedSession = chatService.chatSessionsSubject.value.first(where: { $0.name == "同步会话" })
        let importedBook = mergedBooks.first(where: { $0.name == "同名世界书（同步）" })
        #expect(syncedSession != nil)
        #expect(importedBook != nil)
        #expect(syncedSession?.worldbookIDs.contains(importedBook?.id ?? UUID()) == true)
        #expect(syncedSession?.worldbookIDs.contains(incomingBookID) == false)
    }
}

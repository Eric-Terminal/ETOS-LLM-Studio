import Testing
import Foundation
@testable import Shared

@Suite("Shortcut Sync Tests")
struct ShortcutSyncTests {

    @MainActor
    @Test("shortcut tools are merged when sync option is enabled")
    func testShortcutToolsMerged() async {
        let original = ShortcutToolStore.loadTools()
        defer {
            ShortcutToolStore.saveTools(original)
            ShortcutToolManager.shared.reloadFromDisk()
        }

        ShortcutToolStore.saveTools([])
        ShortcutToolManager.shared.reloadFromDisk()

        let incomingTool = ShortcutToolDefinition(
            name: "Sync Imported Tool",
            isEnabled: false,
            generatedDescription: "from peer"
        )

        let package = SyncPackage(
            options: [.shortcutTools],
            shortcutTools: [incomingTool]
        )

        let summary = await SyncEngine.apply(package: package)
        #expect(summary.importedShortcutTools == 1)

        let merged = ShortcutToolStore.loadTools()
        #expect(merged.contains(where: { $0.name == "Sync Imported Tool" }))
    }
}

import Foundation
import Testing
@testable import ETOSCore
@testable import ETOS_LLM_Studio_macOS_App

struct MacLinuxFilePresentationTests {
    @Test("目录合并分页按名称去重，自然排序并将目录置前，向导不含路径和文件名")
    func directoryPaginationAndPrivacy() {
        let parent = info(nil, mode: 0o040755)
        let first = LocalLinuxBrowserDirectory(node: LocalLinuxBrowserNode(path: "/private", info: parent), resolvedInfo: parent,
            page: LocalLinuxGuestDirectoryPage(entries: [info("."), info(".."), info("note10"), info("note2"), info("folder", mode: 0o040755)], nextCursor: 4, isComplete: false))
        let catalog = MacLinuxFileDirectory.prepare(first)
        #expect(catalog.rows.map(\.name) == ["folder", "note2", "note10"])
        let next = LocalLinuxBrowserDirectory(node: first.node, resolvedInfo: parent,
            page: LocalLinuxGuestDirectoryPage(entries: [info("note2", size: 80), info("link", mode: 0o120777)], nextCursor: 5, isComplete: true))
        let combined = MacLinuxFileDirectory.prepare(next, previous: catalog.rows)
        #expect(combined.rows.count == 4); #expect(combined.rows.first { $0.name == "note2" }?.node.info.size == 80)
        #expect(combined.rows.first { $0.name == "link" }?.symbol == "link")
        #expect(combined.parentPath == "/")
        guard case .dictionary(let fields) = combined.guide else { Issue.record("缺少目录状态"); return }
        #expect(Set(fields.keys) == ["entry_count", "complete", "is_root"])
        #expect(fields["entry_count"] == .int(4)); #expect(fields["complete"] == .bool(true))
        #expect(catalog.id != combined.id)
    }

    @Test("只读预览说明在后台准备，重新本地化保留编辑器身份和原件")
    func editorPresentationRetainsSource() {
        let metadata = info(nil, size: 300_000)
        let preview = LocalLinuxBrowserPreview(node: LocalLinuxBrowserNode(path: "/work/私密名称.txt", info: metadata),
            resolvedInfo: metadata, content: "前缀内容", readOnlyReason: .large, originalData: Data())
        let first = MacLinuxFileEditorTarget.prepare(preview)
        let refreshed = MacLinuxFileEditorTarget.prepare(preview, id: first.id)
        #expect(refreshed.id == first.id); #expect(refreshed.title == "私密名称.txt")
        #expect(refreshed.notice != nil); #expect(!refreshed.preview.isEditable)
        #expect(refreshed.preview.content == "前缀内容")
    }

    private func info(_ name: String?, size: UInt64 = 1, mode: UInt32 = 0o100644) -> LocalLinuxGuestFileInfo {
        LocalLinuxGuestFileInfo(name: name, device: 1, inode: 1, size: size, blocks: 1, mode: mode, linkCount: 1,
            userID: 0, groupID: 0, blockSize: 4096, accessTime: .distantPast, modificationTime: .distantPast, statusChangeTime: .distantPast)
    }
}

import Foundation
import Testing
@testable import ETOSCore

struct LocalLinuxFileBrowserTests {
    @Test("完整 UTF-8 文件保留 BOM、空白与原始权限，符号链接按 guest 目标读取")
    func textAndSymlinkSavePreserveContentAndMode() async throws {
        let fs = BrowserTestFileSystem(), browser = LocalLinuxFileBrowser(fileSystem: fs)
        let original = Data([0xef, 0xbb, 0xbf]) + Data(" \n原文\n ".utf8)
        await fs.put("/note", data: original, mode: 0o100640)
        await fs.link("/alias", to: "/note")
        guard case .file(let preview) = try await browser.open(path: "/alias") else { Issue.record("未打开文本预览"); return }
        #expect(preview.isEditable); #expect(Data(preview.content.utf8) == original); #expect(preview.node.info.isSymbolicLink)
        try await browser.save(preview, content: "\u{feff}\n修改后  ")
        #expect(await fs.data("/note") == Data([0xef, 0xbb, 0xbf]) + Data("\n修改后  ".utf8))
        #expect(await fs.lastWriteMode == 0o640)
        #expect(await fs.lastWriteFollowedLinks)
    }

    @Test("大文件、二进制和无效 UTF-8 只读，特殊文件不会发起读取")
    func unsafeTextPreviewsStayReadOnly() async throws {
        let fs = BrowserTestFileSystem(), browser = LocalLinuxFileBrowser(fileSystem: fs)
        let cases: [(String, Data, UInt32, LocalLinuxBrowserPreview.ReadOnlyReason)] = [
            ("/large", Data(repeating: 0x61, count: Int(LocalLinuxFileBrowser.previewByteLimit) + 1), 0o100644, .large),
            ("/binary", Data([0, 1, 2]), 0o100644, .binary),
            ("/invalid", Data([0xff, 0xfe]), 0o100644, .invalidUTF8),
            ("/pipe", Data(), 0o010644, .special)
        ]
        for (path, data, mode, reason) in cases {
            await fs.put(path, data: data, mode: mode)
            let reads = await fs.readCount
            guard case .file(let preview) = try await browser.open(path: path) else { Issue.record("未打开只读预览"); return }
            #expect(preview.readOnlyReason == reason); #expect(!preview.isEditable)
            if reason == .special { #expect(await fs.readCount == reads) }
            if reason == .large { #expect(preview.content.utf8.count == Int(LocalLinuxFileBrowser.previewByteLimit)) }
            await #expect(throws: LocalLinuxFileBrowserError.self) { try await browser.save(preview, content: "不应写入") }
        }
        #expect(await fs.writeCount == 0)
    }

    @Test("元数据未变但内容不同也拒绝旧草稿，不能覆盖替换后的文件")
    func staleBytesAndIdentityAreRejected() async throws {
        let fs = BrowserTestFileSystem(), browser = LocalLinuxFileBrowser(fileSystem: fs)
        await fs.put("/note", data: Data("first".utf8))
        guard case .file(let original) = try await browser.open(path: "/note") else { Issue.record("缺少原件"); return }
        await fs.replaceBytesOnly("/note", data: Data("other".utf8))
        await #expect(throws: LocalLinuxFileBrowserError.self) { try await browser.save(original, content: "旧窗口") }
        #expect(await fs.data("/note") == Data("other".utf8))
        await fs.put("/note", data: Data("first".utf8), inode: 99)
        await #expect(throws: LocalLinuxFileBrowserError.self) { try await browser.save(original, content: "旧窗口") }
        #expect(await fs.writeCount == 0)
    }

    @Test("文件读取过程中被替换时不发布可编辑预览")
    func changeDuringReadIsDetected() async throws {
        let fs = BrowserTestFileSystem(), browser = LocalLinuxFileBrowser(fileSystem: fs)
        await fs.put("/note", data: Data("text".utf8))
        await fs.replaceDuringNextRead()
        await #expect(throws: LocalLinuxFileBrowserError.self) { _ = try await browser.open(path: "/note") }
    }

    @Test("目录分页核对原目录版本并拒绝不前进的游标")
    func directoryPaginationChecksSource() async throws {
        let fs = BrowserTestFileSystem(), browser = LocalLinuxFileBrowser(fileSystem: fs)
        await fs.put("/folder", data: Data(), mode: 0o040755)
        await fs.setPage(cursor: 0, page: LocalLinuxGuestDirectoryPage(entries: [], nextCursor: 5, isComplete: false))
        let first = try await browser.directory(path: "/folder")
        #expect(first.page.nextCursor == 5)
        await fs.put("/folder", data: Data(), mode: 0o040755, inode: 22)
        await #expect(throws: LocalLinuxFileBrowserError.self) { _ = try await browser.directory(path: "/folder", cursor: 5, original: first) }
        await fs.setPage(cursor: 0, page: LocalLinuxGuestDirectoryPage(entries: [], nextCursor: 0, isComplete: false))
        await #expect(throws: LocalLinuxFileBrowserError.self) { _ = try await browser.directory(path: "/folder") }
    }

    @Test("删除检查旧身份，目录符号链接只删除链接且不递归目标")
    func deletionChecksIdentityAndLinkSemantics() async throws {
        let fs = BrowserTestFileSystem(), browser = LocalLinuxFileBrowser(fileSystem: fs)
        await fs.put("/folder", data: Data(), mode: 0o040755)
        let directory = try await browser.directory(path: "/folder")
        await fs.put("/folder", data: Data(), mode: 0o040755, inode: 55)
        await #expect(throws: LocalLinuxFileBrowserError.self) { try await browser.remove(directory.node) }
        #expect(await fs.removeCount == 0)
        await fs.link("/alias", to: "/folder")
        let alias = try await browser.directory(path: "/alias")
        try await browser.remove(alias.node)
        #expect(await fs.lastRemoveRecursive == false)
        #expect(await fs.contains("/folder")); #expect(await fs.contains("/alias") == false)
        let current = try await browser.directory(path: "/folder")
        try await browser.remove(current.node)
        #expect(await fs.lastRemoveRecursive == true)
    }

    @Test("等待 guest 写入期间第二个窗口不能同时进入保存检查")
    func concurrentSavesDoNotInterleave() async throws {
        let fs = BrowserTestFileSystem(), browser = LocalLinuxFileBrowser(fileSystem: fs)
        await fs.put("/note", data: Data("before".utf8))
        guard case .file(let original) = try await browser.open(path: "/note") else { Issue.record("缺少原件"); return }
        await fs.pauseNextWrite()
        let first = Task { try await browser.save(original, content: "first") }
        await fs.waitForWrite()
        await #expect(throws: LocalLinuxFileBrowserError.self) { try await browser.save(original, content: "second") }
        await fs.releaseWrite()
        try await first.value
        #expect(await fs.data("/note") == Data("first".utf8)); #expect(await fs.writeCount == 1)
    }

    @Test("取消的保存不写入，关键目录识别保留 guest 根路径语义")
    func cancellationAndCriticalPaths() async throws {
        let fs = BrowserTestFileSystem(), browser = LocalLinuxFileBrowser(fileSystem: fs)
        await fs.put("/note", data: Data())
        guard case .file(let original) = try await browser.open(path: "/note") else { Issue.record("缺少空文件预览"); return }
        #expect(original.isEditable)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await browser.save(original, content: "迟到写入")
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await fs.writeCount == 0)
        #expect(LocalLinuxFileBrowser.isCriticalSystemPath("/"))
        #expect(LocalLinuxFileBrowser.isCriticalSystemPath("/usr/"))
        #expect(!LocalLinuxFileBrowser.isCriticalSystemPath("/usr/share/note"))
    }

    @Test("读取引起的 atime 与目录回调名称差异不误判为外部修改")
    func accessTimeAndEntryNameDoNotChangeRevision() async throws {
        let fs = BrowserTestFileSystem()
        await fs.put("/note", data: Data("text".utf8))
        let original = try await fs.statGuestFile(path: "/note", requestID: 1, noFollow: true)
        let after = LocalLinuxGuestFileInfo(name: "note", device: original.device, inode: original.inode, size: original.size,
            blocks: original.blocks, mode: original.mode, linkCount: original.linkCount, userID: original.userID,
            groupID: original.groupID, blockSize: original.blockSize, accessTime: Date(timeIntervalSince1970: 99),
            modificationTime: original.modificationTime, statusChangeTime: original.statusChangeTime)
        #expect(LocalLinuxFileBrowser.sameRevision(after, original))
    }
}

private actor BrowserTestFileSystem: LocalLinuxBrowsingFileSystem {
    private var contents: [String: Data] = [:]
    private var metadata: [String: LocalLinuxGuestFileInfo] = [:]
    private var links: [String: String] = [:]
    private var pages: [UInt64: LocalLinuxGuestDirectoryPage] = [:]
    private var changeDuringRead = false
    private var pauseWrite = false
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var removeCount = 0
    private(set) var lastWriteMode: UInt32?
    private(set) var lastWriteFollowedLinks = false
    private(set) var lastRemoveRecursive = false
    private enum Failure: Error { case missing }

    func put(_ path: String, data: Data, mode: UInt32 = 0o100644, inode: UInt64 = 1) {
        contents[path] = data
        metadata[path] = LocalLinuxGuestFileInfo(name: nil, device: 1, inode: inode, size: UInt64(data.count), blocks: 1,
            mode: mode, linkCount: 1, userID: 0, groupID: 0, blockSize: 4096, accessTime: Date(timeIntervalSince1970: 1),
            modificationTime: Date(timeIntervalSince1970: 2), statusChangeTime: Date(timeIntervalSince1970: 3))
    }
    func link(_ path: String, to target: String) { put(path, data: Data(target.utf8), mode: 0o120777, inode: 10); links[path] = target }
    func replaceBytesOnly(_ path: String, data: Data) { contents[path] = data }
    func replaceDuringNextRead() { changeDuringRead = true }
    func setPage(cursor: UInt64, page: LocalLinuxGuestDirectoryPage) { pages[cursor] = page }
    func data(_ path: String) -> Data? { contents[path] }
    func contains(_ path: String) -> Bool { metadata[path] != nil }
    func pauseNextWrite() { pauseWrite = true }
    func waitForWrite() async {
        if writeContinuation != nil { return }
        await withCheckedContinuation { writeWaiters.append($0) }
    }
    func releaseWrite() { writeContinuation?.resume(); writeContinuation = nil; pauseWrite = false }

    func statGuestFile(path: String, requestID: UInt64, noFollow: Bool) async throws -> LocalLinuxGuestFileInfo {
        guard let info = metadata[noFollow ? path : links[path] ?? path] else { throw Failure.missing }
        return info
    }
    func listGuestDirectory(path: String, requestID: UInt64, cursor: UInt64, maximumEntryCount: UInt32, noFollow: Bool) async throws -> LocalLinuxGuestDirectoryPage {
        pages[cursor] ?? LocalLinuxGuestDirectoryPage(entries: [], nextCursor: cursor, isComplete: true)
    }
    func readGuestFile(path: String, requestID: UInt64, offset: UInt64, maximumByteCount: UInt32, noFollow: Bool) async throws -> LocalLinuxGuestFileReadResult {
        readCount += 1
        let target = noFollow ? path : links[path] ?? path
        guard let data = contents[target] else { throw Failure.missing }
        if changeDuringRead { changeDuringRead = false; put(target, data: data, inode: 100) }
        let start = min(Int(offset), data.count), end = min(data.count, Int(offset) + Int(maximumByteCount))
        return LocalLinuxGuestFileReadResult(data: data.subdata(in: start..<end), totalSize: UInt64(data.count), isComplete: end == data.count)
    }
    func writeGuestFile(path: String, requestID: UInt64, data: Data, mode: UInt32, noFollow: Bool) async throws {
        writeCount += 1; lastWriteMode = mode; lastWriteFollowedLinks = !noFollow
        if pauseWrite {
            await withCheckedContinuation { continuation in
                writeContinuation = continuation
                let waiters = writeWaiters; writeWaiters.removeAll(); waiters.forEach { $0.resume() }
            }
        }
        contents[noFollow ? path : links[path] ?? path] = data
    }
    func removeGuestFile(path: String, requestID: UInt64, recursive: Bool, noFollow: Bool) async throws {
        removeCount += 1; lastRemoveRecursive = recursive
        contents[path] = nil; metadata[path] = nil; links[path] = nil
    }
}

// ============================================================================
// SandboxFileToolSupportTests.swift
// ============================================================================
// SandboxFileToolSupportTests 测试文件
// - 覆盖沙盒路径逃逸拦截
// - 覆盖文本文件读写与目录列表
// ============================================================================

import Testing
import Foundation
@testable import ETOSCore

@Suite("沙盒文件工具辅助测试")
struct SandboxFileToolSupportTests {

    @Test("路径不能逃逸出沙盒根目录")
    func testResolveURLRejectsParentTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: SandboxFileToolError.self) {
            try SandboxFileToolSupport.resolveURL(
                relativePath: "../secret.txt",
                rootDirectory: root,
                allowRoot: false
            )
        }
    }

    @Test("可以在沙盒根目录中写入并读回文本文件")
    func testWriteAndReadTextFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writeResult = try SandboxFileToolSupport.writeTextFile(
            relativePath: "notes/test.txt",
            content: "hello sandbox",
            rootDirectory: root
        )
        let loaded = try SandboxFileToolSupport.readTextFile(
            relativePath: "notes/test.txt",
            rootDirectory: root
        )

        #expect(writeResult.path == "Documents/notes/test.txt")
        #expect(writeResult.createdParentDirectories == true)
        #expect(loaded == "hello sandbox")
    }

    @Test("列目录会返回子项信息")
    func testListDirectoryReturnsEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "drafts/chapter1.txt",
            content: "chapter",
            rootDirectory: root
        )

        let entries = try SandboxFileToolSupport.listDirectory(
            relativePath: "drafts",
            rootDirectory: root
        )

        #expect(entries.count == 1)
        #expect(entries[0].name == "chapter1.txt")
        #expect(entries[0].isDirectory == false)
        #expect(entries[0].path == "Documents/drafts/chapter1.txt")
    }

    @Test("搜索工具支持按文件名与内容检索")
    func testSearchItemsFindsByNameAndContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "docs/plan.txt",
            content: "alpha beta",
            rootDirectory: root
        )
        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "logs/app.log",
            content: "beta gamma",
            rootDirectory: root
        )

        let byName = try SandboxFileToolSupport.searchItems(
            relativePath: "",
            nameQuery: "plan",
            contentQuery: nil,
            rootDirectory: root
        )
        let byContent = try SandboxFileToolSupport.searchItems(
            relativePath: "",
            nameQuery: nil,
            contentQuery: "gamma",
            rootDirectory: root
        )

        #expect(byName.count == 1)
        #expect(byName[0].path == "Documents/docs/plan.txt")
        #expect(byContent.count == 1)
        #expect(byContent[0].path == "Documents/logs/app.log")
    }

    @Test("分块读取会返回指定行范围与是否还有剩余内容")
    func testReadTextFileChunkReturnsExpectedWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "notes/chunk.txt",
            content: "line1\nline2\nline3\nline4\nline5",
            rootDirectory: root
        )

        let chunk = try SandboxFileToolSupport.readTextFileChunk(
            relativePath: "notes/chunk.txt",
            startLine: 2,
            maxLines: 2,
            rootDirectory: root
        )

        #expect(chunk.startLine == 2)
        #expect(chunk.endLine == 3)
        #expect(chunk.totalLines == nil)
        #expect(chunk.hasMore == true)
        #expect(chunk.content == "line2\nline3")
    }

    @Test("沙盒分块读取用字节 cursor 约束超长单行")
    func testReadTextFileChunkBoundsLongLine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("long.txt")
        try Data(repeating: 0x61, count: 2 * 1_024 * 1_024).write(to: fileURL)

        let first = try SandboxFileToolSupport.readTextFileChunk(
            relativePath: "long.txt",
            startLine: 1,
            maxLines: 1,
            maxBytes: 1_024,
            rootDirectory: root
        )
        let second = try SandboxFileToolSupport.readTextFileChunk(
            relativePath: "long.txt",
            startLine: first.nextStartLine ?? 1,
            maxLines: 1,
            byteOffset: first.nextByteOffset,
            maxBytes: 1_024,
            rootDirectory: root
        )

        #expect(first.content.utf8.count == 1_024)
        #expect(first.contentTruncated)
        #expect(first.nextByteOffset == 1_024)
        #expect(second.nextByteOffset == 2_048)
    }

    @Test("沙盒分块 cursor 不会拆开 CRLF")
    func testReadTextFileChunkConsumesCRLFTogether() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abcd\r\nz".utf8).write(to: root.appendingPathComponent("crlf.txt"))

        let first = try SandboxFileToolSupport.readTextFileChunk(
            relativePath: "crlf.txt",
            startLine: 1,
            maxLines: 10,
            maxBytes: 4,
            rootDirectory: root
        )
        let second = try SandboxFileToolSupport.readTextFileChunk(
            relativePath: "crlf.txt",
            startLine: first.nextStartLine ?? 1,
            maxLines: 10,
            byteOffset: first.nextByteOffset,
            maxBytes: 4,
            rootDirectory: root
        )

        #expect(first.nextByteOffset == 6)
        #expect(first.nextStartLine == 2)
        #expect(second.content == "z")
        #expect(second.endLine == 2)
    }

    @Test("沙盒分块在极大 cursor 行号下不会整数溢出")
    func testReadTextFileChunkMaximumCursorLineDoesNotOverflow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one\ntwo".utf8).write(to: root.appendingPathComponent("small.txt"))

        let chunk = try SandboxFileToolSupport.readTextFileChunk(
            relativePath: "small.txt",
            startLine: Int.max,
            maxLines: 1,
            byteOffset: 0,
            rootDirectory: root
        )

        #expect(chunk.content == "one")
        #expect(chunk.nextStartLine == Int.max)
    }

    @Test("移动工具可重命名并自动创建目标父目录")
    func testMoveItemRenamesFileAndCreatesParents() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "drafts/todo.txt",
            content: "todo",
            rootDirectory: root
        )

        let result = try SandboxFileToolSupport.moveItem(
            from: "drafts/todo.txt",
            to: "archive/2026/todo-final.txt",
            overwrite: false,
            createIntermediateDirectories: true,
            rootDirectory: root
        )

        let sourceURL = root.appendingPathComponent("drafts/todo.txt")
        let destinationURL = root.appendingPathComponent("archive/2026/todo-final.txt")

        #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path) == true)
        #expect(result.createdParentDirectories == true)
        #expect(result.sourcePath == "Documents/drafts/todo.txt")
        #expect(result.destinationPath == "Documents/archive/2026/todo-final.txt")
    }

    @Test("创建目录工具可新建目录并返回创建状态")
    func testCreateDirectoryBuildsPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try SandboxFileToolSupport.createDirectory(
            relativePath: "workspace/docs/specs",
            createIntermediateDirectories: true,
            rootDirectory: root
        )
        let createdURL = root.appendingPathComponent("workspace/docs/specs", isDirectory: true)

        #expect(result.created == true)
        #expect(result.createdParentDirectories == true)
        #expect(result.path == "Documents/workspace/docs/specs")
        #expect(FileManager.default.fileExists(atPath: createdURL.path))
    }

    @Test("复制工具可复制文件并覆盖目标")
    func testCopyItemCanOverwriteTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "src/config.txt",
            content: "new-value",
            rootDirectory: root
        )
        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "dst/config.txt",
            content: "old-value",
            rootDirectory: root
        )

        let result = try SandboxFileToolSupport.copyItem(
            from: "src/config.txt",
            to: "dst/config.txt",
            overwrite: true,
            rootDirectory: root
        )
        let copied = try SandboxFileToolSupport.readTextFile(
            relativePath: "dst/config.txt",
            rootDirectory: root
        )

        #expect(result.overwroteDestination == true)
        #expect(copied == "new-value")
    }

    @Test("App 复制和移动在修改文件系统前拒绝用源项目覆盖其祖先")
    func testCopyAndMoveRejectDestinationContainingSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("parent/child", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = sourceDirectory.appendingPathComponent("source.txt")
        let siblingFile = root.appendingPathComponent("parent/sibling.txt")
        try Data("source".utf8).write(to: sourceFile)
        try Data("sibling".utf8).write(to: siblingFile)

        #expect(throws: SandboxFileToolError.self) {
            _ = try SandboxFileToolSupport.copyItem(
                from: "parent/child",
                to: "parent",
                overwrite: true,
                rootDirectory: root
            )
        }
        #expect(throws: SandboxFileToolError.self) {
            _ = try SandboxFileToolSupport.moveItem(
                from: "parent/child",
                to: "parent",
                overwrite: true,
                rootDirectory: root
            )
        }

        #expect(String(decoding: try Data(contentsOf: sourceFile), as: UTF8.self) == "source")
        #expect(String(decoding: try Data(contentsOf: siblingFile), as: UTF8.self) == "sibling")
    }

    @Test("App 分段复制中途失败不会触碰既有目标")
    func testStagedCopyFailureKeepsExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.txt")
        let destinationURL = root.appendingPathComponent("destination.txt")
        try Data("new".utf8).write(to: sourceURL)
        try Data("old".utf8).write(to: destinationURL)

        #expect(throws: SandboxFileToolError.self) {
            _ = try SandboxFileToolSupport.copyItemThroughStaging(
                from: sourceURL,
                to: destinationURL,
                destinationExists: true,
                sourceIsDirectory: false
            ) { _, stagingURL in
                try Data("partial".utf8).write(to: stagingURL)
                throw SandboxFileToolError.invalidPath
            }
        }

        #expect(String(decoding: try Data(contentsOf: destinationURL), as: UTF8.self) == "old")
        let remainingItems = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(remainingItems == [
            "destination.txt", "source.txt"
        ])
    }

    @Test("App 原子替换发布中途失败会同时恢复源和既有目标")
    func testAtomicReplacementFailureRestoresBothItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.txt")
        let destinationURL = root.appendingPathComponent("destination.txt")
        try Data("new".utf8).write(to: sourceURL)
        try Data("old".utf8).write(to: destinationURL)

        #expect(throws: SandboxFileToolError.self) {
            _ = try SandboxFileToolSupport.replaceItemKeepingBackup(
                at: destinationURL,
                with: sourceURL
            ) { destination, replacement, backupName in
                let backupURL = destination.deletingLastPathComponent()
                    .appendingPathComponent(backupName)
                try FileManager.default.moveItem(at: destination, to: backupURL)
                try FileManager.default.moveItem(at: replacement, to: destination)
                throw SandboxFileToolError.invalidPath
            }
        }

        #expect(String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self) == "new")
        #expect(String(decoding: try Data(contentsOf: destinationURL), as: UTF8.self) == "old")
    }

    @Test("App 覆盖移动可撤销并恢复源与旧目标")
    func testOverwritingMoveCanRestoreBothItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.txt")
        let destinationURL = root.appendingPathComponent("destination.txt")
        try Data("new".utf8).write(to: sourceURL)
        try Data("old".utf8).write(to: destinationURL)

        let result = try SandboxFileToolSupport.moveItem(
            from: "source.txt",
            to: "destination.txt",
            overwrite: true,
            rootDirectory: root
        )
        #expect(result.overwroteDestination)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(String(decoding: try Data(contentsOf: destinationURL), as: UTF8.self) == "new")

        _ = try SandboxFileToolSupport.undoLastMutation(rootDirectory: root)

        #expect(String(decoding: try Data(contentsOf: sourceURL), as: UTF8.self) == "new")
        #expect(String(decoding: try Data(contentsOf: destinationURL), as: UTF8.self) == "old")
    }

    @Test("Agent 撤销按 Run 和 mutation ID 精确隔离")
    func testAgentUndoDoesNotCrossRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runA = UUID()
        let runB = UUID()
        let mutationA = UUID()
        let mutationB = UUID()

        try SandboxFileToolSupport.$undoContext.withValue(
            .init(runID: runA, mutationID: mutationA)
        ) {
            _ = try SandboxFileToolSupport.writeTextFile(
                relativePath: "a.txt",
                content: "A",
                rootDirectory: root
            )
        }
        try SandboxFileToolSupport.$undoContext.withValue(
            .init(runID: runB, mutationID: mutationB)
        ) {
            _ = try SandboxFileToolSupport.writeTextFile(
                relativePath: "b.txt",
                content: "B",
                rootDirectory: root
            )
        }

        _ = try SandboxFileToolSupport.undoMutation(
            id: mutationA,
            runID: runA,
            rootDirectory: root
        )

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("b.txt").path))
        #expect(SandboxFileToolSupport.hasUndoMutation(id: mutationB, runID: runB))
        SandboxFileToolSupport.discardUndoMutations(runID: runB)
    }

    @Test("Agent 撤销失败会恢复点击撤销前的文件状态")
    func testAgentUndoFailureRollsBackUndoItself() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("state.txt")
        try Data("before-undo".utf8).write(to: fileURL)
        let runID = UUID()
        let mutationID = UUID()

        SandboxFileToolSupport.$undoContext.withValue(.init(runID: runID, mutationID: mutationID)) {
            SandboxFileToolSupport.pushUndoEntry(
                rootDirectory: root,
                operation: "test_partial_undo",
                rollbackURLs: [fileURL]
            ) {
                try Data("partial-undo".utf8).write(to: fileURL, options: .atomic)
                throw SandboxFileToolError.invalidPath
            }
        }

        #expect(throws: SandboxFileToolError.self) {
            _ = try SandboxFileToolSupport.undoMutation(
                id: mutationID,
                runID: runID,
                rootDirectory: root
            )
        }
        let restored = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        #expect(restored == "before-undo")
        #expect(SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: runID))
        SandboxFileToolSupport.discardUndoMutations(runID: runID)
    }

    @Test("TaskLocal 撤销上下文会穿过文件工具后台队列")
    func testUndoContextCrossesSandboxBackgroundQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let mutationID = UUID()

        _ = try await SandboxFileToolSupport.$undoContext.withValue(
            .init(runID: runID, mutationID: mutationID)
        ) {
            try await AppToolManager.runSandboxFileOperationOffMainThread {
                try SandboxFileToolSupport.writeTextFile(
                    relativePath: "background.txt",
                    content: "value",
                    rootDirectory: root
                )
            }
        }

        #expect(SandboxFileToolSupport.hasUndoMutation(id: mutationID, runID: runID))
        SandboxFileToolSupport.discardUndoMutations(runID: runID)
    }

    @Test("批量编辑会按规则替换文本")
    func testBatchReplaceTextAppliesRules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "docs/page.txt",
            content: "title: old\nowner: alice",
            rootDirectory: root
        )

        let result = try SandboxFileToolSupport.batchReplaceText(
            relativePath: "docs/page.txt",
            rules: [
                SandboxBatchEditRule(oldText: "old", newText: "new"),
                SandboxBatchEditRule(oldText: "alice", newText: "bob")
            ],
            replaceAll: false,
            ignoreMissing: false,
            rootDirectory: root
        )
        let updated = try SandboxFileToolSupport.readTextFile(
            relativePath: "docs/page.txt",
            rootDirectory: root
        )

        #expect(result.replacements == 2)
        #expect(result.rulesApplied == 2)
        #expect(updated == "title: new\nowner: bob")
    }

    @Test("撤销会回滚最近一次写入")
    func testUndoLastMutationRevertsWrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "undo/record.txt",
            content: "v1",
            rootDirectory: root
        )
        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "undo/record.txt",
            content: "v2",
            rootDirectory: root
        )

        let undo = try SandboxFileToolSupport.undoLastMutation(rootDirectory: root)
        let restored = try SandboxFileToolSupport.readTextFile(
            relativePath: "undo/record.txt",
            rootDirectory: root
        )

        #expect(undo.operation == "write_sandbox_file")
        #expect(restored == "v1")
    }

    @Test("diff 会输出新增与删除行")
    func testDiffTextFileReturnsUnifiedLikeOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "notes/change.txt",
            content: "A\nB\nC",
            rootDirectory: root
        )

        let diff = try SandboxFileToolSupport.diffTextFile(
            relativePath: "notes/change.txt",
            updatedContent: "A\nX\nC",
            rootDirectory: root
        )

        #expect(diff.contains("--- current"))
        #expect(diff.contains("+++ proposed"))
        #expect(diff.contains("-B"))
        #expect(diff.contains("+X"))
    }

    @Test("局部编辑会替换命中的旧文本")
    func testReplaceTextRewritesMatchedSnippet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "drafts/edit.txt",
            content: "alpha beta gamma",
            rootDirectory: root
        )

        let result = try SandboxFileToolSupport.replaceText(
            relativePath: "drafts/edit.txt",
            oldText: "beta",
            newText: "delta",
            rootDirectory: root
        )
        let updated = try SandboxFileToolSupport.readTextFile(
            relativePath: "drafts/edit.txt",
            rootDirectory: root
        )

        #expect(result.replacements == 1)
        #expect(updated == "alpha delta gamma")
    }

    @Test("删除会移除目标文件")
    func testDeleteItemRemovesFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SandboxFileToolSupport.writeTextFile(
            relativePath: "trash/remove.txt",
            content: "to delete",
            rootDirectory: root
        )

        let result = try SandboxFileToolSupport.deleteItem(
            relativePath: "trash/remove.txt",
            rootDirectory: root
        )
        let targetURL = root.appendingPathComponent("trash/remove.txt")

        #expect(result.path == "Documents/trash/remove.txt")
        #expect(FileManager.default.fileExists(atPath: targetURL.path) == false)
    }
}

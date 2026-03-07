// ============================================================================
// SandboxFileToolSupportTests.swift
// ============================================================================
// SandboxFileToolSupportTests 测试文件
// - 覆盖沙盒路径逃逸拦截
// - 覆盖文本文件读写与目录列表
// ============================================================================

import Testing
import Foundation
@testable import Shared

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

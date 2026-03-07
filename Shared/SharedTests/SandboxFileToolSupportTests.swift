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
}

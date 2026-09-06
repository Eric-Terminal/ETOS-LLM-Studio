// ============================================================================
// ExternalStorageMountTests.swift
// ============================================================================
// 外部挂载在存储文件浏览器中的读写边界测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOS_LLM_Studio_App

struct ExternalStorageMountTests {
    @Test("只读外部挂载关闭文件删除能力")
    func readOnlyMountDisablesDeletion() {
        let directory = URL(fileURLWithPath: "/tmp/external", isDirectory: true)
        let browser = StorageDirectoryBrowserView(
            title: "External",
            rootDirectory: directory,
            currentDirectory: directory,
            emptyTitle: "Empty",
            emptyDescription: "Empty",
            allowsDeletion: false
        )

        #expect(!browser.allowsDeletion)
    }

    @Test("应用内目录仍默认允许文件删除")
    func appDirectoryKeepsDeletionEnabled() {
        let directory = URL(fileURLWithPath: "/tmp/documents", isDirectory: true)
        let browser = StorageDirectoryBrowserView(
            title: "Documents",
            rootDirectory: directory,
            currentDirectory: directory,
            emptyTitle: "Empty",
            emptyDescription: "Empty"
        )

        #expect(browser.allowsDeletion)
    }
}

// ============================================================================
// FileListDetailView.swift
// ============================================================================
// ETOS LLM Studio iOS App - 文件列表详情视图
//
// 功能特性:
// - 按目录层级浏览文件与文件夹
// - 显示文件名、大小、修改时间，并为长文件名提供跑马灯
// - 支持删除单个文件和批量删除
// - 支持文本文件、图片和 SQLite 数据库预览
// ============================================================================

import Foundation
import ETOSCore
import SwiftUI

struct FileListDetailView: View {
    let category: StorageCategory

    private let rootDirectory: URL

    init(category: StorageCategory) {
        self.category = category
        self.rootDirectory = StorageUtility.getDirectory(for: category)
    }

    var body: some View {
        StorageDirectoryBrowserView(
            title: category.displayName,
            rootDirectory: rootDirectory,
            currentDirectory: rootDirectory,
            emptyTitle: "暂无文件",
            emptyDescription: "此类别下没有任何文件。",
            footerText: "点击文件夹继续浏览，点击文件可尝试预览内容。"
        )
    }
}

struct DocumentsStorageBrowserView: View {
    private let rootDirectory = StorageUtility.documentsDirectory

    var body: some View {
        StorageDirectoryBrowserView(
            title: rootDirectory.lastPathComponent,
            rootDirectory: rootDirectory,
            currentDirectory: rootDirectory,
            emptyTitle: NSLocalizedString("暂无文件", comment: ""),
            emptyDescription: NSLocalizedString("此类别下没有任何文件。", comment: ""),
            footerText: NSLocalizedString("点击文件夹继续浏览，点击文件可尝试预览内容。", comment: "")
        )
    }
}

// ============================================================================
// StorageManagementView.swift
// ============================================================================
// ETOS LLM Studio Watch App - 存储管理视图
//
// 功能特性:
// - 显示 Documents 目录的存储使用概览
// - 按类别浏览文件，并支持继续进入子文件夹
// - 支持 JSON 文件分页预览
// - 提供缓存清理功能
// ============================================================================

import SwiftUI
import Shared

public struct StorageManagementView: View {
    @State private var storageBreakdown = StorageBreakdown()
    @State private var isLoading = true
    @State private var showClearCacheConfirmation = false
    @State private var showCleanAllOrphansConfirmation = false
    @State private var orphanedDataCount = StorageUtility.OrphanedDataCount()
    @State private var cleanupAlert: CleanupAlert?

    struct CleanupAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    public init() {}

    public var body: some View {
        List {
            storageOverviewSection
            storageCategoriesSection
            cleanupToolsSection
        }
        .navigationTitle("存储管理")
        .task {
            await refreshData()
        }
        .confirmationDialog(
            "清理缓存",
            isPresented: $showClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) {
                performCacheCleanup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有语音和图片缓存文件。")
        }
        .confirmationDialog(
            "确认清理孤立数据",
            isPresented: $showCleanAllOrphansConfirmation,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) {
                performAllOrphanCleanup()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理：\(orphanedDataCount.description)。\n\n此操作不可撤销。")
        }
        .alert(item: $cleanupAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好的"))
            )
        }
    }

    private var storageOverviewSection: some View {
        Section {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "internaldrive")
                        .font(.title2)
                        .foregroundStyle(.blue)

                    Text(StorageUtility.formatSize(storageBreakdown.totalSize))
                        .font(.headline)

                    Text("总使用空间")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private var storageCategoriesSection: some View {
        Section("存储分类") {
            ForEach(StorageCategory.allCases) { category in
                NavigationLink {
                    WatchFileListView(category: category)
                } label: {
                    HStack {
                        Image(systemName: category.systemImage)
                            .foregroundStyle(category.iconColor)
                            .frame(width: 20)

                        Text(category.displayName)
                            .font(.footnote)

                        Spacer()

                        Text(StorageUtility.formatSize(storageBreakdown.categorySize[category] ?? 0))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var cleanupToolsSection: some View {
        Section {
            Button {
                checkAllOrphanedData()
            } label: {
                HStack {
                    Image(systemName: "trash.slash")
                        .foregroundStyle(.orange)
                    Text("清理孤立数据")
                        .font(.footnote)
                    Spacer()
                    if orphanedDataCount.total > 0 {
                        Text(String(format: NSLocalizedString("%d 项", comment: ""), orphanedDataCount.total))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("清理所有缓存")
                        .font(.footnote)
                }
            }
        } header: {
            Text("清理工具")
        } footer: {
            Text("孤立数据包括幽灵会话、孤立音频/图片、无效音频引用。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshData() async {
        isLoading = true

        let breakdown = await Task.detached(priority: .userInitiated) {
            StorageUtility.getStorageBreakdown()
        }.value

        let orphanedCount = await Task.detached(priority: .userInitiated) {
            StorageUtility.countAllOrphanedData()
        }.value

        await MainActor.run {
            storageBreakdown = breakdown
            orphanedDataCount = orphanedCount
            isLoading = false
        }
    }

    private func checkAllOrphanedData() {
        if orphanedDataCount.total > 0 {
            showCleanAllOrphansConfirmation = true
        } else {
            cleanupAlert = CleanupAlert(
                title: "无孤立数据",
                message: "当前没有需要清理的孤立数据。"
            )
        }
    }

    private func performAllOrphanCleanup() {
        Task {
            let summary = await Task.detached(priority: .userInitiated) {
                StorageUtility.cleanupAllOrphans()
            }.value

            await MainActor.run {
                cleanupAlert = CleanupAlert(
                    title: "清理完成",
                    message: "已清理：\(summary.description)"
                )
            }

            await refreshData()
        }
    }

    private func performCacheCleanup() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                StorageUtility.clearCacheFiles()
            }.value

            await MainActor.run {
                cleanupAlert = CleanupAlert(
                    title: "清理完成",
                    message: String(format: NSLocalizedString("已删除 %d 个文件。", comment: ""), result.audioDeleted + result.imageDeleted)
                )
            }

            await refreshData()
        }
    }
}

public struct WatchFileListView: View {
    let category: StorageCategory

    private let rootDirectory: URL
    private let currentDirectory: URL

    @State private var files: [FileItem] = []
    @State private var isLoading = true
    @State private var fileToDelete: FileItem?
    @State private var showDeleteConfirmation = false

    public init(category: StorageCategory, directoryURL: URL? = nil) {
        self.category = category
        let root = StorageUtility.getDirectory(for: category)
        self.rootDirectory = root
        self.currentDirectory = directoryURL ?? root
    }

    private var relativePath: String {
        StorageBrowserSupport.relativeDisplayPath(for: currentDirectory, rootDirectory: rootDirectory)
    }

    private var folderCount: Int {
        files.filter(\.isDirectory).count
    }

    private var fileCount: Int {
        files.count - folderCount
    }

    private var totalFileSize: Int64 {
        files.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
    }

    public var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无内容")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                fileListView
            }
        }
        .navigationTitle(currentDirectory == rootDirectory ? category.displayName : currentDirectory.lastPathComponent)
        .task {
            await loadFiles()
        }
        .confirmationDialog(
            "删除项目",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let file = fileToDelete {
                Text(String(format: NSLocalizedString("删除 \"%@\"？", comment: ""), file.name))
            }
        }
    }

    private var fileListView: some View {
        List {
            Section("当前位置") {
                Text(relativePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Section("统计") {
                infoRow(title: "文件夹", value: "\(folderCount)")
                infoRow(title: "文件", value: "\(fileCount)")
                infoRow(title: "总大小", value: StorageUtility.formatSize(totalFileSize))
            }

            Section {
                ForEach(files) { file in
                    row(for: file)
                }
            } header: {
                Text("内容")
            } footer: {
                Text("点击文件夹继续浏览，点击 JSON 文件打开分页阅读。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(for file: FileItem) -> some View {
        if file.isDirectory {
            NavigationLink {
                WatchFileListView(category: category, directoryURL: file.url)
            } label: {
                WatchFileRow(file: file)
            }
            .swipeActions(edge: .trailing) {
                deleteAction(for: file)
            }
        } else if StorageBrowserSupport.isJSONFile(file.url) {
            NavigationLink {
                WatchJSONPreviewView(file: file)
            } label: {
                WatchFileRow(file: file)
            }
            .swipeActions(edge: .trailing) {
                deleteAction(for: file)
            }
        } else {
            WatchFileRow(file: file)
                .swipeActions(edge: .trailing) {
                    deleteAction(for: file)
                }
        }
    }

    private func deleteAction(for file: FileItem) -> some View {
        Button(role: .destructive) {
            fileToDelete = file
            showDeleteConfirmation = true
        } label: {
            Image(systemName: "trash")
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote)
            Spacer()
            Text(value)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func loadFiles() async {
        isLoading = true

        let directory = currentDirectory
        let loadedFiles = await Task.detached(priority: .userInitiated) {
            StorageUtility.listFiles(in: directory)
        }.value

        await MainActor.run {
            files = loadedFiles
            isLoading = false
        }
    }

    private func deleteFile(_ file: FileItem) {
        Task {
            do {
                try StorageUtility.deleteFile(at: file.url)
                await MainActor.run {
                    files.removeAll { $0.id == file.id }
                }
            } catch {
                // 当前界面暂不展示额外错误提示，保持与现有交互一致。
            }
        }
    }
}

private struct WatchFileRow: View {
    let file: FileItem

    private var subtitle: String {
        let date = file.modificationDate.formatted(date: .abbreviated, time: .omitted)
        if file.isDirectory {
            return "文件夹 • \(date)"
        }
        return "\(StorageUtility.formatSize(file.size)) • \(date)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                MarqueeText(
                    content: file.name,
                    uiFont: .preferredFont(forTextStyle: .footnote),
                    speed: 28,
                    delay: 0.8,
                    spacing: 24
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if file.isDirectory {
            return "folder.fill"
        }
        switch file.url.pathExtension.lowercased() {
        case "json":
            return "doc.text"
        case "m4a", "mp3", "wav", "aac":
            return "waveform"
        case "jpg", "jpeg", "png", "gif", "webp", "heic":
            return "photo"
        default:
            return "doc"
        }
    }

    private var iconColor: Color {
        if file.isDirectory {
            return .blue
        }
        switch file.url.pathExtension.lowercased() {
        case "json":
            return .orange
        case "m4a", "mp3", "wav", "aac":
            return .purple
        case "jpg", "jpeg", "png", "gif", "webp", "heic":
            return .green
        default:
            return .secondary
        }
    }
}

private struct WatchJSONPreviewView: View {
    let file: FileItem

    @State private var pages: [StorageTextPage] = []
    @State private var isLoading = true
    @State private var selectedPageIndex = 0

    private var currentPage: StorageTextPage? {
        guard pages.indices.contains(selectedPageIndex) else { return nil }
        return pages[selectedPageIndex]
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let currentPage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryCard(for: currentPage)
                        if pages.count > 1 {
                            pageControls
                        }

                        Text(currentPage.content)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            )

                        if pages.count > 1 {
                            pageControls
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("无法预览")
                        .font(.footnote)
                    Text("无法读取此 JSON 文件。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(file.name)
        .task {
            await loadPages()
        }
    }

    private func summaryCard(for page: StorageTextPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("第 \(page.index + 1) / \(page.totalCount) 页")
                .font(.footnote.weight(.semibold))
            Text("第 \(page.startLineNumber)-\(page.endLineNumber) 行")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var pageControls: some View {
        HStack(spacing: 8) {
            Button("上一页") {
                selectedPageIndex = max(selectedPageIndex - 1, 0)
            }
            .disabled(selectedPageIndex == 0)

            Button("下一页") {
                selectedPageIndex = min(selectedPageIndex + 1, max(0, pages.count - 1))
            }
            .disabled(selectedPageIndex >= pages.count - 1)
        }
        .font(.caption2)
    }

    private func loadPages() async {
        isLoading = true

        let fileURL = file.url
        let loadedPages = await Task.detached(priority: .userInitiated) {
            guard let content = StorageUtility.readJSONFile(at: fileURL) else {
                return [StorageTextPage]()
            }
            return StorageBrowserSupport.paginateText(content, linesPerPage: 100)
        }.value

        await MainActor.run {
            pages = loadedPages
            selectedPageIndex = 0
            isLoading = false
        }
    }
}

#Preview {
    NavigationStack {
        StorageManagementView()
    }
}

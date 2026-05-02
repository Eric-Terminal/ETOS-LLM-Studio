// ============================================================================
// StorageManagementView.swift
// ============================================================================
// ETOS LLM Studio Watch App - 存储管理视图
//
// 功能特性:
// - 显示 Documents 目录的存储使用概览
// - 按类别浏览文件，并支持继续进入子文件夹
// - 支持 JSON 文件分页预览、图片预览和 SQLite 数据库查询
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
        .navigationTitle(NSLocalizedString("存储管理", comment: ""))
        .task {
            await refreshData()
        }
        .confirmationDialog(NSLocalizedString("清理缓存", comment: ""),
            isPresented: $showClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清理", comment: ""), role: .destructive) {
                performCacheCleanup()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("将删除所有语音和图片缓存文件。", comment: ""))
        }
        .confirmationDialog(NSLocalizedString("确认清理孤立数据", comment: ""),
            isPresented: $showCleanAllOrphansConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清理", comment: ""), role: .destructive) {
                performAllOrphanCleanup()
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(String(format: NSLocalizedString("将清理：%@。\n\n此操作不可撤销。", comment: ""), orphanedDataCount.description))
        }
        .alert(item: $cleanupAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(NSLocalizedString("好的", comment: "")))
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
                        .etFont(.title2)
                        .foregroundStyle(.blue)

                    Text(StorageUtility.formatSize(storageBreakdown.totalSize))
                        .etFont(.headline)

                    Text(NSLocalizedString("总使用空间", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private var storageCategoriesSection: some View {
        Section(NSLocalizedString("存储分类", comment: "")) {
            NavigationLink {
                DocumentsStorageBrowserView()
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.blue)
                        .frame(width: 20)

                    Text(StorageUtility.documentsDirectory.lastPathComponent)
                        .etFont(.footnote)

                    Spacer()

                    Text(StorageUtility.formatSize(storageBreakdown.totalSize))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(StorageCategory.allCases) { category in
                NavigationLink {
                    WatchFileListView(category: category)
                } label: {
                    HStack {
                        Image(systemName: category.systemImage)
                            .foregroundStyle(category.iconColor)
                            .frame(width: 20)

                        Text(category.displayName)
                            .etFont(.footnote)

                        Spacer()

                        Text(StorageUtility.formatSize(storageBreakdown.categorySize[category] ?? 0))
                            .etFont(.caption2)
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
                    Text(NSLocalizedString("清理孤立数据", comment: ""))
                        .etFont(.footnote)
                    Spacer()
                    if orphanedDataCount.total > 0 {
                        Text(String(format: NSLocalizedString("%d 项", comment: ""), orphanedDataCount.total))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button(role: .destructive) {
                showClearCacheConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text(NSLocalizedString("清理所有缓存", comment: ""))
                        .etFont(.footnote)
                    Spacer()
                    Text(StorageUtility.formatSize(storageBreakdown.cacheSize))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(NSLocalizedString("清理工具", comment: ""))
        } footer: {
            Text(NSLocalizedString("孤立数据包括幽灵会话、孤立音频/图片、无效音频引用。", comment: ""))
                .etFont(.caption2)
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
                title: NSLocalizedString("无孤立数据", comment: ""),
                message: NSLocalizedString("当前没有需要清理的孤立数据。", comment: "")
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
                    title: NSLocalizedString("清理完成", comment: ""),
                    message: String(format: NSLocalizedString("已清理：%@", comment: ""), summary.description)
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
                    title: NSLocalizedString("清理完成", comment: ""),
                    message: String(format: NSLocalizedString("已删除 %d 个文件。", comment: ""), result.audioDeleted + result.imageDeleted)
                )
            }

            await refreshData()
        }
    }
}

struct DocumentsStorageBrowserView: View {
    private let rootDirectory = StorageUtility.documentsDirectory

    var body: some View {
        WatchFileListView(
            category: .sessions,
            directoryURL: rootDirectory,
            rootDirectory: rootDirectory,
            title: rootDirectory.lastPathComponent
        )
    }
}

public struct WatchFileListView: View {
    let category: StorageCategory

    private let rootDirectory: URL
    private let currentDirectory: URL
    private let titleOverride: String?

    @State private var files: [FileItem] = []
    @State private var isLoading = true
    @State private var fileToDelete: FileItem?
    @State private var showDeleteConfirmation = false

    public init(
        category: StorageCategory,
        directoryURL: URL? = nil,
        rootDirectory: URL? = nil,
        title: String? = nil
    ) {
        self.category = category
        let root = rootDirectory ?? StorageUtility.getDirectory(for: category)
        self.rootDirectory = root
        self.currentDirectory = directoryURL ?? root
        self.titleOverride = title
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
                        .etFont(.title2)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("暂无内容", comment: ""))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                fileListView
            }
        }
        .navigationTitle(currentDirectory == rootDirectory ? (titleOverride ?? category.displayName) : currentDirectory.lastPathComponent)
        .task {
            await loadFiles()
        }
        .confirmationDialog(NSLocalizedString("删除项目", comment: ""),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            if let file = fileToDelete {
                Text(String(format: NSLocalizedString("删除 \"%@\"？", comment: ""), file.name))
            }
        }
    }

    private var fileListView: some View {
        List {
            Section(NSLocalizedString("当前位置", comment: "")) {
                Text(relativePath)
                    .etFont(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("统计", comment: "")) {
                infoRow(title: NSLocalizedString("文件夹", comment: ""), value: "\(folderCount)")
                infoRow(title: NSLocalizedString("文件", comment: ""), value: "\(fileCount)")
                infoRow(title: NSLocalizedString("总大小", comment: ""), value: StorageUtility.formatSize(totalFileSize))
            }

            Section {
                ForEach(files) { file in
                    row(for: file)
                }
            } header: {
                Text(NSLocalizedString("内容", comment: ""))
            } footer: {
                Text(NSLocalizedString("点击文件夹继续浏览，点击 JSON 文件打开分页阅读。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(for file: FileItem) -> some View {
        if file.isDirectory {
            NavigationLink {
                WatchFileListView(
                    category: category,
                    directoryURL: file.url,
                    rootDirectory: rootDirectory,
                    title: titleOverride
                )
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
        } else if StorageBrowserSupport.isImageFile(file.url) {
            NavigationLink {
                WatchImagePreviewView(file: file)
            } label: {
                WatchFileRow(file: file)
            }
            .swipeActions(edge: .trailing) {
                deleteAction(for: file)
            }
        } else if StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
            NavigationLink {
                WatchSQLitePreviewView(file: file)
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
            Text(NSLocalizedString(title, comment: "存储信息行标题"))
                .etFont(.footnote)
            Spacer()
            Text(value)
                .etFont(.caption2)
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

private struct WatchImagePreviewView: View {
    let file: FileItem

    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let image {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("文件名", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            Text(file.name)
                                .etFont(.footnote)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .etFont(.title3)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("无法预览", comment: ""))
                        .etFont(.footnote)
                    Text(NSLocalizedString("无法读取图片数据。", comment: ""))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("图片预览", comment: ""))
        .task {
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: file.url.path)
            }.value
            isLoading = false
        }
    }
}

private struct WatchSQLitePreviewView: View {
    let file: FileItem

    @State private var tables: [StorageSQLiteTableInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "cylinder.split.1x2")
                        .etFont(.title3)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("无法预览", comment: ""))
                        .etFont(.footnote)
                    Text(errorMessage)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                List {
                    Section(NSLocalizedString("文件", comment: "")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name)
                                .etFont(.footnote)
                            Text(StorageUtility.formatSize(file.size))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section(NSLocalizedString("查询", comment: "")) {
                        NavigationLink {
                            WatchSQLiteQueryView(databaseURL: file.url)
                        } label: {
                            Label(NSLocalizedString("查询数据库", comment: "Query SQLite database"), systemImage: "magnifyingglass")
                        }
                    }

                    Section(NSLocalizedString("表", comment: "SQLite tables")) {
                        if tables.isEmpty {
                            Text(NSLocalizedString("暂无内容", comment: ""))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(tables) { table in
                                NavigationLink {
                                    WatchSQLiteTableDataView(databaseURL: file.url, table: table)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(table.name)
                                            .etFont(.footnote.weight(.semibold))
                                        Text(String(format: NSLocalizedString("%d 个字段", comment: "SQLite column count"), table.columns.count))
                                            .etFont(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("数据库预览", comment: "SQLite database preview"))
        .task {
            await loadTables()
        }
    }

    private func loadTables() async {
        isLoading = true
        let databaseURL = file.url
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try StorageBrowserSupport.listSQLiteTables(at: databaseURL)
            }
        }.value

        await MainActor.run {
            switch result {
            case .success(let loadedTables):
                tables = loadedTables
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct WatchSQLiteTableDataView: View {
    let databaseURL: URL
    let table: StorageSQLiteTableInfo

    @State private var page: StorageSQLiteQueryPage?
    @State private var pageIndex = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let pageSize = 20

    var body: some View {
        WatchSQLiteRowsView(
            title: table.name,
            page: page,
            isLoading: isLoading,
            errorMessage: errorMessage,
            canGoBack: pageIndex > 0,
            canGoForward: page?.hasNextPage == true,
            onPrevious: {
                pageIndex = max(0, pageIndex - 1)
                Task { await loadPage() }
            },
            onNext: {
                pageIndex += 1
                Task { await loadPage() }
            }
        )
        .task {
            await loadPage()
        }
    }

    private func loadPage() async {
        isLoading = true
        let databaseURL = databaseURL
        let tableName = table.name
        let pageIndex = pageIndex
        let pageSize = pageSize
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try StorageBrowserSupport.querySQLiteTablePage(
                    at: databaseURL,
                    tableName: tableName,
                    pageIndex: pageIndex,
                    pageSize: pageSize
                )
            }
        }.value

        await MainActor.run {
            switch result {
            case .success(let loadedPage):
                page = loadedPage
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct WatchSQLiteQueryView: View {
    let databaseURL: URL

    @State private var sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')"
    @State private var page: StorageSQLiteQueryPage?
    @State private var pageIndex = 0
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let pageSize = 20

    var body: some View {
        WatchSQLiteRowsView(
            title: NSLocalizedString("查询数据库", comment: "Query SQLite database"),
            page: page,
            isLoading: isLoading,
            errorMessage: errorMessage,
            canGoBack: pageIndex > 0,
            canGoForward: page?.hasNextPage == true,
            onPrevious: {
                pageIndex = max(0, pageIndex - 1)
                Task { await executeQuery() }
            },
            onNext: {
                pageIndex += 1
                Task { await executeQuery() }
            },
            header: {
                Section(NSLocalizedString("SQL", comment: "SQLite SQL input section")) {
                    TextField(
                        NSLocalizedString("只读 SQL", comment: "Read-only SQL placeholder"),
                        text: $sql.watchKeyboardNewlineBinding(),
                        axis: .vertical
                    )
                    .etFont(.system(size: 10, design: .monospaced))

                    Button {
                        pageIndex = 0
                        Task { await executeQuery() }
                    } label: {
                        Label(NSLocalizedString("执行查询", comment: "Run SQLite query"), systemImage: "play")
                    }
                    .disabled(sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
            }
        )
        .task {
            if page == nil && errorMessage == nil {
                await executeQuery()
            }
        }
    }

    private func executeQuery() async {
        isLoading = true
        let databaseURL = databaseURL
        let sql = sql
        let pageIndex = pageIndex
        let pageSize = pageSize
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try StorageBrowserSupport.querySQLitePage(
                    at: databaseURL,
                    sql: sql,
                    pageIndex: pageIndex,
                    pageSize: pageSize
                )
            }
        }.value

        await MainActor.run {
            switch result {
            case .success(let loadedPage):
                page = loadedPage
                errorMessage = nil
            case .failure(let error):
                page = nil
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct WatchSQLiteRowsView<Header: View>: View {
    let title: String
    let page: StorageSQLiteQueryPage?
    let isLoading: Bool
    let errorMessage: String?
    let canGoBack: Bool
    let canGoForward: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let header: () -> Header

    var body: some View {
        List {
            header()

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .etFont(.caption2)
                    .foregroundStyle(.orange)
            } else if let page {
                Section(NSLocalizedString("统计", comment: "")) {
                    infoRow(title: NSLocalizedString("当前页", comment: "SQLite current page"), value: "\(page.pageIndex + 1)")
                    infoRow(title: NSLocalizedString("行", comment: "SQLite row count"), value: "\(page.rows.count)")
                    infoRow(title: NSLocalizedString("字段", comment: "SQLite column count label"), value: "\(page.columns.count)")
                }

                Section {
                    HStack(spacing: 8) {
                        Button(NSLocalizedString("上一页", comment: "")) {
                            onPrevious()
                        }
                        .disabled(!canGoBack || isLoading)

                        Button(NSLocalizedString("下一页", comment: "")) {
                            onNext()
                        }
                        .disabled(!canGoForward || isLoading)
                    }
                    .etFont(.caption2)
                }

                Section(NSLocalizedString("内容", comment: "")) {
                    if page.rows.isEmpty {
                        Text(NSLocalizedString("暂无内容", comment: ""))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(page.rows) { row in
                            WatchSQLiteRowCard(row: row)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .etFont(.footnote)
            Spacer()
            Text(value)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private extension WatchSQLiteRowsView where Header == EmptyView {
    init(
        title: String,
        page: StorageSQLiteQueryPage?,
        isLoading: Bool,
        errorMessage: String?,
        canGoBack: Bool,
        canGoForward: Bool,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) {
        self.title = title
        self.page = page
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.header = { EmptyView() }
    }
}

private struct WatchSQLiteRowCard: View {
    let row: StorageSQLiteRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("#\(row.index + 1)")
                .etFont(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(row.cells) { cell in
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.column)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    Text(cell.value)
                        .etFont(.system(size: 10, design: .monospaced))
                        .lineLimit(6)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WatchFileRow: View {
    let file: FileItem

    private var subtitle: String {
        let date = file.modificationDate.formatted(date: .abbreviated, time: .omitted)
        if file.isDirectory {
            return String(format: NSLocalizedString("文件夹 • %@", comment: ""), date)
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
                    .etFont(.caption2)
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
        if StorageBrowserSupport.isImageFile(file.url) {
            return "photo"
        }
        if StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
            return "cylinder.split.1x2"
        }
        switch file.url.pathExtension.lowercased() {
        case "json":
            return "doc.text"
        case "m4a", "mp3", "wav", "aac":
            return "waveform"
        default:
            return "doc"
        }
    }

    private var iconColor: Color {
        if file.isDirectory {
            return .blue
        }
        if StorageBrowserSupport.isImageFile(file.url) {
            return .green
        }
        if StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
            return .indigo
        }
        switch file.url.pathExtension.lowercased() {
        case "json":
            return .orange
        case "m4a", "mp3", "wav", "aac":
            return .purple
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
                            .etFont(.system(size: 10, design: .monospaced))
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
                        .etFont(.title3)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("无法预览", comment: ""))
                        .etFont(.footnote)
                    Text(NSLocalizedString("无法读取此 JSON 文件。", comment: ""))
                        .etFont(.caption2)
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
            Text(String(format: NSLocalizedString("第 %d / %d 页", comment: ""), page.index + 1, page.totalCount))
                .etFont(.footnote.weight(.semibold))
            Text(String(format: NSLocalizedString("第 %d-%d 行", comment: ""), page.startLineNumber, page.endLineNumber))
                .etFont(.caption2)
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
            Button(NSLocalizedString("上一页", comment: "")) {
                selectedPageIndex = max(selectedPageIndex - 1, 0)
            }
            .disabled(selectedPageIndex == 0)

            Button(NSLocalizedString("下一页", comment: "")) {
                selectedPageIndex = min(selectedPageIndex + 1, max(0, pages.count - 1))
            }
            .disabled(selectedPageIndex >= pages.count - 1)
        }
        .etFont(.caption2)
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

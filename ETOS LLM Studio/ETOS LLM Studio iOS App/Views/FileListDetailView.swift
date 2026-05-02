// ============================================================================
// FileListDetailView.swift
// ============================================================================
// ETOS LLM Studio iOS App - 文件列表详情视图
//
// 功能特性:
// - 按目录层级浏览文件与文件夹
// - 显示文件名、大小、修改时间，并为长文件名提供跑马灯
// - 支持删除单个文件和批量删除
// - 支持 JSON 文件、图片和 SQLite 数据库预览
// ============================================================================

import SwiftUI
import UIKit
import Shared

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
            footerText: "点击文件夹继续浏览，点击 JSON 文件可预览内容。"
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
            footerText: NSLocalizedString("点击文件夹继续浏览，点击 JSON 文件可预览内容。", comment: "")
        )
    }
}

private struct StorageDirectoryBrowserView: View {
    let title: String
    let rootDirectory: URL
    let currentDirectory: URL
    let emptyTitle: String
    let emptyDescription: String
    let footerText: String?
    let itemFilter: (FileItem) -> Bool

    @State private var files: [FileItem] = []
    @State private var isLoading = true
    @State private var selectedFiles = Set<String>()
    @State private var isEditing = false
    @State private var showDeleteAlert = false
    @State private var fileToDelete: FileItem?
    @State private var showBatchDeleteAlert = false
    @State private var previewingFile: FileItem?

    init(
        title: String,
        rootDirectory: URL,
        currentDirectory: URL,
        emptyTitle: String,
        emptyDescription: String,
        footerText: String? = nil,
        itemFilter: @escaping (FileItem) -> Bool = { _ in true }
    ) {
        self.title = title
        self.rootDirectory = rootDirectory
        self.currentDirectory = currentDirectory
        self.emptyTitle = emptyTitle
        self.emptyDescription = emptyDescription
        self.footerText = footerText
        self.itemFilter = itemFilter
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

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString(emptyTitle, comment: "文件列表空状态标题"),
                    systemImage: "folder",
                    description: Text(NSLocalizedString(emptyDescription, comment: "文件列表空状态说明"))
                )
            } else {
                fileListView
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !files.isEmpty {
                    Button(isEditing ? NSLocalizedString("完成", comment: "") : NSLocalizedString("编辑", comment: "")) {
                        withAnimation {
                            isEditing.toggle()
                            if !isEditing {
                                selectedFiles.removeAll()
                            }
                        }
                    }
                }
            }
        }
        .task {
            await loadFiles()
        }
        .refreshable {
            await loadFiles()
        }
        .alert(NSLocalizedString("删除文件", comment: ""), isPresented: $showDeleteAlert) {
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                if let file = fileToDelete {
                    deleteFile(file)
                }
            }
        } message: {
            if let file = fileToDelete {
                Text(String(format: NSLocalizedString("确定要删除 \"%@\" 吗？此操作不可撤销。", comment: ""), file.name))
            }
        }
        .alert(NSLocalizedString("批量删除", comment: ""), isPresented: $showBatchDeleteAlert) {
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            Button(String(format: NSLocalizedString("删除 %d 个项目", comment: ""), selectedFiles.count), role: .destructive) {
                deleteSelectedFiles()
            }
        } message: {
            Text(String(format: NSLocalizedString("确定要删除选中的 %d 个项目吗？此操作不可撤销。", comment: ""), selectedFiles.count))
        }
        .sheet(item: $previewingFile) { file in
            if StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
                SQLitePreviewSheet(file: file)
            } else if StorageBrowserSupport.isImageFile(file.url) {
                ImagePreviewSheet(file: file)
            } else {
                FilePreviewSheet(file: file)
            }
        }
    }

    private var fileListView: some View {
        List(selection: $selectedFiles) {
            Section(NSLocalizedString("当前位置", comment: "")) {
                Text(relativePath)
                    .etFont(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("统计", comment: "")) {
                infoRow(title: NSLocalizedString("文件夹", comment: ""), value: "\(folderCount)")
                infoRow(title: NSLocalizedString("文件", comment: ""), value: "\(fileCount)")
                infoRow(title: NSLocalizedString("可见项目", comment: ""), value: "\(files.count)")
                infoRow(title: NSLocalizedString("文件总大小", comment: ""), value: StorageUtility.formatSize(totalFileSize))
            }

            Section {
                ForEach(files) { file in
                    row(for: file)
                }
            } header: {
                Text(NSLocalizedString("内容", comment: ""))
            } footer: {
                if let footerText {
                    Text(NSLocalizedString(footerText, comment: "文件列表底部说明"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .safeAreaInset(edge: .bottom) {
            if isEditing && !selectedFiles.isEmpty {
                batchDeleteButton
            }
        }
    }

    private var batchDeleteButton: some View {
        Button(role: .destructive) {
            showBatchDeleteAlert = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text(String(format: NSLocalizedString("删除 %d 个项目", comment: ""), selectedFiles.count))
            }
            .etFont(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.red)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func row(for file: FileItem) -> some View {
        if isEditing {
            FileRowView(file: file, isEditing: true, isSelected: selectedFiles.contains(file.id))
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(file)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    deleteAction(for: file)
                }
        } else if file.isDirectory {
            NavigationLink {
                StorageDirectoryBrowserView(
                    title: file.name,
                    rootDirectory: rootDirectory,
                    currentDirectory: file.url,
                    emptyTitle: "空文件夹",
                    emptyDescription: "这个文件夹里还没有内容。",
                    footerText: footerText,
                    itemFilter: itemFilter
                )
            } label: {
                FileRowView(file: file, isEditing: false, isSelected: false)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteAction(for: file)
            }
        } else if StorageBrowserSupport.isJSONFile(file.url) {
            Button {
                previewingFile = file
            } label: {
                FileRowView(file: file, isEditing: false, isSelected: false)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteAction(for: file)
            }
        } else if StorageBrowserSupport.isImageFile(file.url) || StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
            Button {
                previewingFile = file
            } label: {
                FileRowView(file: file, isEditing: false, isSelected: false)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteAction(for: file)
            }
        } else {
            FileRowView(file: file, isEditing: false, isSelected: false)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    deleteAction(for: file)
                }
        }
    }

    private func deleteAction(for file: FileItem) -> some View {
        Button(role: .destructive) {
            fileToDelete = file
            showDeleteAlert = true
        } label: {
            Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(NSLocalizedString(title, comment: "文件列表统计标题"))
            Spacer()
            Text(value)
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
            files = loadedFiles.filter(itemFilter)
            isLoading = false
        }
    }

    private func toggleSelection(_ file: FileItem) {
        if selectedFiles.contains(file.id) {
            selectedFiles.remove(file.id)
        } else {
            selectedFiles.insert(file.id)
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
                // 当前界面暂不展示额外错误提示，保持与现有存储管理交互一致。
            }
        }
    }

    private func deleteSelectedFiles() {
        Task {
            let urlsToDelete = files.filter { selectedFiles.contains($0.id) }.map(\.url)
            _ = StorageUtility.deleteFiles(urlsToDelete)

            await MainActor.run {
                files.removeAll { selectedFiles.contains($0.id) }
                selectedFiles.removeAll()
                isEditing = false
            }
        }
    }
}

private struct FileRowView: View {
    let file: FileItem
    let isEditing: Bool
    let isSelected: Bool

    private var subtitle: String {
        let date = file.modificationDate.formatted(date: .abbreviated, time: .shortened)
        if file.isDirectory {
            return String(format: NSLocalizedString("文件夹 • %@", comment: ""), date)
        }
        return "\(StorageUtility.formatSize(file.size)) • \(date)"
    }

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .etFont(.title3)
            }

            fileIcon

            MarqueeTitleSubtitleLabel(
                title: file.name,
                subtitle: subtitle,
                titleUIFont: .preferredFont(forTextStyle: .subheadline),
                subtitleUIFont: .preferredFont(forTextStyle: .caption1),
                subtitleColor: .secondary,
                spacing: 4
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .etFont(.caption)
                    .foregroundStyle(.tertiary)
            } else if (StorageBrowserSupport.isJSONFile(file.url) || StorageBrowserSupport.isImageFile(file.url) || StorageBrowserSupport.isSQLiteDatabaseFile(file.url)) && !isEditing {
                Image(systemName: "eye")
                    .etFont(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var fileIcon: some View {
        let (icon, color) = fileIconInfo

        return Image(systemName: icon)
            .etFont(.system(size: 16))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fileIconInfo: (String, Color) {
        if file.isDirectory {
            return ("folder.fill", .blue)
        }
        if StorageBrowserSupport.isImageFile(file.url) {
            return ("photo", .green)
        }
        if StorageBrowserSupport.isSQLiteDatabaseFile(file.url) {
            return ("cylinder.split.1x2", .indigo)
        }

        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "json":
            return ("doc.text", .orange)
        case "m4a", "mp3", "wav", "aac":
            return ("waveform", .purple)
        case "pdf":
            return ("doc.richtext", .red)
        default:
            return ("doc", .gray)
        }
    }
}

private struct FilePreviewSheet: View {
    let file: FileItem

    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var isLoading = true

    private var lineCount: Int {
        guard let content else { return 0 }
        return StorageBrowserSupport.paginateText(content, linesPerPage: Int.max).first?.endLineNumber ?? 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(NSLocalizedString("文件名", comment: ""))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text(file.name)
                                    .etFont(.footnote.monospaced())

                                Text(NSLocalizedString("总行数", comment: ""))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(lineCount)")
                                    .etFont(.footnote.monospaced())
                            }

                            Text(content)
                                .etFont(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(NSLocalizedString("无法预览", comment: ""),
                        systemImage: "doc.questionmark",
                        description: Text(NSLocalizedString("无法读取此文件的内容。", comment: ""))
                    )
                }
            }
            .navigationTitle(NSLocalizedString("JSON 预览", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
        .task {
            content = StorageUtility.readJSONFile(at: file.url)
            isLoading = false
        }
    }
}

private struct ImagePreviewSheet: View {
    let file: FileItem

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(NSLocalizedString("文件名", comment: ""))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text(file.name)
                                    .etFont(.footnote.monospaced())
                            }
                        }
                        .padding()
                    }
                } else {
                    ContentUnavailableView(
                        NSLocalizedString("无法预览", comment: ""),
                        systemImage: "photo",
                        description: Text(NSLocalizedString("无法读取图片数据。", comment: ""))
                    )
                }
            }
            .navigationTitle(NSLocalizedString("图片预览", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
        .task {
            let filePath = file.url.path
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: filePath)
            }.value
            isLoading = false
        }
    }
}

private struct SQLitePreviewSheet: View {
    let file: FileItem

    @Environment(\.dismiss) private var dismiss
    @State private var tables: [StorageSQLiteTableInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        NSLocalizedString("无法预览", comment: ""),
                        systemImage: "cylinder.split.1x2",
                        description: Text(errorMessage)
                    )
                } else {
                    List {
                        Section(NSLocalizedString("文件", comment: "")) {
                            infoRow(title: NSLocalizedString("文件名", comment: ""), value: file.name)
                            infoRow(title: NSLocalizedString("文件总大小", comment: ""), value: StorageUtility.formatSize(file.size))
                        }

                        Section(NSLocalizedString("查询", comment: "")) {
                            NavigationLink {
                                SQLiteQueryView(databaseURL: file.url, title: file.name)
                            } label: {
                                Label(NSLocalizedString("查询数据库", comment: "Query SQLite database"), systemImage: "magnifyingglass")
                            }
                        }

                        Section(NSLocalizedString("表", comment: "SQLite tables")) {
                            if tables.isEmpty {
                                Text(NSLocalizedString("暂无内容", comment: ""))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(tables) { table in
                                    NavigationLink {
                                        SQLiteTableDataView(databaseURL: file.url, table: table)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(table.name)
                                                .etFont(.subheadline.weight(.semibold))
                                            Text(String(format: NSLocalizedString("%d 个字段", comment: "SQLite column count"), table.columns.count))
                                                .etFont(.caption)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await loadTables()
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
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

private struct SQLiteTableDataView: View {
    let databaseURL: URL
    let table: StorageSQLiteTableInfo

    @State private var page: StorageSQLiteQueryPage?
    @State private var pageIndex = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let pageSize = 50

    var body: some View {
        SQLiteRowsView(
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

private struct SQLiteQueryView: View {
    let databaseURL: URL
    let title: String

    @State private var sql = "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')"
    @State private var page: StorageSQLiteQueryPage?
    @State private var pageIndex = 0
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let pageSize = 50

    var body: some View {
        SQLiteRowsView(
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
                    TextField(NSLocalizedString("只读 SQL", comment: "Read-only SQL placeholder"), text: $sql, axis: .vertical)
                        .etFont(.system(.footnote, design: .monospaced))
                        .lineLimit(3...8)

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

private struct SQLiteRowsView<Header: View>: View {
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
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else if let page {
                Section(NSLocalizedString("统计", comment: "")) {
                    infoRow(
                        title: NSLocalizedString("当前页", comment: "SQLite current page"),
                        value: "\(page.pageIndex + 1)"
                    )
                    infoRow(
                        title: NSLocalizedString("行", comment: "SQLite row count"),
                        value: "\(page.rows.count)"
                    )
                    infoRow(
                        title: NSLocalizedString("字段", comment: "SQLite column count label"),
                        value: "\(page.columns.count)"
                    )
                }

                Section {
                    HStack {
                        Button(NSLocalizedString("上一页", comment: "")) {
                            onPrevious()
                        }
                        .disabled(!canGoBack || isLoading)

                        Spacer()

                        Button(NSLocalizedString("下一页", comment: "")) {
                            onNext()
                        }
                        .disabled(!canGoForward || isLoading)
                    }
                }

                Section(NSLocalizedString("内容", comment: "")) {
                    if page.rows.isEmpty {
                        Text(NSLocalizedString("暂无内容", comment: ""))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(page.rows) { row in
                            SQLiteRowCard(row: row)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private extension SQLiteRowsView where Header == EmptyView {
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

private struct SQLiteRowCard: View {
    let row: StorageSQLiteRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("#\(row.index + 1)")
                .etFont(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(row.cells) { cell in
                VStack(alignment: .leading, spacing: 2) {
                    Text(cell.column)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(cell.value)
                        .etFont(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct OtherFilesView: View {
    private let rootDirectory = StorageUtility.documentsDirectory
    private let knownDirectories = Set(StorageCategory.allCases.map(\.rawValue))

    var body: some View {
        StorageDirectoryBrowserView(
            title: NSLocalizedString("其他文件", comment: ""),
            rootDirectory: rootDirectory,
            currentDirectory: rootDirectory,
            emptyTitle: NSLocalizedString("暂无其他文件", comment: ""),
            emptyDescription: NSLocalizedString("Documents 根目录下没有其他文件。", comment: ""),
            footerText: NSLocalizedString("点击文件夹继续浏览，点击 JSON 文件可预览内容。", comment: ""),
            itemFilter: { item in
                if item.isDirectory {
                    return !knownDirectories.contains(item.name)
                }
                return true
            }
        )
    }
}

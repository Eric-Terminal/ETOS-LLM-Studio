// ============================================================================
// FileListDetailViewPreviews.swift
// ============================================================================
// ETOS LLM Studio
//
// iOS 文件列表详情页的文本文件预览、图片预览与 SQLite 预览子视图。
// ============================================================================

import Foundation
import ETOSCore
import SwiftUI
import UIKit

struct FilePreviewSheet: View {
    let file: FileItem

    @Environment(\.dismiss) private var dismiss
    @State private var payload: FileAttachmentPreviewPayload?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let payload, let content = payload.text {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(NSLocalizedString("文件名", comment: ""))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text(file.name)
                                    .etFont(.footnote.monospaced())

                                Text(NSLocalizedString("文件大小", comment: ""))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text(StorageUtility.formatSize(payload.fileSize))
                                    .etFont(.footnote.monospaced())

                                Text(NSLocalizedString("总行数", comment: ""))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(payload.lineCount)")
                                    .etFont(.footnote.monospaced())
                            }

                            if payload.isTextTruncated {
                                Text(String(format: NSLocalizedString("已显示前 %d 个字符，共 %d 个字符。", comment: ""), payload.previewCharacterLimit, payload.originalCharacterCount))
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)

                                NavigationLink {
                                    FileAttachmentPagedTextView(
                                        title: file.name,
                                        text: payload.fullText ?? content
                                    )
                                } label: {
                                    Label(NSLocalizedString("查看完整内容", comment: "Open full file preview"), systemImage: "doc.text.magnifyingglass")
                                }
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
                        description: Text(payload?.errorMessage ?? NSLocalizedString("无法读取此文件的内容。", comment: ""))
                    )
                }
            }
            .navigationTitle(NSLocalizedString("文件预览", comment: ""))
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
            let fileURL = file.url
            payload = await Task.detached(priority: .userInitiated) {
                FileAttachmentPreviewLoader.load(fileURL: fileURL)
            }.value
            isLoading = false
        }
    }
}

struct FileAttachmentPagedTextView: View {
    let title: String
    let pages: [AppLogTextPage]
    let textCharacterCount: Int

    @State private var selectedPageIndex = 0

    init(title: String, text: String) {
        self.title = title
        self.pages = AppLogTextPaginator.paginate(text)
        self.textCharacterCount = text.count
    }

    private var currentPage: AppLogTextPage {
        let clampedIndex = min(max(selectedPageIndex, 0), pages.count - 1)
        return pages[clampedIndex]
    }

    private var hasMultiplePages: Bool {
        pages.count > 1
    }

    private var canGoToPreviousPage: Bool {
        selectedPageIndex > 0
    }

    private var canGoToNextPage: Bool {
        selectedPageIndex + 1 < pages.count
    }

    private var paginationSummaryText: String {
        String(
            format: NSLocalizedString("当前显示第 %d-%d 个字符，共 %d 个字符。", comment: "Paged text preview range summary"),
            currentPage.startCharacterNumber,
            currentPage.endCharacterNumber,
            textCharacterCount
        )
    }

    var body: some View {
        List {
            Section {
                Text(currentPage.content)
                    .etFont(.footnote.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text(String(format: NSLocalizedString("第 %d / %d 页", comment: ""), currentPage.index + 1, currentPage.totalCount))
            } footer: {
                Text(paginationSummaryText)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if hasMultiplePages {
                paginationBar
            }
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Button {
                goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .disabled(!canGoToPreviousPage)
            .accessibilityLabel(NSLocalizedString("上一页", comment: ""))

            Text(paginationSummaryText)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.bordered)
            .disabled(!canGoToNextPage)
            .accessibilityLabel(NSLocalizedString("下一页", comment: ""))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        selectedPageIndex -= 1
    }

    private func goToNextPage() {
        guard canGoToNextPage else { return }
        selectedPageIndex += 1
    }
}

struct ImagePreviewSheet: View {
    let file: FileItem

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        let filePath = file.url.path

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
            image = await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: filePath)
            }.value
            isLoading = false
        }
    }
}

struct SQLitePreviewSheet: View {
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

struct SQLiteTableDataView: View {
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

struct SQLiteQueryView: View {
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

struct SQLiteRowsView<Header: View>: View {
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

struct SQLiteRowCard: View {
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

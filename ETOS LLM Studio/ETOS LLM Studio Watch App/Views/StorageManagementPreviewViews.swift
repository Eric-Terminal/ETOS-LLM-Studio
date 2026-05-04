// ============================================================================
// StorageManagementPreviewViews.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 存储管理视图的图片、SQLite 与 JSON 预览界面。
// ============================================================================

import SwiftUI
import Shared

private struct WatchImagePreviewView: View {
    let file: FileItem

    @State private var image: UIImage?
    @State private var isLoading = true

    var body: some View {
        let filePath = file.url.path

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
                UIImage(contentsOfFile: filePath)
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

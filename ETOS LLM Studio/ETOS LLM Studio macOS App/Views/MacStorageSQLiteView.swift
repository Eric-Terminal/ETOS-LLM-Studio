import ETOSCore
import SwiftUI

@MainActor
struct MacStorageSQLiteView: View {
    let file: MacStorageFile
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacStorageReadModel<MacStorageSQLiteCatalog>()
    @State private var visible = false
    private var active: Bool { visible && isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            Section {
                Text(file.item.name).font(.body.monospaced()).textSelection(.enabled)
                Text(file.size).font(.caption).foregroundStyle(.secondary)
                NavigationLink(NSLocalizedString("只读 SQL 查询", comment: "")) {
                    MacStorageSQLiteRowsView(file: file, table: nil, isActive: isActive)
                }
                Button(NSLocalizedString("刷新", comment: ""), action: reload).disabled(model.isLoading)
            }
            if model.isLoading { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            if let value = model.value {
                ForEach(value.tables) { table in
                    NavigationLink { MacStorageSQLiteRowsView(file: file, table: table, isActive: isActive) } label: {
                        Label(table.info.name, systemImage: table.info.type == "view" ? "eye" : "tablecells")
                    }
                }
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(NSLocalizedString("数据库预览", comment: "")).disabled(!isActive || !workspace.canManageLocalModels)
        .toolbar { Button(NSLocalizedString("关闭", comment: "")) { dismiss() } }
        .onAppear { visible = true }
        .onDisappear { visible = false; model.close(clearContent: false) }
        .onChange(of: active) { _, value in if value { reload() } else { model.close(clearContent: visible) } }
        .onChange(of: configuration.appLanguage) { _, _ in reload() }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-storage-database-\(model.revision)"), title: NSLocalizedString("数据库预览", comment: ""),
            documents: [GuideDocumentReference(id: "storage-management", title: "Storage Management")], isActive: active, settings: [
                .readOnly("loading", label: NSLocalizedString("正在加载…", comment: ""), value: { .bool(model.isLoading) }),
                .readOnly("table_count", label: NSLocalizedString("表", comment: ""), value: { .int(model.value?.tables.count ?? 0) }),
                .readOnly("read_only", label: NSLocalizedString("只读", comment: ""), value: { .bool(true) })
            ])
    }
    private func reload() {
        guard active else { return }; let file = file
        model.load(workspace: workspace) { try MacStorageSQLiteCatalog.load(file) }
    }
}

@MainActor
private struct MacStorageSQLiteRowsView: View {
    let file: MacStorageFile
    let table: MacStorageSQLiteCatalog.Table?
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacStorageReadModel<MacStorageSQLitePage>()
    @State private var draft = "SELECT name, type FROM sqlite_master"
    @State private var executedSQL: String?
    @State private var visible = false
    @State private var selectedCell: MacStorageSQLitePage.Cell?
    private var active: Bool { visible && isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            if let table {
                Section(NSLocalizedString("表结构", comment: "")) {
                    ForEach(table.columns) { column in
                        LabeledContent(column.name, value: column.declaration).font(.caption.monospaced())
                    }
                }
            } else {
                Section {
                    TextEditor(text: $draft).font(.body.monospaced()).frame(minHeight: 100)
                        .accessibilityLabel(NSLocalizedString("只读 SQL 查询", comment: ""))
                    Button(NSLocalizedString("执行查询", comment: "")) { executedSQL = draft; load(pageIndex: 0) }.disabled(model.isLoading)
                } footer: {
                    Text(String(format: NSLocalizedString("只支持只读 SQL：%@。", comment: ""), "SELECT/WITH/PRAGMA"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if model.isLoading { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
            if let page = model.value {
                if page.rows.isEmpty { Text(NSLocalizedString("暂无数据", comment: "")).foregroundStyle(.secondary) }
                ForEach(page.rows) { row in
                    Section {
                        ForEach(row.cells) { cell in
                            VStack(alignment: .leading) {
                                Text(cell.name).font(.caption).foregroundStyle(.secondary)
                                Text(cell.preview).font(.body.monospaced()).textSelection(.enabled)
                                if cell.isTruncated {
                                    Button(NSLocalizedString("查看完整内容", comment: "")) { selectedCell = cell }.buttonStyle(.plain)
                                }
                            }
                        }
                    } header: { Text(String(format: NSLocalizedString("第 %d 行", comment: ""), row.id + 1)) }
                }
                Section {
                    Button(NSLocalizedString("上一页", comment: "")) { load(pageIndex: page.pageIndex - 1) }.disabled(page.pageIndex == 0 || model.isLoading)
                    Button(NSLocalizedString("下一页", comment: "")) { load(pageIndex: page.pageIndex + 1) }.disabled(!page.hasNextPage || model.isLoading)
                }
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
        }
        .navigationTitle(table?.info.name ?? NSLocalizedString("只读 SQL 查询", comment: "")).disabled(!isActive || !workspace.canManageLocalModels)
        .onAppear { visible = true }
        .onDisappear { visible = false; clear() }
        .onChange(of: active) { _, value in if value && table != nil { load(pageIndex: 0) } else if !value { clear() } }
        .onChange(of: configuration.appLanguage) { _, _ in clear(); if table != nil { load(pageIndex: 0) } }
        .onChange(of: draft) { _, _ in executedSQL = nil; model.close() }
        .sheet(item: $selectedCell) { MacStorageCellPreviewView(cell: $0, isActive: active) }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-storage-query-\(model.revision)"), title: NSLocalizedString("只读 SQL 查询", comment: ""),
            documents: [GuideDocumentReference(id: "storage-management", title: "Storage Management")], isActive: active && selectedCell == nil,
            settings: guideFields)
    }
    private var guideFields: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("loading", label: NSLocalizedString("正在加载…", comment: ""), value: { .bool(model.isLoading) }),
            .readOnly("row_count", label: NSLocalizedString("记录", comment: ""), value: { .int(model.value?.rows.count ?? 0) }),
            .readOnly("save_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("read_only_query_requires_native_execution") })
        ]
        if table == nil {
            fields.append(.string("query_draft", label: NSLocalizedString("只读 SQL 查询", comment: ""), get: { draft }, set: { draft = $0 }))
        }
        return fields
    }
    private func clear() { model.close(); selectedCell = nil; executedSQL = nil }
    private func load(pageIndex: Int) {
        guard active, table != nil || executedSQL != nil else { return }
        let sql = executedSQL ?? "", name = table?.info.name, file = file
        model.load(workspace: workspace) { try MacStorageSQLitePage.load(file: file, table: name, sql: sql, pageIndex: pageIndex) }
    }
}

@MainActor
private struct MacStorageCellPreviewView: View {
    let cell: MacStorageSQLitePage.Cell
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = MacStorageReadModel<[StorageTextPage]>()
    @State private var index = 0
    var body: some View {
        NavigationStack {
            VStack {
                if let pages = model.value, pages.indices.contains(index) {
                    ScrollView([.horizontal, .vertical]) { Text(pages[index].content).font(.body.monospaced()).textSelection(.enabled).padding() }
                    HStack {
                        Button(NSLocalizedString("上一页", comment: "")) { index -= 1 }.disabled(index == 0)
                        Button(NSLocalizedString("下一页", comment: "")) { index += 1 }.disabled(index + 1 == pages.count)
                    }.padding()
                }
            }
            .navigationTitle(cell.name).toolbar { Button(NSLocalizedString("关闭", comment: "")) { dismiss() } }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-storage-cell-\(cell.id)"), title: NSLocalizedString("查看完整内容", comment: ""),
                documents: [GuideDocumentReference(id: "storage-management", title: "Storage Management")], isActive: isActive && workspace.canManageLocalModels,
                settings: [.readOnly("page", label: NSLocalizedString("文件预览", comment: ""), value: { .int(index + 1) })])
        }
        .modifier(MacGuideInspector()).frame(minWidth: 600, minHeight: 400)
        .onAppear { let text = cell.fullText; model.load(workspace: workspace) { StorageBrowserSupport.paginateText(text) } }
        .onDisappear { model.close() }
        .onChange(of: isActive && workspace.canManageLocalModels) { _, active in if !active { model.close(); dismiss() } }
    }
}

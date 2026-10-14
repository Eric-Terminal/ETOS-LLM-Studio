import AppKit
import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct MacWorldbookListView: View {
    @ObservedObject var model: MacWorldbookModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var isImporting = false
    @State private var newBook: Worldbook?
    @State private var deletingBook: Worldbook?
    @State private var bindingSession: ChatSession?
    @State private var isImportingURL = false

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "worldbooks", title: NSLocalizedString("世界书", comment: ""),
                                     details: NSLocalizedString("Mac 世界书使用说明", comment: ""), documentID: "worldbooks")
                Button(NSLocalizedString("新增世界书", comment: "")) {
                    newBook = Worldbook(name: NSLocalizedString("新世界书", comment: ""), entries: [])
                }
                Button(NSLocalizedString("导入酒馆世界书 (JSON/PNG)", comment: "")) { isImporting = true }
                Button(NSLocalizedString("从 URL 导入世界书", comment: "")) { isImportingURL = true }
            }
            Section {
                Toggle(NSLocalizedString("在模型选择器中显示世界书", comment: ""), isOn: $configuration.modelPickerWorldbookShortcutEnabled)
                if let session = workspace.currentSession {
                    Button(NSLocalizedString("绑定世界书", comment: "")) { bindingSession = session }
                }
            }
            if let report = model.importReport {
                Section(NSLocalizedString("最近导入结果", comment: "")) {
                    LabeledContent(NSLocalizedString("新增条目", comment: ""), value: String(report.importedEntries))
                    LabeledContent(NSLocalizedString("跳过条目", comment: ""), value: String(report.skippedEntries))
                    LabeledContent(NSLocalizedString("失败条目", comment: ""), value: String(report.failedEntries))
                    if !model.importDetails.isEmpty { Text(model.importDetails).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section(String(format: NSLocalizedString("已导入世界书 (%d)", comment: ""), model.snapshot.rows.count)) {
                if model.isLoading { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                if model.snapshot.rows.isEmpty { Text(NSLocalizedString("暂无世界书。", comment: "")).foregroundStyle(.secondary) }
                ForEach(model.snapshot.rows) { row in
                    NavigationLink {
                        MacWorldbookDetailView(model: model, bookID: row.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(row.book.name)
                            Text(row.summary).font(.caption).foregroundStyle(.secondary)
                            Text(row.date).font(.caption).foregroundStyle(.secondary)
                            if !row.book.isEnabled { Text(NSLocalizedString("已停用", comment: "")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .contextMenu {
                        Button(NSLocalizedString("导出", comment: "")) { export(row.book) }
                        Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletingBook = row.book }
                    }
                    .moveDisabled(!model.query.isEmpty)
                }
                .onMove { indices, destination in
                    Task { do { try await model.moveBooks(from: indices, to: destination) } catch { model.error = error.localizedDescription } }
                }
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .disabled(model.isWorking || workspace.isRestoringData)
        .searchable(text: $model.query, prompt: NSLocalizedString("搜索", comment: ""))
        .navigationTitle(NSLocalizedString("世界书", comment: ""))
        .sheet(item: $newBook) { MacWorldbookEditor(model: model, book: $0, isNew: true) }
        .sheet(item: $bindingSession) { MacWorldbookBindingView(model: model, session: $0) }
        .sheet(isPresented: $isImportingURL) { MacWorldbookURLImportView(model: model) }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .png, .data]) { result in
            Task {
                do { try await model.importFile(result.get()) }
                catch { model.error = error.localizedDescription }
            }
        }
        .confirmationDialog(NSLocalizedString("删除世界书", comment: ""), isPresented: Binding(
            get: { deletingBook != nil }, set: { if !$0 { deletingBook = nil } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let book = deletingBook else { return }
                deletingBook = nil
                Task { do { try await model.delete(book) } catch { model.error = error.localizedDescription } }
            }
        }
        .guideSettingsPageContext(
            id: deletingBook == nil ? "mac-worldbooks" : "mac-worldbook-delete",
            title: NSLocalizedString("世界书", comment: ""),
            documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            settings: [
                .readOnly("books", label: NSLocalizedString("世界书列表", comment: ""), value: { model.snapshot.guideValue }),
                .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(model.isWorking) }),
                .readOnly("deleting_id", label: NSLocalizedString("删除世界书", comment: ""), value: { .string(deletingBook?.id.uuidString ?? "") })
            ] + (deletingBook != nil || model.isWorking || workspace.isRestoringData ? [] : [
                .bool("show_shortcut", label: NSLocalizedString("在模型选择器中显示世界书", comment: ""),
                      get: { configuration.modelPickerWorldbookShortcutEnabled }, set: { configuration.modelPickerWorldbookShortcutEnabled = $0 })
            ])
        )
    }

    private func export(_ book: Worldbook) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "worldbook.lorebook.json"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { do { try await model.export(book, to: url) } catch { model.error = error.localizedDescription } }
        }
    }
}

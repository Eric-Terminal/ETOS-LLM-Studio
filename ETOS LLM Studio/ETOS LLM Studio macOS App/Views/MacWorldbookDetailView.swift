import ETOSCore
import SwiftUI

struct MacWorldbookDetailView: View {
    @ObservedObject var model: MacWorldbookModel
    let bookID: UUID
    @State private var editingBook: Worldbook?
    @State private var editingEntry: EntryTarget?
    @State private var deletingEntry: DeletionTarget?

    private struct DeletionTarget {
        let book: Worldbook
        let id: UUID
    }

    private struct EntryTarget: Identifiable {
        let book: Worldbook
        let draft: MacWorldbookEntryDraft
        var id: UUID { draft.id }
    }

    var body: some View {
        List {
            if let row = model.snapshot.byID[bookID] {
                Section {
                    LabeledContent(NSLocalizedString("世界书名称", comment: ""), value: row.book.name)
                    if !row.book.description.isEmpty { Text(row.book.description).font(.footnote).foregroundStyle(.secondary) }
                    Text(row.summary).font(.caption).foregroundStyle(.secondary)
                    Button(NSLocalizedString("编辑", comment: "")) { editingBook = row.book }
                } header: { Text(NSLocalizedString("基本信息", comment: "")) }
                Section(NSLocalizedString("条目", comment: "")) {
                    Button(NSLocalizedString("新增条目", comment: "")) {
                        editingEntry = EntryTarget(book: row.book, draft: MacWorldbookEntryDraft(entry: WorldbookEntry(content: "", keys: [])))
                    }
                    ForEach(row.entries) { entry in
                        Button { edit(entry.entry, in: row.book) } label: {
                            VStack(alignment: .leading) {
                                Text(entry.title)
                                Text(entry.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                if !entry.entry.isEnabled { Text(NSLocalizedString("已停用", comment: "")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletingEntry = DeletionTarget(book: row.book, id: entry.id) }
                        }
                    }
                    .onMove { indices, destination in
                        Task { do { try await model.moveEntries(in: row.book, from: indices, to: destination) } catch { model.error = error.localizedDescription } }
                    }
                }
            } else {
                Text(NSLocalizedString("世界书不存在或已被删除。", comment: "")).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .disabled(model.isWorking)
        .navigationTitle(NSLocalizedString("世界书详情", comment: ""))
        .sheet(item: $editingBook) { MacWorldbookEditor(model: model, book: $0) }
        .sheet(item: $editingEntry) { MacWorldbookEntryEditor(model: model, book: $0.book, draft: $0.draft) }
        .confirmationDialog(NSLocalizedString("确认删除条目", comment: ""), isPresented: Binding(
            get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let target = deletingEntry else { return }
                deletingEntry = nil
                Task { do { try await model.delete(target.book, entryID: target.id) } catch { model.error = error.localizedDescription } }
            }
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-worldbook-detail-\(bookID)-\(deletingEntry == nil ? "view" : "delete")"),
            title: NSLocalizedString("世界书详情", comment: ""), documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks")],
            settings: [
                .readOnly("book", label: NSLocalizedString("世界书", comment: ""), value: { model.snapshot.byID[bookID]?.guideValue ?? .null }),
                .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(model.isWorking) }),
                .readOnly("deleting_entry", label: NSLocalizedString("确认删除条目", comment: ""), value: { .string(deletingEntry?.id.uuidString ?? "") })
            ]
        )
    }

    private func edit(_ entry: WorldbookEntry, in book: Worldbook) {
        Task {
            let draft = await Task.detached { MacWorldbookEntryDraft(entry: entry) }.value
            editingEntry = EntryTarget(book: book, draft: draft)
        }
    }

}

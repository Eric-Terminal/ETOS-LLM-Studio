// ============================================================================
// WorldbookDetailView.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS 世界书详情页的基础信息、默认设置与条目列表维护。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct WorldbookDetailView: View {
    let worldbookID: UUID

    @State private var worldbook: Worldbook?
    @State private var nameDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var editingEntryDraft: WorldbookEntryDraft?
    @State private var entryToDelete: WorldbookEntry?

    private var orderedEntries: [WorldbookEntry] {
        worldbook?.entries ?? []
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    var body: some View {
        List {
            if let worldbook {
                Section(NSLocalizedString("基本信息", comment: "Basic info")) {
                    TextField(NSLocalizedString("世界书名称", comment: "Worldbook name field"), text: $nameDraft)
                        .onSubmit {
                            saveName()
                        }
                    TextField(NSLocalizedString("世界书描述", comment: "Worldbook description field"), text: $descriptionDraft, axis: .vertical)
                        .lineLimit(2...6)
                        .onSubmit {
                            saveDescription()
                        }
                    Text(String(format: NSLocalizedString("条目数量：%d", comment: "Entry count"), worldbook.entries.count))
                        .foregroundStyle(.secondary)
                }

                Section(NSLocalizedString("默认设置", comment: "Default settings")) {
                    LabeledContent(NSLocalizedString("扫描深度", comment: "Scan depth label")) {
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: settingsScanDepthBinding, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                    }
                    LabeledContent(NSLocalizedString("最大递归层级", comment: "Max recursion depth label")) {
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: settingsMaxRecursionDepthBinding, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                    }
                    LabeledContent(NSLocalizedString("最大注入条目", comment: "Max injected entries label")) {
                        TextField(NSLocalizedString("-1 表示不限制", comment: "Unlimited placeholder"), value: settingsMaxInjectedEntriesBinding, formatter: numberFormatter)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    LabeledContent(NSLocalizedString("最大注入字符", comment: "Max injected characters label")) {
                        TextField(NSLocalizedString("-1 表示不限制", comment: "Unlimited placeholder"), value: settingsMaxInjectedCharsBinding, formatter: numberFormatter)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    Picker(NSLocalizedString("备用插入位置", comment: "Fallback position"), selection: settingsFallbackPositionBinding) {
                        ForEach(WorldbookPosition.allCases, id: \.self) { position in
                            Text(worldbookPositionLabel(position))
                                .tag(position)
                        }
                    }
                }

                Section(NSLocalizedString("条目", comment: "Entries section")) {
                    Button {
                        editingEntryDraft = .new()
                    } label: {
                        Label(NSLocalizedString("新增条目", comment: "Add entry"), systemImage: "plus")
                    }

                    if orderedEntries.isEmpty {
                        Text(NSLocalizedString("暂无条目", comment: "No entries"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(orderedEntries) { entry in
                            NavigationLink {
                                WorldbookEntryDetailView(
                                    entry: entry,
                                    onSave: { updatedEntry in
                                        upsertEntry(updatedEntry)
                                    }
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.comment.isEmpty ? NSLocalizedString("(无注释)", comment: "No comment") : entry.comment)
                                        .etFont(.subheadline)
                                        .lineLimit(1)

                                    Text(
                                        entry.isEnabled
                                        ? NSLocalizedString("已启用", comment: "Worldbook enabled status")
                                        : NSLocalizedString("已停用", comment: "Worldbook disabled status")
                                    )
                                    .etFont(.caption)
                                    .foregroundStyle(entry.isEnabled ? .green : .secondary)

                                    if let preview = entryPreview(entry) {
                                        Text(preview)
                                            .etFont(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                                    entryToDelete = entry
                                }
                            }
                        }
                        .onMove(perform: moveEntries)
                    }
                }
            } else {
                Section {
                    Text(NSLocalizedString("世界书不存在或已被删除。", comment: "Worldbook missing"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("世界书详情", comment: "Worldbook detail title"))
        .onAppear(perform: reload)
        .onDisappear(perform: persistPendingBasicInfo)
        .sheet(item: $editingEntryDraft) { draft in
            NavigationStack {
                WorldbookEntryEditView(
                    draft: draft,
                    isNew: true,
                    onSave: { updatedEntry in
                        upsertEntry(updatedEntry)
                    },
                    onDelete: nil
                )
            }
        }
        .alert(
            NSLocalizedString("确认删除条目", comment: "Confirm deleting entry"),
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        entryToDelete = nil
                    }
                }
            ),
            actions: {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    guard let entryToDelete else { return }
                    deleteEntry(id: entryToDelete.id)
                    self.entryToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                    entryToDelete = nil
                }
            },
            message: {
                Text(NSLocalizedString("删除后不可恢复。", comment: "Delete entry irreversible"))
            }
        )
    }

    private func reload() {
        guard var book = ChatService.shared.loadWorldbooks().first(where: { $0.id == worldbookID }) else {
            worldbook = nil
            nameDraft = ""
            descriptionDraft = ""
            return
        }
        book.entries = normalizedEntryOrder(book.entries)
        worldbook = book
        nameDraft = book.name
        descriptionDraft = book.description
    }

    private func updateWorldbook(_ mutate: (inout Worldbook) -> Void) {
        guard var worldbook else { return }
        mutate(&worldbook)
        worldbook.updatedAt = Date()
        ChatService.shared.saveWorldbook(worldbook)
        self.worldbook = worldbook
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        guard !trimmed.isEmpty else {
            nameDraft = worldbook?.name ?? ""
            return
        }
        updateWorldbook { $0.name = trimmed }
    }

    private func saveDescription() {
        let trimmed = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        updateWorldbook { $0.description = trimmed }
    }

    private func persistPendingBasicInfo() {
        guard worldbook != nil else { return }
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let trimmedDescription = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        updateWorldbook { book in
            if !trimmedName.isEmpty {
                book.name = trimmedName
            }
            book.description = trimmedDescription
        }
    }

    private var settingsScanDepthBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.scanDepth ?? 4 },
            set: { value in
                updateWorldbook { $0.settings.scanDepth = max(1, value) }
            }
        )
    }

    private var settingsMaxRecursionDepthBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.maxRecursionDepth ?? 2 },
            set: { value in
                updateWorldbook { $0.settings.maxRecursionDepth = max(0, value) }
            }
        )
    }

    private var settingsMaxInjectedEntriesBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.maxInjectedEntries ?? WorldbookSettings.unlimitedInjectedEntries },
            set: { value in
                updateWorldbook { book in
                    book.settings.maxInjectedEntries = value < 0 ? WorldbookSettings.unlimitedInjectedEntries : max(1, value)
                    book.metadata["etosExplicitMaxInjectedEntries"] = value < 0 ? nil : .bool(true)
                }
            }
        )
    }

    private var settingsMaxInjectedCharsBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.maxInjectedCharacters ?? WorldbookSettings.unlimitedInjectedCharacters },
            set: { value in
                updateWorldbook { $0.settings.maxInjectedCharacters = value < 0 ? WorldbookSettings.unlimitedInjectedCharacters : max(1, value) }
            }
        )
    }

    private var settingsFallbackPositionBinding: Binding<WorldbookPosition> {
        Binding(
            get: { worldbook?.settings.fallbackPosition ?? .after },
            set: { value in
                updateWorldbook { $0.settings.fallbackPosition = value }
            }
        )
    }

    private func upsertEntry(_ entry: WorldbookEntry) {
        updateWorldbook { worldbook in
            if let index = worldbook.entries.firstIndex(where: { $0.id == entry.id }) {
                worldbook.entries[index] = entry
            } else {
                worldbook.entries.append(entry)
            }
            worldbook.entries = normalizedEntryOrder(worldbook.entries)
        }
        reload()
    }

    private func deleteEntry(id: UUID) {
        updateWorldbook { worldbook in
            worldbook.entries.removeAll { $0.id == id }
            worldbook.entries = normalizedEntryOrder(worldbook.entries)
        }
        reload()
    }

    private func moveEntries(from source: IndexSet, to destination: Int) {
        guard var book = worldbook else { return }
        book.entries.move(fromOffsets: source, toOffset: destination)
        book.entries = normalizedEntryOrder(book.entries)
        book.updatedAt = Date()
        ChatService.shared.saveWorldbook(book)
        worldbook = book
    }

    private func normalizedEntryOrder(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
        var normalized: [WorldbookEntry] = entries
        normalized.sort {
            if $0.order == $1.order {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.order > $1.order
        }
        let total = normalized.count
        for index in normalized.indices {
            normalized[index].order = total - index
        }
        return normalized
    }

    private func entryPreview(_ entry: WorldbookEntry) -> String? {
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

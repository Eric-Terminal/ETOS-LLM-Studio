// ============================================================================
// WorldbookSettingsSupport.swift
// ============================================================================
// WorldbookSettingsView watchOS 详情、条目编辑与会话绑定辅助视图
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct WatchWorldbookDetailView: View {
    let worldbookID: UUID

    @State private var worldbook: Worldbook?
    @State private var editingEntryDraft: WatchWorldbookEntryDraft?
    @State private var entryToDelete: WorldbookEntry?
    @State private var nameDraft: String = ""
    @State private var descriptionDraft: String = ""

    private var orderedEntries: [WorldbookEntry] {
        guard let worldbook else { return [] }
        return worldbook.entries.sorted { lhs, rhs in
            if lhs.order == rhs.order {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.order > rhs.order
        }
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var settingsScanDepthBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.scanDepth ?? 4 },
            set: { value in
                updateWorldbook { book in
                    book.settings.scanDepth = max(1, value)
                }
            }
        )
    }

    private var settingsMaxRecursionDepthBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.maxRecursionDepth ?? 2 },
            set: { value in
                updateWorldbook { book in
                    book.settings.maxRecursionDepth = max(0, value)
                }
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
                updateWorldbook { book in
                    book.settings.maxInjectedCharacters = value < 0 ? WorldbookSettings.unlimitedInjectedCharacters : max(1, value)
                }
            }
        )
    }

    private var settingsFallbackPositionBinding: Binding<WorldbookPosition> {
        Binding(
            get: { worldbook?.settings.fallbackPosition ?? .after },
            set: { value in
                updateWorldbook { book in
                    book.settings.fallbackPosition = value
                }
            }
        )
    }

    var body: some View {
        List {
            if let worldbook {
                Section(NSLocalizedString("基本信息", comment: "Basic info")) {
                    TextField(
                        NSLocalizedString("名称", comment: "Worldbook name field"),
                        text: $nameDraft.watchKeyboardNewlineBinding(normalizeSmartQuotes: true)
                    )
                    TextField(
                        NSLocalizedString("描述", comment: "Worldbook description field"),
                        text: $descriptionDraft.watchKeyboardNewlineBinding(normalizeSmartQuotes: true)
                    )
                    Button(NSLocalizedString("保存信息", comment: "Save basic info")) {
                        saveBasicInfo()
                    }
                    Text(String(format: NSLocalizedString("条目数量：%d", comment: "Entry count"), worldbook.entries.count))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(NSLocalizedString("默认设置", comment: "Default settings")) {
                    HStack {
                        Text(NSLocalizedString("扫描深度", comment: "Scan depth label"))
                        Spacer()
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: settingsScanDepthBinding, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    HStack {
                        Text(NSLocalizedString("最大递归层级", comment: "Max recursion depth label"))
                        Spacer()
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: settingsMaxRecursionDepthBinding, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                    HStack {
                        Text(NSLocalizedString("最大注入条目", comment: "Max injected entries label"))
                        Spacer()
                        TextField(NSLocalizedString("-1 表示不限制", comment: "Unlimited placeholder"), value: settingsMaxInjectedEntriesBinding, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 76)
                    }
                    HStack {
                        Text(NSLocalizedString("最大注入字符", comment: "Max injected characters label"))
                        Spacer()
                        TextField(NSLocalizedString("-1 表示不限制", comment: "Unlimited placeholder"), value: settingsMaxInjectedCharsBinding, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 76)
                    }
                    Picker(NSLocalizedString("备用插入位置", comment: "Fallback position"), selection: settingsFallbackPositionBinding) {
                        ForEach(WorldbookPosition.allCases, id: \.self) { position in
                            Text(worldbookPositionLabel(position)).tag(position)
                        }
                    }
                }

                Section(NSLocalizedString("条目", comment: "Entries section")) {
                    Button {
                        editingEntryDraft = .new()
                    } label: {
                        Label(NSLocalizedString("新增条目", comment: "Add entry"), systemImage: "plus")
                    }

                    if worldbook.entries.isEmpty {
                        Text(NSLocalizedString("暂无条目", comment: "No entries"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(orderedEntries) { entry in
                            NavigationLink {
                                WatchWorldbookEntryDetailView(
                                    entry: entry,
                                    onSave: { updatedEntry in
                                        upsertEntry(updatedEntry)
                                    }
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.comment.isEmpty ? NSLocalizedString("(无注释)", comment: "No comment") : entry.comment)
                                        .etFont(.footnote)
                                        .lineLimit(1)

                                    Text(
                                        entry.isEnabled
                                        ? NSLocalizedString("已启用", comment: "Worldbook enabled status")
                                        : NSLocalizedString("已停用", comment: "Worldbook disabled status")
                                    )
                                    .etFont(.caption2)
                                    .foregroundStyle(entry.isEnabled ? .green : .secondary)

                                    if let preview = entryPreview(entry) {
                                        Text(preview)
                                            .etFont(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                                    entryToDelete = entry
                                }
                            }
                        }
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
        .onAppear(perform: load)
        .sheet(item: $editingEntryDraft) { draft in
            NavigationStack {
                WatchWorldbookEntryEditView(
                    draft: draft,
                    onSave: { entry in
                        upsertEntry(entry)
                    }
                )
            }
        }
        .confirmationDialog(
            NSLocalizedString("确认删除条目", comment: "Confirm deleting entry"),
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        entryToDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                guard let entryToDelete else { return }
                deleteEntry(entryToDelete.id)
                self.entryToDelete = nil
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                entryToDelete = nil
            }
        } message: {
            Text(NSLocalizedString("删除后不可恢复。", comment: "Delete entry irreversible"))
        }
    }

    private func load() {
        worldbook = ChatService.shared.loadWorldbooks().first(where: { $0.id == worldbookID })
        nameDraft = worldbook?.name ?? ""
        descriptionDraft = worldbook?.description ?? ""
    }

    private func saveBasicInfo() {
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        updateWorldbook { worldbook in
            if !trimmedName.isEmpty {
                worldbook.name = trimmedName
            }
            worldbook.description = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        }
    }

    private func upsertEntry(_ entry: WorldbookEntry) {
        updateWorldbook { worldbook in
            if let index = worldbook.entries.firstIndex(where: { $0.id == entry.id }) {
                worldbook.entries[index] = entry
            } else {
                worldbook.entries.append(entry)
            }
            worldbook.entries = normalizeEntryOrder(worldbook.entries)
        }
    }

    private func deleteEntry(_ entryID: UUID) {
        updateWorldbook { worldbook in
            worldbook.entries.removeAll { $0.id == entryID }
            worldbook.entries = normalizeEntryOrder(worldbook.entries)
        }
    }

    private func updateWorldbook(_ mutate: (inout Worldbook) -> Void) {
        guard var worldbook else { return }
        mutate(&worldbook)
        worldbook.updatedAt = Date()
        ChatService.shared.saveWorldbook(worldbook)
        self.worldbook = worldbook
    }

    private func normalizeEntryOrder(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
        var normalized = entries
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

struct WatchWorldbookSessionBindingView: View {
    private enum InjectionBindingTab: String, CaseIterable, Identifiable {
        case mode
        case lorebooks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mode:
                return NSLocalizedString("Mode Injections", comment: "Mode injection tab")
            case .lorebooks:
                return NSLocalizedString("Lorebooks", comment: "Lorebooks tab")
            }
        }
    }

    @Binding var session: ChatSession?
    @State private var worldbooks: [Worldbook] = []
    @State private var selected = Set<UUID>()
    @State private var selectedTab: InjectionBindingTab = .lorebooks

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("注入类型", comment: "Injection type"), selection: $selectedTab) {
                    ForEach(InjectionBindingTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
            }

            Section {
                Text(NSLocalizedString("点击条目即可绑定或取消绑定。", comment: "Binding hint tap row"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if selectedTab == .mode {
                Text(NSLocalizedString("Mode Injection 绑定功能将与助手注入页对齐，当前版本先保留 Lorebook 绑定。", comment: "Mode injection placeholder"))
                    .foregroundStyle(.secondary)
            } else if worldbooks.isEmpty {
                Text(NSLocalizedString("暂无可绑定世界书", comment: "No bindable worldbook on watch"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(worldbooks) { book in
                    Button {
                        toggle(book.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.name)
                                    .etFont(.footnote)
                                Text(String(format: NSLocalizedString("%d 条", comment: "Entry count short"), book.entries.count))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(
                                    selected.contains(book.id)
                                    ? AnyShapeStyle(.tint)
                                    : AnyShapeStyle(.tertiary)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(NSLocalizedString("会话绑定", comment: "Session binding title"))
        .onAppear(perform: load)
    }

    private func load() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
        selected = Set(session?.lorebookIDs ?? [])
    }

    private func toggle(_ id: UUID) {
        guard var current = session else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        current.lorebookIDs = selected.sorted(by: { $0.uuidString < $1.uuidString })
        persistSessionSettings(current)
    }

    private func persistSessionSettings(_ current: ChatSession) {
        session = current
        ChatService.shared.updateWorldbookSessionSettings(
            sessionID: current.id,
            worldbookIDs: current.lorebookIDs,
            worldbookContextIsolationEnabled: current.worldbookContextIsolationEnabled
        )
    }
}

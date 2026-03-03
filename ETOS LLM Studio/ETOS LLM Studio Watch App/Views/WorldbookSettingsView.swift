// ============================================================================
// WorldbookSettingsView.swift
// ============================================================================
// WorldbookSettingsView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import Shared

struct WorldbookSettingsView: View {
    @ObservedObject var viewModel: ChatViewModel

    @State private var worldbooks: [Worldbook] = []
    @State private var selected = Set<UUID>()
    @State private var worldbookToDelete: Worldbook?
    @State private var importURLText: String = ""
    @State private var isImportingFromURL = false
    @State private var importError: String?
    @State private var importReport: WorldbookImportReport?

    var body: some View {
        List {
            if let session = viewModel.currentSession {
                Section(NSLocalizedString("当前会话", comment: "Current session section")) {
                    NavigationLink {
                        WatchWorldbookSessionBindingView(
                            session: Binding(
                                get: { viewModel.currentSession },
                                set: { viewModel.currentSession = $0 }
                            )
                        )
                    } label: {
                        HStack {
                            Text(NSLocalizedString("绑定世界书", comment: "Bind worldbooks"))
                            Spacer()
                            Text(bindingSummary(for: session))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section(NSLocalizedString("世界书列表", comment: "Worldbook list section")) {
                if worldbooks.isEmpty {
                    Text(NSLocalizedString("暂无世界书，可在本机通过链接导入，或在 iPhone 导入后同步。", comment: "No worldbooks on watch"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(worldbooks) { book in
                        NavigationLink {
                            WatchWorldbookDetailView(worldbookID: book.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.name)

                                Text(enabledEntrySummary(for: book))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                if !book.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(book.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                if selected.contains(book.id) {
                                    Text(NSLocalizedString("已绑定当前会话", comment: "Bound current session"))
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                worldbookToDelete = book
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section(NSLocalizedString("导入", comment: "Import section")) {
                TextField(NSLocalizedString("世界书链接", comment: "Worldbook URL field"), text: $importURLText.watchKeyboardNewlineBinding())

                Button {
                    importFromURL()
                } label: {
                    Label(
                        isImportingFromURL
                        ? NSLocalizedString("正在下载并导入...", comment: "Downloading and importing")
                        : NSLocalizedString("从 URL 导入世界书", comment: "Import worldbook from URL button"),
                        systemImage: "link.badge.plus"
                    )
                }
                .disabled(isImportingFromURL)

                if isImportingFromURL {
                    ProgressView()
                }

                Text(NSLocalizedString("支持 http/https 的 JSON 或 PNG 链接。", comment: "Supported URL formats"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let report = importReport {
                Section(NSLocalizedString("最近导入结果", comment: "Latest import result section")) {
                    row(title: NSLocalizedString("新增条目", comment: "Imported entries"), value: "\(report.importedEntries)")
                    row(title: NSLocalizedString("跳过条目", comment: "Skipped entries"), value: "\(report.skippedEntries)")
                    row(title: NSLocalizedString("失败条目", comment: "Failed entries"), value: "\(report.failedEntries)")
                    if !report.failureReasons.isEmpty {
                        Text(report.failureReasons.joined(separator: "\n"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let importError, !importError.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "Import error section")) {
                    Text(importError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("世界书", comment: "Worldbook nav title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    createEmptyWorldbook()
                } label: {
                    Label(NSLocalizedString("新增", comment: "Add worldbook"), systemImage: "plus")
                }
            }
        }
        .onAppear(perform: load)
        .confirmationDialog(
            NSLocalizedString("确认删除世界书", comment: "Confirm deleting worldbook title"),
            isPresented: Binding(
                get: { worldbookToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        worldbookToDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                confirmDeleteWorldbook()
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                worldbookToDelete = nil
            }
        } message: {
            if let worldbookToDelete {
                Text(
                    String(
                        format: NSLocalizedString("将删除“%@”，此操作不可恢复。", comment: "Delete worldbook confirmation message"),
                        worldbookToDelete.name
                    )
                )
            }
        }
    }

    private func load() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
        selected = Set(viewModel.currentSession?.lorebookIDs ?? [])
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func bindingSummary(for session: ChatSession) -> String {
        let boundSet = Set(session.lorebookIDs)
        let boundBookCount = worldbooks.filter { boundSet.contains($0.id) }.count
        let totalBookCount = worldbooks.count
        return String(
            format: NSLocalizedString("%d/%d 本", comment: "Bound worldbook count summary"),
            boundBookCount,
            totalBookCount
        )
    }

    private func enabledEntrySummary(for book: Worldbook) -> String {
        let enabledCount = book.entries.filter(\.isEnabled).count
        return String(
            format: NSLocalizedString("启用条目 %d/%d", comment: "Enabled worldbook entry summary"),
            enabledCount,
            book.entries.count
        )
    }

    private func confirmDeleteWorldbook() {
        guard let target = worldbookToDelete else { return }
        ChatService.shared.deleteWorldbook(id: target.id)
        if var session = viewModel.currentSession {
            session.lorebookIDs.removeAll { $0 == target.id }
            viewModel.currentSession = session
        }
        worldbookToDelete = nil
        load()
    }

    private func createEmptyWorldbook() {
        let defaultEntry = WorldbookEntry(
            comment: NSLocalizedString("新条目", comment: "New entry comment"),
            content: "",
            keys: [],
            position: .after
        )
        let worldbook = Worldbook(
            name: NSLocalizedString("新世界书", comment: "New worldbook name"),
            entries: [defaultEntry],
            settings: WorldbookSettings()
        )
        ChatService.shared.saveWorldbook(worldbook)
        load()
    }

    private func importFromURL() {
        let trimmed = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importError = NSLocalizedString("链接不能为空。", comment: "URL cannot be empty")
            return
        }
        guard let url = URL(string: trimmed) else {
            importError = NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "Invalid URL format")
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            importError = NSLocalizedString("仅支持 http/https 链接。", comment: "Only http or https is supported")
            return
        }

        importError = nil
        isImportingFromURL = true

        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        importError = String(
                            format: NSLocalizedString("下载失败：HTTP %d", comment: "HTTP status code failure"),
                            httpResponse.statusCode
                        )
                        isImportingFromURL = false
                    }
                    return
                }

                let fileName = suggestedRemoteImportFileName(from: url, response: response)
                let report = try ChatService.shared.importWorldbook(data: data, fileName: fileName)
                await MainActor.run {
                    importReport = report
                    importError = report.failureReasons.isEmpty ? nil : report.failureReasons.joined(separator: "\n")
                    importURLText = ""
                    isImportingFromURL = false
                    load()
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    isImportingFromURL = false
                }
            }
        }
    }

    private func suggestedRemoteImportFileName(from url: URL, response: URLResponse) -> String {
        var fileName = response.suggestedFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fileName.isEmpty {
            fileName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if fileName.isEmpty || fileName == "/" {
            fileName = "worldbook-from-url"
        }

        let lowercased = fileName.lowercased()
        if lowercased.hasSuffix(".json") || lowercased.hasSuffix(".png") {
            return fileName
        }

        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("png") {
            return "\(fileName).png"
        }
        return "\(fileName).json"
    }

}

private struct WatchWorldbookDetailView: View {
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                                        .font(.footnote)
                                        .lineLimit(1)

                                    Text(
                                        entry.isEnabled
                                        ? NSLocalizedString("已启用", comment: "Worldbook enabled status")
                                        : NSLocalizedString("已停用", comment: "Worldbook disabled status")
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(entry.isEnabled ? .green : .secondary)

                                    if let preview = entryPreview(entry) {
                                        Text(preview)
                                            .font(.caption2)
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
        guard var worldbook else { return }
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        if !trimmedName.isEmpty {
            worldbook.name = trimmedName
        }
        worldbook.description = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        worldbook.updatedAt = Date()
        ChatService.shared.saveWorldbook(worldbook)
        self.worldbook = worldbook
    }

    private func upsertEntry(_ entry: WorldbookEntry) {
        guard var worldbook else { return }
        if let index = worldbook.entries.firstIndex(where: { $0.id == entry.id }) {
            worldbook.entries[index] = entry
        } else {
            worldbook.entries.append(entry)
        }
        worldbook.entries = normalizeEntryOrder(worldbook.entries)
        worldbook.updatedAt = Date()
        ChatService.shared.saveWorldbook(worldbook)
        self.worldbook = worldbook
    }

    private func deleteEntry(_ entryID: UUID) {
        guard var worldbook else { return }
        worldbook.entries.removeAll { $0.id == entryID }
        worldbook.entries = normalizeEntryOrder(worldbook.entries)
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

private struct WatchWorldbookEntryDetailView: View {
    @State private var entry: WorldbookEntry

    let onSave: (WorldbookEntry) -> Void

    init(entry: WorldbookEntry, onSave: @escaping (WorldbookEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.onSave = onSave
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { enabled in
                entry.isEnabled = enabled
                onSave(entry)
            }
        )
    }

    var body: some View {
        List {
            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: enabledBinding)
            }

            Section(NSLocalizedString("编辑", comment: "Edit")) {
                NavigationLink {
                    WatchWorldbookEntryEditView(
                        draft: WatchWorldbookEntryDraft(entry: entry),
                        onSave: { updatedEntry in
                            entry = updatedEntry
                            onSave(updatedEntry)
                        }
                    )
                } label: {
                    Label(NSLocalizedString("编辑条目", comment: "Edit entry"), systemImage: "square.and.pencil")
                }
            }

            Section(NSLocalizedString("内容", comment: "Content field")) {
                if !entry.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.comment)
                        .font(.footnote)
                }

                if !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.content)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !entry.keys.isEmpty {
                    Text(entry.keys.joined(separator: "，"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(worldbookPositionLabel(entry.position))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(
                    String(
                        format: NSLocalizedString("角色：%@", comment: "Entry role label"),
                        worldbookEntryRoleLabel(entry.role)
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("条目", comment: "Entries section"))
    }
}

private struct WatchWorldbookEntryEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: WatchWorldbookEntryDraft

    let onSave: (WorldbookEntry) -> Void

    let onDelete: (() -> Void)?

    init(draft: WatchWorldbookEntryDraft, onSave: @escaping (WorldbookEntry) -> Void, onDelete: (() -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var canSave: Bool {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return false }
        if !draft.constant && parseKeywordList(draft.keysText).isEmpty { return false }
        return true
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var orderBinding: Binding<Int> {
        Binding(
            get: { draft.order },
            set: { newValue in
                draft.order = min(1000, max(0, newValue))
            }
        )
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("基础", comment: "Entry base section")) {
                TextField(
                    NSLocalizedString("注释", comment: "Comment field"),
                    text: $draft.comment.watchKeyboardNewlineBinding(normalizeSmartQuotes: true),
                    axis: .vertical
                )
                .lineLimit(1...4)
                TextField(
                    NSLocalizedString("内容", comment: "Content field"),
                    text: $draft.content.watchKeyboardNewlineBinding(normalizeSmartQuotes: true),
                    axis: .vertical
                )
                .lineLimit(4...12)
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: $draft.isEnabled)
            }

            Section(NSLocalizedString("触发", comment: "Entry trigger section")) {
                TextField(
                    NSLocalizedString("关键词（逗号分隔）", comment: "Keywords field"),
                    text: $draft.keysText.watchKeyboardNewlineBinding(normalizeSmartQuotes: true),
                    axis: .vertical
                )
                .lineLimit(2...6)
                Toggle(NSLocalizedString("常驻激活", comment: "Constant active"), isOn: $draft.constant)
                Toggle(NSLocalizedString("正则匹配", comment: "Regex match"), isOn: $draft.useRegex)
                Toggle(NSLocalizedString("区分大小写", comment: "Case sensitive"), isOn: $draft.caseSensitive)
            }

            Section(NSLocalizedString("插入", comment: "Entry position section")) {
                Picker(NSLocalizedString("位置", comment: "Position"), selection: $draft.position) {
                    ForEach(WorldbookPosition.allCases, id: \.self) { position in
                        Text(worldbookPositionLabel(position)).tag(position)
                    }
                }
                Picker(NSLocalizedString("角色", comment: "Role"), selection: $draft.role) {
                    ForEach(WorldbookEntryRole.allCases, id: \.self) { role in
                        Text(worldbookEntryRoleLabel(role)).tag(role)
                    }
                }
                HStack {
                    Text(String(format: NSLocalizedString("优先级：%d", comment: "Order value"), draft.order))
                    Spacer()
                    TextField("数量", value: orderBinding, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
                if draft.position == .atDepth {
                    Stepper(
                        String(format: NSLocalizedString("深度：%d", comment: "Depth value"), draft.depth),
                        value: $draft.depth,
                        in: 0...64
                    )
                }
            }

            if let onDelete {
                Section {
                    Button(NSLocalizedString("删除条目", comment: "Delete entry"), role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("编辑条目", comment: "Edit entry"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(NSLocalizedString("取消", comment: "Cancel")) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("保存", comment: "Save")) {
                    onSave(draft.toEntry())
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}

private struct WatchWorldbookEntryDraft: Identifiable {
    let id: UUID
    let entryID: UUID

    var comment: String
    var content: String
    var keysText: String
    var isEnabled: Bool
    var constant: Bool
    var useRegex: Bool
    var caseSensitive: Bool
    var position: WorldbookPosition
    var role: WorldbookEntryRole
    var depth: Int
    var order: Int

    init(entry: WorldbookEntry) {
        self.id = UUID()
        self.entryID = entry.id
        self.comment = entry.comment
        self.content = entry.content
        self.keysText = entry.keys.joined(separator: ", ")
        self.isEnabled = entry.isEnabled
        self.constant = entry.constant
        self.useRegex = entry.useRegex
        self.caseSensitive = entry.caseSensitive
        self.position = entry.position
        self.role = entry.role
        self.depth = max(0, entry.depth ?? 0)
        self.order = entry.order
    }

    static func new() -> WatchWorldbookEntryDraft {
        WatchWorldbookEntryDraft(
            id: UUID(),
            entryID: UUID(),
            comment: "",
            content: "",
            keysText: "",
            isEnabled: true,
            constant: false,
            useRegex: false,
            caseSensitive: false,
            position: .after,
            role: .user,
            depth: 0,
            order: 100
        )
    }

    private init(
        id: UUID,
        entryID: UUID,
        comment: String,
        content: String,
        keysText: String,
        isEnabled: Bool,
        constant: Bool,
        useRegex: Bool,
        caseSensitive: Bool,
        position: WorldbookPosition,
        role: WorldbookEntryRole,
        depth: Int,
        order: Int
    ) {
        self.id = id
        self.entryID = entryID
        self.comment = comment
        self.content = content
        self.keysText = keysText
        self.isEnabled = isEnabled
        self.constant = constant
        self.useRegex = useRegex
        self.caseSensitive = caseSensitive
        self.position = position
        self.role = role
        self.depth = depth
        self.order = order
    }

    func toEntry() -> WorldbookEntry {
        let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedKeys = parseKeywordList(keysText.normalizedPlainQuotes())
        WorldbookEntry(
            id: entryID,
            comment: normalizedComment,
            content: normalizedContent,
            keys: normalizedKeys,
            isEnabled: isEnabled,
            constant: constant,
            position: position,
            order: order,
            depth: position == .atDepth ? depth : nil,
            caseSensitive: caseSensitive,
            useRegex: useRegex,
            role: role
        )
    }
}

private struct WatchWorldbookSessionBindingView: View {
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
                    .font(.footnote)
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
                                    .font(.footnote)
                                Text(String(format: NSLocalizedString("%d 条", comment: "Entry count short"), book.entries.count))
                                    .font(.caption2)
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
        session = current
        ChatService.shared.assignWorldbooks(to: current.id, worldbookIDs: current.lorebookIDs)
    }
}

private func worldbookPositionLabel(_ position: WorldbookPosition) -> String {
    switch position {
    case .before:
        return NSLocalizedString("系统前置", comment: "Worldbook position before")
    case .after:
        return NSLocalizedString("系统后置", comment: "Worldbook position after")
    case .anTop:
        return NSLocalizedString("AN 顶部", comment: "Worldbook position anTop")
    case .anBottom:
        return NSLocalizedString("AN 底部", comment: "Worldbook position anBottom")
    case .atDepth:
        return NSLocalizedString("按深度插入", comment: "Worldbook position atDepth")
    case .emTop:
        return NSLocalizedString("消息顶部", comment: "Worldbook position emTop")
    case .emBottom:
        return NSLocalizedString("消息底部", comment: "Worldbook position emBottom")
    case .outlet:
        return NSLocalizedString("Outlet", comment: "Worldbook position outlet")
    @unknown default:
        return NSLocalizedString("系统后置", comment: "Worldbook position fallback")
    }
}

private func worldbookEntryRoleLabel(_ role: WorldbookEntryRole) -> String {
    switch role {
    case .system:
        return NSLocalizedString("系统", comment: "Worldbook role system")
    case .user:
        return NSLocalizedString("用户", comment: "Worldbook role user")
    case .assistant:
        return NSLocalizedString("助手", comment: "Worldbook role assistant")
    @unknown default:
        return NSLocalizedString("用户", comment: "Worldbook role default")
    }
}

private func parseKeywordList(_ raw: String) -> [String] {
    let normalized = raw
        .normalizedPlainQuotes()
        .replacingOccurrences(of: "，", with: ",")
    let components = normalized.components(separatedBy: CharacterSet(charactersIn: ",\n"))
    var seen = Set<String>()
    var result: [String] = []

    for component in components {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        if seen.contains(key) { continue }
        seen.insert(key)
        result.append(trimmed)
    }

    return result
}

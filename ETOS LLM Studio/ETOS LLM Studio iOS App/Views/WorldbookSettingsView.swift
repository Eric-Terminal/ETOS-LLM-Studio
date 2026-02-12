import SwiftUI
import UniformTypeIdentifiers
import Shared

struct WorldbookSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @State private var worldbooks: [Worldbook] = []
    @State private var isImporting = false
    @State private var importError: String?
    @State private var exportError: String?
    @State private var importReport: WorldbookImportReport?
    @State private var showImportReportAlert = false
    @State private var worldbookToDelete: Worldbook?
    @State private var exportDocument: WorldbookExportDocument?
    @State private var exportFileName: String = "worldbook.lorebook.json"
    @State private var isURLImportSheetPresented = false
    @State private var importURLText: String = ""
    @State private var isImportingFromURL = false

    var body: some View {
        List {
            Section(NSLocalizedString("世界书说明", comment: "Worldbook description section")) {
                Text(NSLocalizedString("世界书会在发送消息时按规则自动激活并注入，不会写入长期记忆。", comment: "Worldbook intro"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let session = viewModel.currentSession {
                Section(NSLocalizedString("当前会话", comment: "Current session section")) {
                    NavigationLink {
                        WorldbookSessionBindingView(
                            currentSession: Binding(
                                get: { viewModel.currentSession },
                                set: { viewModel.currentSession = $0 }
                            )
                        )
                    } label: {
                        HStack {
                            Label(NSLocalizedString("绑定世界书", comment: "Bind worldbooks"), systemImage: "link.badge.plus")
                            Spacer()
                            Text(bindingSummary(for: session))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section(NSLocalizedString("导入", comment: "Import section")) {
                Button {
                    isImporting = true
                } label: {
                    Label(NSLocalizedString("导入酒馆世界书 (JSON/PNG)", comment: "Import worldbook button"), systemImage: "square.and.arrow.down")
                }

                Button {
                    isURLImportSheetPresented = true
                } label: {
                    Label(NSLocalizedString("从 URL 导入世界书", comment: "Import worldbook from URL button"), systemImage: "link.badge.plus")
                }

                if isImportingFromURL {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(NSLocalizedString("正在下载并导入...", comment: "Downloading and importing"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let report = importReport {
                Section(NSLocalizedString("最近导入结果", comment: "Latest import result section")) {
                    row(title: NSLocalizedString("新增条目", comment: "Imported entries"), value: "\(report.importedEntries)")
                    row(title: NSLocalizedString("跳过条目", comment: "Skipped entries"), value: "\(report.skippedEntries)")
                    row(title: NSLocalizedString("失败条目", comment: "Failed entries"), value: "\(report.failedEntries)")
                    if !report.failureReasons.isEmpty {
                        Text(report.failureReasons.joined(separator: "\n"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let importError, !importError.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "Import error section")) {
                    Text(importError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let exportError, !exportError.isEmpty {
                Section(NSLocalizedString("导出错误", comment: "Export error section")) {
                    Text(exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section(String(format: NSLocalizedString("已导入世界书 (%d)", comment: "Imported worldbook count"), worldbooks.count)) {
                if worldbooks.isEmpty {
                    Text(NSLocalizedString("暂无世界书。", comment: "No worldbook"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(worldbooks) { book in
                        NavigationLink {
                            WorldbookDetailView(worldbookID: book.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(book.name)
                                        .font(.headline)
                                    Spacer()
                                    Text(book.isEnabled
                                         ? NSLocalizedString("已启用", comment: "Worldbook enabled status")
                                         : NSLocalizedString("已停用", comment: "Worldbook disabled status"))
                                        .font(.caption)
                                        .foregroundStyle(book.isEnabled ? .green : .secondary)
                                }

                                HStack(spacing: 8) {
                                    Text(String(format: NSLocalizedString("条目 %d", comment: "Entry count short"), book.entries.count))
                                    Text(book.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if !book.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(book.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                if isBoundToCurrentSession(book) {
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
                        .contextMenu {
                            Button {
                                exportWorldbook(book.id)
                            } label: {
                                Label(NSLocalizedString("导出", comment: "Export"), systemImage: "square.and.arrow.up")
                            }

                            Button(role: .destructive) {
                                worldbookToDelete = book
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveWorldbooks)
                }
            }
        }
        .navigationTitle(NSLocalizedString("世界书", comment: "Worldbook nav title"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    createEmptyWorldbook()
                } label: {
                    Label(NSLocalizedString("新增世界书", comment: "Add worldbook"), systemImage: "plus")
                }
            }
        }
        .onAppear(perform: reloadWorldbooks)
        .sheet(isPresented: $isURLImportSheetPresented) {
            NavigationStack {
                Form {
                    Section {
                        TextField(NSLocalizedString("世界书链接", comment: "Worldbook URL field"), text: $importURLText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                    }

                    Section {
                        Text(NSLocalizedString("输入可直接访问的 JSON 或 PNG 世界书链接。", comment: "URL import hint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if isImportingFromURL {
                        Section {
                            ProgressView(NSLocalizedString("正在下载并导入...", comment: "Downloading and importing"))
                        }
                    }
                }
                .navigationTitle(NSLocalizedString("从链接导入", comment: "Import from link title"))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(NSLocalizedString("取消", comment: "Cancel")) {
                            isURLImportSheetPresented = false
                        }
                        .disabled(isImportingFromURL)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(NSLocalizedString("开始导入", comment: "Start import")) {
                            startURLImport()
                        }
                        .disabled(isImportingFromURL || importURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.json, .png],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { newValue in
                    if !newValue {
                        exportDocument = nil
                    }
                }
            ),
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFileName
        ) { result in
            switch result {
            case .success:
                exportError = nil
            case .failure(let error):
                exportError = error.localizedDescription
            }
        }
        .alert(
            NSLocalizedString("世界书导入报告", comment: "Import report alert title"),
            isPresented: $showImportReportAlert,
            actions: {
                Button(NSLocalizedString("好的", comment: "OK")) {}
            },
            message: {
                if let importReport {
                    Text(importReportAlertMessage(importReport))
                }
            }
        )
        .alert(
            NSLocalizedString("确认删除世界书", comment: "Confirm deleting worldbook title"),
            isPresented: Binding(
                get: { worldbookToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        worldbookToDelete = nil
                    }
                }
            ),
            actions: {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    confirmDeleteWorldbook()
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                    worldbookToDelete = nil
                }
            },
            message: {
                if let worldbookToDelete {
                    Text(
                        String(
                            format: NSLocalizedString("将删除“%@”，此操作不可恢复。", comment: "Delete worldbook confirmation message"),
                            worldbookToDelete.name
                        )
                    )
                }
            }
        )
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private func isBoundToCurrentSession(_ worldbook: Worldbook) -> Bool {
        viewModel.currentSession?.lorebookIDs.contains(worldbook.id) ?? false
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
        reloadWorldbooks()
    }

    private func reloadWorldbooks() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
    }

    private func confirmDeleteWorldbook() {
        guard let target = worldbookToDelete else { return }
        ChatService.shared.deleteWorldbook(id: target.id)
        if var session = viewModel.currentSession {
            session.lorebookIDs.removeAll { $0 == target.id }
            viewModel.currentSession = session
        }
        worldbookToDelete = nil
        reloadWorldbooks()
    }

    private func moveWorldbooks(from source: IndexSet, to destination: Int) {
        worldbooks.move(fromOffsets: source, toOffset: destination)
        var reordered = worldbooks
        let now = Date()
        for index in reordered.indices {
            reordered[index].updatedAt = now.addingTimeInterval(Double(reordered.count - index))
            ChatService.shared.saveWorldbook(reordered[index])
        }
        worldbooks = reordered
    }

    private func exportWorldbook(_ id: UUID) {
        do {
            let output = try ChatService.shared.exportWorldbook(id: id)
            exportDocument = WorldbookExportDocument(data: output.data)
            exportFileName = output.suggestedFileName
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let shouldStop = url.startAccessingSecurityScopedResource()
                    defer {
                        if shouldStop {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    let data = try Data(contentsOf: url)
                    let report = try ChatService.shared.importWorldbook(data: data, fileName: url.lastPathComponent)
                    await MainActor.run {
                        importReport = report
                        importError = report.failureReasons.isEmpty ? nil : report.failureReasons.joined(separator: "\n")
                        showImportReportAlert = true
                        reloadWorldbooks()
                    }
                } catch {
                    await MainActor.run {
                        importError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func startURLImport() {
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
                    showImportReportAlert = true
                    reloadWorldbooks()
                    importURLText = ""
                    isImportingFromURL = false
                    isURLImportSheetPresented = false
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

    private func importReportAlertMessage(_ report: WorldbookImportReport) -> String {
        var lines: [String] = [
            String(format: NSLocalizedString("新增条目：%d", comment: "Imported entries count"), report.importedEntries),
            String(format: NSLocalizedString("跳过条目：%d", comment: "Skipped entries count"), report.skippedEntries),
            String(format: NSLocalizedString("失败条目：%d", comment: "Failed entries count"), report.failedEntries)
        ]
        if !report.failureReasons.isEmpty {
            lines.append("")
            lines.append(NSLocalizedString("失败详情：", comment: "Failure details header"))
            lines.append(contentsOf: report.failureReasons)
        }
        return lines.joined(separator: "\n")
    }
}

private struct WorldbookDetailView: View {
    let worldbookID: UUID

    @State private var worldbook: Worldbook?
    @State private var nameDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var expandedEntryIDs = Set<UUID>()
    @State private var editingEntryDraft: WorldbookEntryDraft?

    private var orderedEntries: [WorldbookEntry] {
        worldbook?.entries ?? []
    }

    var body: some View {
        List {
            if let worldbook {
                Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                    Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: enabledBinding)
                }

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
                    Stepper(
                        String(format: NSLocalizedString("扫描深度：%d", comment: "Scan depth value"), worldbook.settings.scanDepth),
                        value: settingsScanDepthBinding,
                        in: 1...64
                    )
                    Stepper(
                        String(format: NSLocalizedString("最大递归层级：%d", comment: "Max recursion depth value"), worldbook.settings.maxRecursionDepth),
                        value: settingsMaxRecursionDepthBinding,
                        in: 0...16
                    )
                    Stepper(
                        String(format: NSLocalizedString("最大注入条目：%d", comment: "Max injected entries value"), worldbook.settings.maxInjectedEntries),
                        value: settingsMaxInjectedEntriesBinding,
                        in: 1...256
                    )
                    Stepper(
                        String(format: NSLocalizedString("最大注入字符：%d", comment: "Max injected chars value"), worldbook.settings.maxInjectedCharacters),
                        value: settingsMaxInjectedCharsBinding,
                        in: 256...20000,
                        step: 128
                    )
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
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.comment.isEmpty ? NSLocalizedString("(无注释)", comment: "No comment") : entry.comment)
                                        .font(.subheadline)
                                    Spacer()
                                    Text(worldbookPositionLabel(entry.position))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Text(entry.content)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(expandedEntryIDs.contains(entry.id) ? nil : 4)

                                HStack {
                                    Button(
                                        expandedEntryIDs.contains(entry.id)
                                        ? NSLocalizedString("点击收起", comment: "Tap to collapse")
                                        : NSLocalizedString("点击展开全文", comment: "Tap to expand full text")
                                    ) {
                                        toggleEntryExpansion(entry.id)
                                    }
                                    .font(.caption2)

                                    Spacer()

                                    Button(NSLocalizedString("编辑", comment: "Edit")) {
                                        editingEntryDraft = WorldbookEntryDraft(entry: entry)
                                    }
                                    .font(.caption2)
                                }

                                Text(String(format: NSLocalizedString("关键词：%@", comment: "Keywords"), entry.keys.joined(separator: "，")))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)

                                Text(
                                    String(
                                        format: NSLocalizedString("角色：%@", comment: "Entry role label"),
                                        worldbookEntryRoleLabel(entry.role)
                                    )
                                )
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                        .onMove(perform: moveEntries)
                        .onDelete(perform: deleteEntries)
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
                    isNew: !entryExists(draft.entryID),
                    onSave: { updatedEntry in
                        upsertEntry(updatedEntry)
                    },
                    onDelete: entryExists(draft.entryID) ? {
                        deleteEntry(id: draft.entryID)
                    } : nil
                )
            }
        }
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

    private func entryExists(_ entryID: UUID) -> Bool {
        worldbook?.entries.contains(where: { $0.id == entryID }) ?? false
    }

    private func updateWorldbook(_ mutate: (inout Worldbook) -> Void) {
        guard var worldbook else { return }
        mutate(&worldbook)
        worldbook.updatedAt = Date()
        ChatService.shared.saveWorldbook(worldbook)
        self.worldbook = worldbook
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameDraft = worldbook?.name ?? ""
            return
        }
        updateWorldbook { $0.name = trimmed }
    }

    private func saveDescription() {
        let trimmed = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updateWorldbook { $0.description = trimmed }
    }

    private func persistPendingBasicInfo() {
        guard worldbook != nil else { return }
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updateWorldbook { book in
            if !trimmedName.isEmpty {
                book.name = trimmedName
            }
            book.description = trimmedDescription
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { worldbook?.isEnabled ?? false },
            set: { enabled in
                updateWorldbook { $0.isEnabled = enabled }
            }
        )
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
            get: { worldbook?.settings.maxInjectedEntries ?? 64 },
            set: { value in
                updateWorldbook { $0.settings.maxInjectedEntries = max(1, value) }
            }
        )
    }

    private var settingsMaxInjectedCharsBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.maxInjectedCharacters ?? 6000 },
            set: { value in
                updateWorldbook { $0.settings.maxInjectedCharacters = max(256, value) }
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

    private func deleteEntries(_ offsets: IndexSet) {
        let ids = offsets.map { orderedEntries[$0].id }
        updateWorldbook { worldbook in
            worldbook.entries.removeAll { ids.contains($0.id) }
            worldbook.entries = normalizedEntryOrder(worldbook.entries)
        }
        for id in ids {
            expandedEntryIDs.remove(id)
        }
        reload()
    }

    private func deleteEntry(id: UUID) {
        updateWorldbook { worldbook in
            worldbook.entries.removeAll { $0.id == id }
            worldbook.entries = normalizedEntryOrder(worldbook.entries)
        }
        expandedEntryIDs.remove(id)
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

    private func toggleEntryExpansion(_ entryID: UUID) {
        if expandedEntryIDs.contains(entryID) {
            expandedEntryIDs.remove(entryID)
        } else {
            expandedEntryIDs.insert(entryID)
        }
    }
}

private struct WorldbookEntryEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: WorldbookEntryDraft
    @State private var showDeleteConfirmation = false

    let isNew: Bool
    let onSave: (WorldbookEntry) -> Void
    let onDelete: (() -> Void)?

    init(
        draft: WorldbookEntryDraft,
        isNew: Bool,
        onSave: @escaping (WorldbookEntry) -> Void,
        onDelete: (() -> Void)?
    ) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var canSave: Bool {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return false }
        if !draft.constant && draft.primaryKeys.isEmpty { return false }
        return true
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("基础", comment: "Base section")) {
                TextField(NSLocalizedString("注释", comment: "Comment field"), text: $draft.comment)
                TextField(NSLocalizedString("内容", comment: "Content field"), text: $draft.content, axis: .vertical)
                    .lineLimit(6...16)
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: $draft.isEnabled)
            }

            Section(NSLocalizedString("关键词", comment: "Keyword section")) {
                TextField(NSLocalizedString("主关键词（逗号/换行分隔）", comment: "Primary keywords field"), text: $draft.keysText, axis: .vertical)
                    .lineLimit(2...6)
                TextField(NSLocalizedString("次级关键词（逗号/换行分隔）", comment: "Secondary keywords field"), text: $draft.secondaryKeysText, axis: .vertical)
                    .lineLimit(2...6)
                Picker(NSLocalizedString("次级逻辑", comment: "Secondary selective logic"), selection: $draft.selectiveLogic) {
                    ForEach(WorldbookSelectiveLogic.allCases, id: \.self) { logic in
                        Text(worldbookSelectiveLogicLabel(logic)).tag(logic)
                    }
                }
            }

            Section(NSLocalizedString("匹配与触发", comment: "Match and trigger section")) {
                Toggle(NSLocalizedString("常驻激活", comment: "Constant active"), isOn: $draft.constant)
                Toggle(NSLocalizedString("正则匹配", comment: "Regex match"), isOn: $draft.useRegex)
                Toggle(NSLocalizedString("区分大小写", comment: "Case sensitive"), isOn: $draft.caseSensitive)
                Toggle(NSLocalizedString("整词匹配", comment: "Whole word match"), isOn: $draft.matchWholeWords)
                Toggle(NSLocalizedString("启用概率", comment: "Enable probability"), isOn: $draft.useProbability)
                if draft.useProbability {
                    HStack {
                        Text(NSLocalizedString("概率", comment: "Probability"))
                        Spacer()
                        Text("\(Int(draft.probability.rounded()))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $draft.probability, in: 1...100, step: 1)
                }
                Stepper(
                    String(format: NSLocalizedString("优先级：%d", comment: "Order value"), draft.order),
                    value: $draft.order,
                    in: 0...1000
                )
            }

            Section(NSLocalizedString("插入方式", comment: "Injection mode section")) {
                Picker(NSLocalizedString("位置", comment: "Position"), selection: $draft.position) {
                    ForEach(WorldbookPosition.allCases, id: \.self) { position in
                        Text(worldbookPositionLabel(position)).tag(position)
                    }
                }

                Picker(NSLocalizedString("注入角色", comment: "Injection role"), selection: $draft.role) {
                    ForEach(WorldbookEntryRole.allCases, id: \.self) { role in
                        Text(worldbookEntryRoleLabel(role)).tag(role)
                    }
                }

                if draft.position == .atDepth {
                    Stepper(
                        String(format: NSLocalizedString("深度：%d", comment: "Depth value"), draft.depth),
                        value: $draft.depth,
                        in: 0...64
                    )
                }

                if draft.position == .outlet {
                    TextField(NSLocalizedString("Outlet 名称", comment: "Outlet name"), text: $draft.outletName)
                }
            }

            Section(NSLocalizedString("扫描与分组", comment: "Scan and group section")) {
                Toggle(NSLocalizedString("覆盖扫描深度", comment: "Override scan depth"), isOn: $draft.enableEntryScanDepth)
                if draft.enableEntryScanDepth {
                    Stepper(
                        String(format: NSLocalizedString("扫描深度：%d", comment: "Scan depth value"), draft.scanDepth),
                        value: $draft.scanDepth,
                        in: 1...64
                    )
                }

                TextField(NSLocalizedString("分组名", comment: "Group name"), text: $draft.groupName)
                Toggle(NSLocalizedString("组覆盖", comment: "Group override"), isOn: $draft.groupOverride)
                Toggle(NSLocalizedString("组评分", comment: "Use group scoring"), isOn: $draft.useGroupScoring)
                HStack {
                    Text(NSLocalizedString("组权重", comment: "Group weight"))
                    Spacer()
                    Text(String(format: "%.1f", draft.groupWeight))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $draft.groupWeight, in: 0...10, step: 0.5)
            }

            Section(NSLocalizedString("定时效果", comment: "Timed effects section")) {
                Toggle(NSLocalizedString("Sticky", comment: "Sticky toggle"), isOn: $draft.enableSticky)
                if draft.enableSticky {
                    Stepper(
                        String(format: NSLocalizedString("Sticky 回合：%d", comment: "Sticky turns"), draft.sticky),
                        value: $draft.sticky,
                        in: 1...20
                    )
                }

                Toggle(NSLocalizedString("Cooldown", comment: "Cooldown toggle"), isOn: $draft.enableCooldown)
                if draft.enableCooldown {
                    Stepper(
                        String(format: NSLocalizedString("Cooldown 回合：%d", comment: "Cooldown turns"), draft.cooldown),
                        value: $draft.cooldown,
                        in: 1...20
                    )
                }

                Toggle(NSLocalizedString("Delay", comment: "Delay toggle"), isOn: $draft.enableDelay)
                if draft.enableDelay {
                    Stepper(
                        String(format: NSLocalizedString("Delay 回合：%d", comment: "Delay turns"), draft.delay),
                        value: $draft.delay,
                        in: 1...20
                    )
                }
            }

            Section(NSLocalizedString("递归控制", comment: "Recursion section")) {
                Toggle(NSLocalizedString("排除递归缓冲", comment: "Exclude recursion buffer"), isOn: $draft.excludeRecursion)
                Toggle(NSLocalizedString("阻止递归触发", comment: "Prevent recursion"), isOn: $draft.preventRecursion)
                Toggle(NSLocalizedString("仅递归后触发", comment: "Delay until recursion"), isOn: $draft.delayUntilRecursion)
            }

            if onDelete != nil {
                Section {
                    Button(NSLocalizedString("删除条目", comment: "Delete entry"), role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(isNew
                         ? NSLocalizedString("新增条目", comment: "Add entry")
                         : NSLocalizedString("编辑条目", comment: "Edit entry"))
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
        .alert(
            NSLocalizedString("确认删除条目", comment: "Confirm deleting entry"),
            isPresented: $showDeleteConfirmation,
            actions: {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
            },
            message: {
                Text(NSLocalizedString("删除后不可恢复。", comment: "Delete entry irreversible"))
            }
        )
    }
}

private struct WorldbookEntryDraft: Identifiable {
    let id: UUID
    let entryID: UUID

    var comment: String
    var content: String
    var keysText: String
    var secondaryKeysText: String

    var selectiveLogic: WorldbookSelectiveLogic
    var isEnabled: Bool
    var constant: Bool

    var position: WorldbookPosition
    var role: WorldbookEntryRole
    var outletName: String
    var order: Int
    var depth: Int

    var enableEntryScanDepth: Bool
    var scanDepth: Int

    var caseSensitive: Bool
    var matchWholeWords: Bool
    var useRegex: Bool

    var useProbability: Bool
    var probability: Double

    var groupName: String
    var groupOverride: Bool
    var groupWeight: Double
    var useGroupScoring: Bool

    var enableSticky: Bool
    var sticky: Int

    var enableCooldown: Bool
    var cooldown: Int

    var enableDelay: Bool
    var delay: Int

    var excludeRecursion: Bool
    var preventRecursion: Bool
    var delayUntilRecursion: Bool

    var primaryKeys: [String] {
        parseKeywordList(keysText)
    }

    var secondaryKeys: [String] {
        parseKeywordList(secondaryKeysText)
    }

    init(entry: WorldbookEntry) {
        self.id = UUID()
        self.entryID = entry.id
        self.comment = entry.comment
        self.content = entry.content
        self.keysText = entry.keys.joined(separator: ", ")
        self.secondaryKeysText = entry.secondaryKeys.joined(separator: ", ")
        self.selectiveLogic = entry.selectiveLogic
        self.isEnabled = entry.isEnabled
        self.constant = entry.constant
        self.position = entry.position
        self.role = entry.role
        self.outletName = entry.outletName ?? ""
        self.order = entry.order
        self.depth = max(0, entry.depth ?? 0)
        self.enableEntryScanDepth = entry.scanDepth != nil
        self.scanDepth = max(1, entry.scanDepth ?? 4)
        self.caseSensitive = entry.caseSensitive
        self.matchWholeWords = entry.matchWholeWords
        self.useRegex = entry.useRegex
        self.useProbability = entry.useProbability
        self.probability = max(1, min(100, entry.probability))
        self.groupName = entry.group ?? ""
        self.groupOverride = entry.groupOverride
        self.groupWeight = entry.groupWeight
        self.useGroupScoring = entry.useGroupScoring
        self.enableSticky = entry.sticky != nil
        self.sticky = max(1, entry.sticky ?? 1)
        self.enableCooldown = entry.cooldown != nil
        self.cooldown = max(1, entry.cooldown ?? 1)
        self.enableDelay = entry.delay != nil
        self.delay = max(1, entry.delay ?? 1)
        self.excludeRecursion = entry.excludeRecursion
        self.preventRecursion = entry.preventRecursion
        self.delayUntilRecursion = entry.delayUntilRecursion
    }

    static func new() -> WorldbookEntryDraft {
        WorldbookEntryDraft(
            id: UUID(),
            entryID: UUID(),
            comment: "",
            content: "",
            keysText: "",
            secondaryKeysText: "",
            selectiveLogic: .andAny,
            isEnabled: true,
            constant: false,
            position: .after,
            role: .user,
            outletName: "",
            order: 100,
            depth: 0,
            enableEntryScanDepth: false,
            scanDepth: 4,
            caseSensitive: false,
            matchWholeWords: false,
            useRegex: false,
            useProbability: false,
            probability: 100,
            groupName: "",
            groupOverride: false,
            groupWeight: 1,
            useGroupScoring: false,
            enableSticky: false,
            sticky: 1,
            enableCooldown: false,
            cooldown: 1,
            enableDelay: false,
            delay: 1,
            excludeRecursion: false,
            preventRecursion: false,
            delayUntilRecursion: false
        )
    }

    func toEntry() -> WorldbookEntry {
        WorldbookEntry(
            id: entryID,
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines),
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            keys: primaryKeys,
            secondaryKeys: secondaryKeys,
            selectiveLogic: selectiveLogic,
            isEnabled: isEnabled,
            constant: constant,
            position: position,
            outletName: outletName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : outletName.trimmingCharacters(in: .whitespacesAndNewlines),
            order: order,
            depth: position == .atDepth ? depth : nil,
            scanDepth: enableEntryScanDepth ? scanDepth : nil,
            caseSensitive: caseSensitive,
            matchWholeWords: matchWholeWords,
            useRegex: useRegex,
            useProbability: useProbability,
            probability: max(1, min(100, probability)),
            group: groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : groupName.trimmingCharacters(in: .whitespacesAndNewlines),
            groupOverride: groupOverride,
            groupWeight: groupWeight,
            useGroupScoring: useGroupScoring,
            role: role,
            sticky: enableSticky ? sticky : nil,
            cooldown: enableCooldown ? cooldown : nil,
            delay: enableDelay ? delay : nil,
            excludeRecursion: excludeRecursion,
            preventRecursion: preventRecursion,
            delayUntilRecursion: delayUntilRecursion
        )
    }

    private init(
        id: UUID,
        entryID: UUID,
        comment: String,
        content: String,
        keysText: String,
        secondaryKeysText: String,
        selectiveLogic: WorldbookSelectiveLogic,
        isEnabled: Bool,
        constant: Bool,
        position: WorldbookPosition,
        role: WorldbookEntryRole,
        outletName: String,
        order: Int,
        depth: Int,
        enableEntryScanDepth: Bool,
        scanDepth: Int,
        caseSensitive: Bool,
        matchWholeWords: Bool,
        useRegex: Bool,
        useProbability: Bool,
        probability: Double,
        groupName: String,
        groupOverride: Bool,
        groupWeight: Double,
        useGroupScoring: Bool,
        enableSticky: Bool,
        sticky: Int,
        enableCooldown: Bool,
        cooldown: Int,
        enableDelay: Bool,
        delay: Int,
        excludeRecursion: Bool,
        preventRecursion: Bool,
        delayUntilRecursion: Bool
    ) {
        self.id = id
        self.entryID = entryID
        self.comment = comment
        self.content = content
        self.keysText = keysText
        self.secondaryKeysText = secondaryKeysText
        self.selectiveLogic = selectiveLogic
        self.isEnabled = isEnabled
        self.constant = constant
        self.position = position
        self.role = role
        self.outletName = outletName
        self.order = order
        self.depth = depth
        self.enableEntryScanDepth = enableEntryScanDepth
        self.scanDepth = scanDepth
        self.caseSensitive = caseSensitive
        self.matchWholeWords = matchWholeWords
        self.useRegex = useRegex
        self.useProbability = useProbability
        self.probability = probability
        self.groupName = groupName
        self.groupOverride = groupOverride
        self.groupWeight = groupWeight
        self.useGroupScoring = useGroupScoring
        self.enableSticky = enableSticky
        self.sticky = sticky
        self.enableCooldown = enableCooldown
        self.cooldown = cooldown
        self.enableDelay = enableDelay
        self.delay = delay
        self.excludeRecursion = excludeRecursion
        self.preventRecursion = preventRecursion
        self.delayUntilRecursion = delayUntilRecursion
    }
}

private struct WorldbookSessionBindingView: View {
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

    @Binding var currentSession: ChatSession?

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
                .pickerStyle(.segmented)
            }

            Section {
                Text(NSLocalizedString("点击条目即可绑定或取消绑定。", comment: "Binding hint tap row"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if selectedTab == .mode {
                Text(NSLocalizedString("Mode Injection 绑定功能将与助手注入页对齐，当前版本先保留 Lorebook 绑定。", comment: "Mode injection placeholder"))
                    .foregroundStyle(.secondary)
            } else {
                if worldbooks.isEmpty {
                    Text(NSLocalizedString("暂无可绑定的世界书。", comment: "No bindable worldbook"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(worldbooks) { book in
                        Button {
                            toggle(book.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.name)
                                    Text(String(format: NSLocalizedString("%d 条", comment: "Entry count short"), book.entries.count))
                                        .font(.caption)
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
        }
        .navigationTitle(NSLocalizedString("会话绑定世界书", comment: "Session binding title"))
        .onAppear(perform: load)
    }

    private func load() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
        selected = Set(currentSession?.lorebookIDs ?? [])
    }

    private func toggle(_ id: UUID) {
        guard var session = currentSession else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        session.lorebookIDs = selected.sorted(by: { $0.uuidString < $1.uuidString })
        currentSession = session
        ChatService.shared.assignWorldbooks(to: session.id, worldbookIDs: session.lorebookIDs)
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

private func worldbookSelectiveLogicLabel(_ logic: WorldbookSelectiveLogic) -> String {
    switch logic {
    case .andAny:
        return NSLocalizedString("AND_ANY（任一命中）", comment: "Selective logic andAny")
    case .andAll:
        return NSLocalizedString("AND_ALL（全部命中）", comment: "Selective logic andAll")
    case .notAny:
        return NSLocalizedString("NOT_ANY（全部不命中）", comment: "Selective logic notAny")
    case .notAll:
        return NSLocalizedString("NOT_ALL（并非全部命中）", comment: "Selective logic notAll")
    @unknown default:
        return NSLocalizedString("AND_ANY（任一命中）", comment: "Selective logic fallback")
    }
}

private func worldbookEntryRoleLabel(_ role: WorldbookEntryRole) -> String {
    switch role {
    case .user:
        return NSLocalizedString("用户", comment: "Worldbook role user")
    case .assistant:
        return NSLocalizedString("助手", comment: "Worldbook role assistant")
    @unknown default:
        return NSLocalizedString("用户", comment: "Worldbook role default")
    }
}

private func parseKeywordList(_ raw: String) -> [String] {
    let normalized = raw.replacingOccurrences(of: "，", with: ",")
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

private struct WorldbookExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

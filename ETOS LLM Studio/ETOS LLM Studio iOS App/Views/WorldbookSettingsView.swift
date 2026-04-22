// ============================================================================
// WorldbookSettingsView.swift
// ============================================================================
// WorldbookSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

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
    @State private var isShowingIntroDetails = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: "世界书",
                    summary: "按规则在发送消息时自动激活并注入，独立于记忆系统。",
                    details: """
                    能力说明
                    • 世界书会根据触发规则在发送消息时自动注入上下文。
                    • 它是“静态规则知识”，不参与记忆系统写入。

                    怎么用（建议顺序）
                    1. 先导入世界书（支持 JSON/PNG 或 URL）。
                    2. 在“当前会话”绑定需要生效的世界书。
                    3. 按需启用“隔离发送”，让会话只发送提示词与世界书上下文。

                    关键参数与状态
                    • 绑定数量：显示当前会话已绑定 / 总世界书数。
                    • 启用条目：显示每本世界书里启用条目占比。
                    • 已启用隔离发送：会屏蔽记忆、MCP、快捷指令等外部工具上下文。

                    管理建议
                    • 大型世界书优先维护条目启用状态，避免注入冗余内容。
                    • 导入后先看“最近导入结果”，及时处理失败条目和冲突。
                    • 重要世界书建议定期导出备份。
                    """,
                    isExpanded: $isShowingIntroDetails
                )
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
                            .etFont(.footnote)
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
                            .etFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let importError, !importError.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "Import error section")) {
                    Text(importError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if let exportError, !exportError.isEmpty {
                Section(NSLocalizedString("导出错误", comment: "Export error section")) {
                    Text(exportError)
                        .etFont(.footnote)
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
                                Text(book.name)
                                    .etFont(.headline)

                                HStack(spacing: 8) {
                                    Text(String(format: NSLocalizedString("条目 %d", comment: "Entry count short"), book.entries.count))
                                    Text(enabledEntrySummary(for: book))
                                    Text(book.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                                .etFont(.caption)
                                .foregroundStyle(.secondary)

                                if !book.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(book.description)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                if isBoundToCurrentSession(book) {
                                    Text(NSLocalizedString("已绑定当前会话", comment: "Bound current session"))
                                        .etFont(.caption2)
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
                            .etFont(.footnote)
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

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .etFont(.headline.weight(.semibold))
            Text(summary)
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text("进一步了解…")
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func isBoundToCurrentSession(_ worldbook: Worldbook) -> Bool {
        viewModel.currentSession?.lorebookIDs.contains(worldbook.id) ?? false
    }

    private func bindingSummary(for session: ChatSession) -> String {
        let boundSet = Set(session.lorebookIDs)
        let boundBookCount = worldbooks.filter { boundSet.contains($0.id) }.count
        let totalBookCount = worldbooks.count
        let base = String(
            format: NSLocalizedString("%d/%d 本", comment: "Bound worldbook count summary"),
            boundBookCount,
            totalBookCount
        )
        guard session.worldbookContextIsolationEnabled else { return base }
        return "\(base) · \(NSLocalizedString("已启用隔离发送", comment: "Isolation enabled summary"))"
    }

    private func enabledEntrySummary(for book: Worldbook) -> String {
        let enabledCount = book.entries.filter(\.isEnabled).count
        return String(
            format: NSLocalizedString("启用条目 %d/%d", comment: "Enabled worldbook entry summary"),
            enabledCount,
            book.entries.count
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
                let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
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
    @State private var editingEntryDraft: WorldbookEntryDraft?
    @State private var entryToDelete: WorldbookEntry?

    private var orderedEntries: [WorldbookEntry] {
        worldbook?.entries ?? []
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

private struct WorldbookEntryDetailView: View {
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
                    WorldbookEntryEditView(
                        draft: WorldbookEntryDraft(entry: entry),
                        isNew: false,
                        onSave: { updatedEntry in
                            entry = updatedEntry
                            onSave(updatedEntry)
                        },
                        onDelete: nil
                    )
                } label: {
                    Label(NSLocalizedString("编辑条目", comment: "Edit entry"), systemImage: "square.and.pencil")
                }
            }

            Section(NSLocalizedString("内容", comment: "Content field")) {
                if !entry.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.comment)
                        .etFont(.headline)
                }

                if !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.content)
                        .etFont(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !entry.keys.isEmpty {
                    Text(entry.keys.joined(separator: "，"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(worldbookPositionLabel(entry.position))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)

                Text(
                    String(
                        format: NSLocalizedString("角色：%@", comment: "Entry role label"),
                        worldbookEntryRoleLabel(entry.role)
                    )
                )
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("条目", comment: "Entries section"))
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
                    Stepper {
                        Text(String(format: NSLocalizedString("深度：%d", comment: "Depth value"), draft.depth))
                    } onIncrement: {
                        draft.depth += 1
                    } onDecrement: {
                        draft.depth = max(0, draft.depth - 1)
                    }
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
        let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedOutletName = outletName.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        return WorldbookEntry(
            id: entryID,
            comment: normalizedComment,
            content: normalizedContent,
            keys: primaryKeys,
            secondaryKeys: secondaryKeys,
            selectiveLogic: selectiveLogic,
            isEnabled: isEnabled,
            constant: constant,
            position: position,
            outletName: normalizedOutletName.isEmpty ? nil : normalizedOutletName,
            order: order,
            depth: position == .atDepth ? depth : nil,
            scanDepth: enableEntryScanDepth ? scanDepth : nil,
            caseSensitive: caseSensitive,
            matchWholeWords: matchWholeWords,
            useRegex: useRegex,
            useProbability: useProbability,
            probability: max(1, min(100, probability)),
            group: normalizedGroupName.isEmpty ? nil : normalizedGroupName,
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
                .tint(.blue)
            }

            Section {
                Toggle(
                    NSLocalizedString("绑定世界书时屏蔽记忆与工具", comment: "Worldbook isolation toggle"),
                    isOn: Binding(
                        get: { currentSession?.worldbookContextIsolationEnabled ?? false },
                        set: { updateIsolationMode($0) }
                    )
                )

                Text(NSLocalizedString("开启后，在当前会话已绑定世界书时，只发送全局提示词、话题提示词、增强提示词和世界书，不发送记忆系统、MCP 与快捷指令工具调用。", comment: "Worldbook isolation description"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(NSLocalizedString("点击条目即可绑定或取消绑定。", comment: "Binding hint tap row"))
                    .etFont(.footnote)
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
                                        .etFont(.caption)
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
        persistSessionSettings(session)
    }

    private func updateIsolationMode(_ isEnabled: Bool) {
        guard var session = currentSession else { return }
        session.worldbookContextIsolationEnabled = isEnabled
        persistSessionSettings(session)
    }

    private func persistSessionSettings(_ session: ChatSession) {
        currentSession = session
        ChatService.shared.updateWorldbookSessionSettings(
            sessionID: session.id,
            worldbookIDs: session.lorebookIDs,
            worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled
        )
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

private extension String {
    func normalizedPlainQuotes() -> String {
        self
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "„", with: "\"")
            .replacingOccurrences(of: "‟", with: "\"")
            .replacingOccurrences(of: "＂", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‚", with: "'")
            .replacingOccurrences(of: "‛", with: "'")
            .replacingOccurrences(of: "＇", with: "'")
    }
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

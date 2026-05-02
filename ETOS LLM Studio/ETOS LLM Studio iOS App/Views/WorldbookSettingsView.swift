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
    @EnvironmentObject var viewModel: ChatViewModel

    @State var worldbooks: [Worldbook] = []
    @State var isImporting = false
    @State var importError: String?
    @State var exportError: String?
    @State var importReport: WorldbookImportReport?
    @State var showImportReportAlert = false
    @State var worldbookToDelete: Worldbook?
    @State var exportDocument: WorldbookExportDocument?
    @State var exportFileName: String = "worldbook.lorebook.json"
    @State var isURLImportSheetPresented = false
    @State var importURLText: String = ""
    @State var isImportingFromURL = false
    @State var isShowingIntroDetails = false

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

    func row(title: String, value: String) -> some View {
        HStack {
            Text(NSLocalizedString(title, comment: "世界书信息行标题"))
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "世界书介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "世界书介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
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
                    Text(NSLocalizedString(details, comment: "世界书介绍卡片详情"))
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

    func isBoundToCurrentSession(_ worldbook: Worldbook) -> Bool {
        viewModel.currentSession?.lorebookIDs.contains(worldbook.id) ?? false
    }

    func bindingSummary(for session: ChatSession) -> String {
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

    func enabledEntrySummary(for book: Worldbook) -> String {
        let enabledCount = book.entries.filter(\.isEnabled).count
        return String(
            format: NSLocalizedString("启用条目 %d/%d", comment: "Enabled worldbook entry summary"),
            enabledCount,
            book.entries.count
        )
    }

    func createEmptyWorldbook() {
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

    func reloadWorldbooks() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
    }

    func confirmDeleteWorldbook() {
        guard let target = worldbookToDelete else { return }
        ChatService.shared.deleteWorldbook(id: target.id)
        if var session = viewModel.currentSession {
            session.lorebookIDs.removeAll { $0 == target.id }
            viewModel.currentSession = session
        }
        worldbookToDelete = nil
        reloadWorldbooks()
    }

    func moveWorldbooks(from source: IndexSet, to destination: Int) {
        worldbooks.move(fromOffsets: source, toOffset: destination)
        var reordered = worldbooks
        let now = Date()
        for index in reordered.indices {
            reordered[index].updatedAt = now.addingTimeInterval(Double(reordered.count - index))
            ChatService.shared.saveWorldbook(reordered[index])
        }
        worldbooks = reordered
    }

    func exportWorldbook(_ id: UUID) {
        do {
            let output = try ChatService.shared.exportWorldbook(id: id)
            exportDocument = WorldbookExportDocument(data: output.data)
            exportFileName = output.suggestedFileName
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    func handleImportResult(_ result: Result<[URL], Error>) {
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

    func startURLImport() {
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

    func suggestedRemoteImportFileName(from url: URL, response: URLResponse) -> String {
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

    func importReportAlertMessage(_ report: WorldbookImportReport) -> String {
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


struct WorldbookEntryDetailView: View {
    @State var entry: WorldbookEntry

    let onSave: (WorldbookEntry) -> Void

    init(entry: WorldbookEntry, onSave: @escaping (WorldbookEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.onSave = onSave
    }

    var enabledBinding: Binding<Bool> {
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


func worldbookPositionLabel(_ position: WorldbookPosition) -> String {
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


func worldbookSelectiveLogicLabel(_ logic: WorldbookSelectiveLogic) -> String {
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


func worldbookEntryRoleLabel(_ role: WorldbookEntryRole) -> String {
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


func parseKeywordList(_ raw: String) -> [String] {
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


extension String {
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


struct WorldbookExportDocument: FileDocument {
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

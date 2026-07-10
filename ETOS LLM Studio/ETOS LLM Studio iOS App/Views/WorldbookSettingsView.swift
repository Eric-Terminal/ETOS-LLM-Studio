// ============================================================================
// WorldbookSettingsView.swift
// ============================================================================
// WorldbookSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import UniformTypeIdentifiers
import ETOSCore

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
    @State private var importDownloadProgress: SyncPackageDownloadProgress?
    @State private var isShowingIntroDetails = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("世界书", comment: "Worldbook intro title"),
                    summary: NSLocalizedString("按规则在发送消息时自动激活并注入，独立于记忆系统。", comment: "Worldbook intro summary"),
                    details: NSLocalizedString("世界书说明正文", comment: "Worldbook intro details"),
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
                    WorldbookDownloadProgressView(progress: importDownloadProgress)
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
                            WorldbookDownloadProgressView(progress: importDownloadProgress)
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
            Text(NSLocalizedString(title, comment: "世界书信息行标题"))
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
            Task.detached(priority: .userInitiated) {
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
        importDownloadProgress = nil

        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                let (downloadedURL, response) = try await SyncPackageUploadService.downloadTemporaryFile(
                    request: request,
                    progress: { progress in
                        Task { @MainActor in
                            importDownloadProgress = progress
                        }
                    }
                )
                defer { try? FileManager.default.removeItem(at: downloadedURL) }
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        importError = String(
                            format: NSLocalizedString("下载失败：HTTP %d", comment: "HTTP status code failure"),
                            httpResponse.statusCode
                        )
                        isImportingFromURL = false
                        importDownloadProgress = nil
                    }
                    return
                }

                let data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: downloadedURL)
                }.value
                await MainActor.run {
                    importDownloadProgress = SyncPackageDownloadProgress(
                        bytesReceived: Int64(data.count),
                        totalBytes: Int64(data.count)
                    )
                }
                let fileName = suggestedRemoteImportFileName(from: url, response: response)
                let report = try await Task.detached(priority: .userInitiated) {
                    try ChatService.shared.importWorldbook(data: data, fileName: fileName)
                }.value
                await MainActor.run {
                    importReport = report
                    importError = report.failureReasons.isEmpty ? nil : report.failureReasons.joined(separator: "\n")
                    showImportReportAlert = true
                    reloadWorldbooks()
                    importURLText = ""
                    isImportingFromURL = false
                    importDownloadProgress = nil
                    isURLImportSheetPresented = false
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    isImportingFromURL = false
                    importDownloadProgress = nil
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

private struct WorldbookDownloadProgressView: View {
    let progress: SyncPackageDownloadProgress?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(NSLocalizedString("正在下载并导入...", comment: "Downloading and importing"))
                Spacer()
                if let progress, progress.totalBytes > 0 {
                    Text(String(format: "%.0f%%", progress.fractionCompleted * 100))
                        .monospacedDigit()
                } else {
                    ProgressView()
                }
            }
            .etFont(.footnote)

            if let progress, progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                Text(
                    String(
                        format: NSLocalizedString("已下载 %@ / %@", comment: ""),
                        StorageUtility.formatTransferSize(progress.bytesReceived),
                        StorageUtility.formatTransferSize(progress.totalBytes)
                    )
                )
                .etFont(.caption)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

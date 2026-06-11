// ============================================================================
// WorldbookSettingsView.swift
// ============================================================================
// WorldbookSettingsView 界面 (watchOS)
// - 负责该功能在 watchOS 端的交互与展示
// - 适配手表端交互与布局约束
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct WorldbookSettingsView: View {
    @ObservedObject var viewModel: ChatViewModel

    @State private var worldbooks: [Worldbook] = []
    @State private var selected = Set<UUID>()
    @State private var worldbookToDelete: Worldbook?
    @State private var importURLText: String = ""
    @State private var isImportingFromURL = false
    @State private var importDownloadProgress: SyncPackageDownloadProgress?
    @State private var importError: String?
    @State private var importReport: WorldbookImportReport?
    @State private var isShowingIntroDetails = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("世界书", comment: "Worldbook intro title"),
                    summary: NSLocalizedString("按关键词规则注入上下文，不会写入记忆系统。", comment: "Watch worldbook intro summary"),
                    details: NSLocalizedString("世界书说明正文", comment: "Worldbook intro details"),
                    isExpanded: $isShowingIntroDetails
                )
            }

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
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(worldbooks) { book in
                        NavigationLink {
                            WatchWorldbookDetailView(worldbookID: book.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.name)

                                Text(enabledEntrySummary(for: book))
                                    .etFont(.caption2)
                                    .foregroundStyle(.secondary)

                                if !book.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(book.description)
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                if selected.contains(book.id) {
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
                    WorldbookDownloadProgressView(progress: importDownloadProgress)
                }

                Text(NSLocalizedString("支持 http/https 的 JSON 或 PNG 链接。", comment: "Supported URL formats"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let report = importReport {
                Section(NSLocalizedString("最近导入结果", comment: "Latest import result section")) {
                    row(title: NSLocalizedString("新增条目", comment: "Imported entries"), value: "\(report.importedEntries)")
                    row(title: NSLocalizedString("跳过条目", comment: "Skipped entries"), value: "\(report.skippedEntries)")
                    row(title: NSLocalizedString("失败条目", comment: "Failed entries"), value: "\(report.failedEntries)")
                    if !report.failureReasons.isEmpty {
                        Text(report.failureReasons.joined(separator: "\n"))
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let importError, !importError.isEmpty {
                Section(NSLocalizedString("导入错误", comment: "Import error section")) {
                    Text(importError)
                        .etFont(.caption2)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString(title, comment: "世界书介绍卡片标题"))
                .etFont(.footnote.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "世界书介绍卡片摘要"))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .sheet(isPresented: isExpanded) {
            ScrollView {
                Text(NSLocalizedString(details, comment: "世界书介绍卡片详情"))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
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
                    importURLText = ""
                    isImportingFromURL = false
                    importDownloadProgress = nil
                    load()
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

}

private struct WorldbookDownloadProgressView: View {
    let progress: SyncPackageDownloadProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
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
            .etFont(.caption2)

            if let progress, progress.totalBytes > 0 {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                Text(
                    String(
                        format: NSLocalizedString("已下载 %@ / %@", comment: ""),
                        StorageUtility.formatSize(progress.bytesReceived),
                        StorageUtility.formatSize(progress.totalBytes)
                    )
                )
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

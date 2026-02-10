import SwiftUI
import UniformTypeIdentifiers
import Shared

struct WorldbookSettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    @State private var worldbooks: [Worldbook] = []
    @State private var isImporting = false
    @State private var importError: String?
    @State private var importReport: WorldbookImportReport?
    @State private var showImportReportAlert = false

    var body: some View {
        List {
            Section(NSLocalizedString("世界书说明", comment: "Worldbook description section")) {
                Text(NSLocalizedString("世界书会在发送消息时按规则自动激活并注入，不会写入长期记忆。", comment: "Worldbook intro"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.currentSession != nil {
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
                            Text("\((viewModel.currentSession?.worldbookIDs.count ?? 0))")
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
                                    if isBoundToCurrentSession(book) {
                                        Text(NSLocalizedString("已绑定", comment: "Bound tag"))
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.thinMaterial, in: Capsule())
                                    }
                                    Spacer()
                                    Toggle("启用", isOn: bindingForBookEnabled(book.id))
                                        .labelsHidden()
                                }

                                Text(String(
                                    format: NSLocalizedString("条目 %d · 更新于 %@", comment: "Entry count and update time"),
                                    book.entries.count,
                                    book.updatedAt.formatted(date: .abbreviated, time: .shortened)
                                ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                ChatService.shared.deleteWorldbook(id: book.id)
                                reloadWorldbooks()
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("世界书", comment: "Worldbook nav title"))
        .onAppear(perform: reloadWorldbooks)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.json, .png],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
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
        viewModel.currentSession?.worldbookIDs.contains(worldbook.id) ?? false
    }

    private func bindingForBookEnabled(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                worldbooks.first(where: { $0.id == id })?.isEnabled ?? false
            },
            set: { enabled in
                guard var target = worldbooks.first(where: { $0.id == id }) else { return }
                target.isEnabled = enabled
                target.updatedAt = Date()
                ChatService.shared.saveWorldbook(target)
                reloadWorldbooks()
            }
        )
    }

    private func reloadWorldbooks() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
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

    var body: some View {
        List {
            if let worldbook {
                Section(NSLocalizedString("基本信息", comment: "Basic info")) {
                    TextField(NSLocalizedString("世界书名称", comment: "Worldbook name field"), text: $nameDraft)
                        .onSubmit {
                            saveName()
                        }
                    Text(String(format: NSLocalizedString("条目数量：%d", comment: "Entry count"), worldbook.entries.count))
                        .foregroundStyle(.secondary)
                }

                Section(NSLocalizedString("条目", comment: "Entries section")) {
                    if worldbook.entries.isEmpty {
                        Text(NSLocalizedString("暂无条目", comment: "No entries"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(worldbook.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.comment.isEmpty ? NSLocalizedString("(无注释)", comment: "No comment") : entry.comment)
                                    .font(.subheadline)
                                Text(entry.content)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                Text(String(format: NSLocalizedString("关键词：%@", comment: "Keywords"), entry.keys.joined(separator: "，")))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
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
        .onAppear(perform: reload)
    }

    private func reload() {
        let book = ChatService.shared.loadWorldbooks().first(where: { $0.id == worldbookID })
        worldbook = book
        nameDraft = book?.name ?? ""
    }

    private func saveName() {
        guard var worldbook else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameDraft = worldbook.name
            return
        }
        worldbook.name = trimmed
        worldbook.updatedAt = Date()
        ChatService.shared.saveWorldbook(worldbook)
        self.worldbook = worldbook
    }
}

private struct WorldbookSessionBindingView: View {
    @Binding var currentSession: ChatSession?

    @State private var worldbooks: [Worldbook] = []
    @State private var selected = Set<UUID>()

    var body: some View {
        List {
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
                            if selected.contains(book.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(NSLocalizedString("会话绑定世界书", comment: "Session binding title"))
        .onAppear(perform: load)
    }

    private func load() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
        selected = Set(currentSession?.worldbookIDs ?? [])
    }

    private func toggle(_ id: UUID) {
        guard var session = currentSession else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        session.worldbookIDs = selected.sorted(by: { $0.uuidString < $1.uuidString })
        currentSession = session
        ChatService.shared.assignWorldbooks(to: session.id, worldbookIDs: session.worldbookIDs)
    }
}

import AppKit
import ETOSCore
import SwiftUI

struct MacAppLogsView: View {
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var logs = AppLogCenter.shared
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var deletingDay: AppLogDayFolder?
    @State private var clearing = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "app-logs", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 应用日志使用说明", value: "Browse logs by date and launch. Filter the user or developer channel and copy individual entries. Request bodies are recorded only when explicitly enabled. Deleting local logs cannot be undone; the page guide cannot read log contents.", comment: ""),
                    documentID: "mac-app-information", isActive: available)
                Toggle(NSLocalizedString("启用 API 请求日志", comment: ""), isOn: $configuration.requestLogEnabled)
                Toggle(NSLocalizedString("记录请求明文消息", comment: ""), isOn: $configuration.requestLogPlainMessageEnabled)
                    .disabled(!configuration.requestLogEnabled)
            }
            ForEach(logs.logDayFolders) { day in
                Section(day.day) {
                    ForEach(day.runs) { run in
                        NavigationLink { MacLogRunView(run: run, isActive: available) } label: {
                            VStack(alignment: .leading) {
                                Text(run.fileName)
                                Text(run.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletingDay = day }
                }
            }
        }
        .navigationTitle(NSLocalizedString("应用日志", comment: ""))
        .disabled(!available)
        .task { if available { await logs.refreshLogFolders() } }
        .toolbar { Button(NSLocalizedString("清空", comment: ""), role: .destructive) { clearing = true } }
        .confirmationDialog(NSLocalizedString("删除日志", comment: ""), isPresented: Binding(
            get: { deletingDay != nil || clearing }, set: { if !$0 { deletingDay = nil; clearing = false } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard available else { return }
                if clearing { logs.clearAll() } else if let deletingDay { logs.deleteDayFolder(deletingDay) }
                deletingDay = nil; clearing = false
            }
        }
        .guideSettingsPageContext(id: "mac-app-logs", title: NSLocalizedString("应用日志", comment: ""),
            documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("应用日志", comment: ""))],
            isActive: available, settings: [
                .bool("request_logging", label: NSLocalizedString("启用 API 请求日志", comment: ""), get: { configuration.requestLogEnabled }, set: { configuration.requestLogEnabled = $0 }),
                .bool("request_plaintext", label: NSLocalizedString("记录请求明文消息", comment: ""), get: { configuration.requestLogPlainMessageEnabled }, set: { configuration.requestLogPlainMessageEnabled = $0 }),
                .readOnly("days", label: NSLocalizedString("应用日志", comment: ""), value: { .int(logs.logDayFolders.count) })
            ])
    }
}

private struct MacLogRow: Identifiable, Sendable {
    let event: AppLogEvent
    let preview: String
    var id: UUID { event.id }
}

private struct MacLogRunView: View {
    let run: AppLogRunFile
    let isActive: Bool
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var logs = AppLogCenter.shared
    @State private var channel = AppLogChannel.user
    @State private var filter = AppLogFilter()
    @State private var rows: [MacLogRow] = []
    @State private var deleting = false
    @State private var preparation: Task<Void, Never>?
    @State private var visible = false
    private var available: Bool { isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("日志类型", comment: ""), selection: $channel) {
                    ForEach(AppLogChannel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker(NSLocalizedString("级别", comment: ""), selection: $filter.level) {
                    Text(NSLocalizedString("全部", comment: "")).tag(AppLogLevel?.none)
                    ForEach(AppLogLevel.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                TextField(NSLocalizedString("搜索", comment: ""), text: $filter.keyword)
                TextField(NSLocalizedString("分类", comment: ""), text: $filter.categoryKeyword)
                Toggle(NSLocalizedString("仅看配置变更", comment: ""), isOn: $filter.configChangesOnly)
            }
            ForEach(rows) { row in
                NavigationLink { MacLogEventView(event: row.event, isActive: available) } label: {
                    VStack(alignment: .leading) {
                        Text(row.preview).lineLimit(3)
                        HStack { Text(row.event.timestamp, style: .time); Text(row.event.level.displayName); Text(row.event.category) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(run.fileName)
        .disabled(!available)
        .onAppear { visible = true; prepare() }
        .onChange(of: filter) { _, _ in prepare() }
        .onChange(of: channel) { _, _ in prepare() }
        .onReceive(logs.$mergedLogs) { _ in prepare() }
        .onDisappear { visible = false; preparation?.cancel() }
        .onChange(of: available) { _, active in if !active { preparation?.cancel(); rows = [] } }
        .toolbar { Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deleting = true } }
        .confirmationDialog(NSLocalizedString("删除日志", comment: ""), isPresented: $deleting, titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard available else { return }; logs.deleteRunFile(run); dismiss()
            }
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-log-run-\(run.id)"), title: NSLocalizedString("应用日志", comment: ""),
            documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("应用日志", comment: ""))],
            isActive: available && visible, settings: [
                .string("channel", label: NSLocalizedString("日志类型", comment: ""), allowedValues: ["user", "developer"], get: { channel.rawValue }, set: { channel = AppLogChannel(rawValue: $0) ?? .user }),
                .bool("config_changes", label: NSLocalizedString("仅看配置变更", comment: ""), get: { filter.configChangesOnly }, set: { filter.configChangesOnly = $0 }),
                .string("level", label: NSLocalizedString("级别", comment: ""), allowedValues: ["all", "debug", "info", "warning", "error"], get: { filter.level?.rawValue ?? "all" }, set: { filter.level = AppLogLevel(rawValue: $0) }),
                .readOnly("has_keyword", label: NSLocalizedString("搜索", comment: ""), value: { .bool(!filter.keyword.isEmpty) }),
                .readOnly("has_category", label: NSLocalizedString("分类", comment: ""), value: { .bool(!filter.categoryKeyword.isEmpty) }),
                .readOnly("count", label: NSLocalizedString("应用日志", comment: ""), value: { .int(rows.count) })
            ])
    }

    private func prepare() {
        preparation?.cancel()
        guard available, visible else { return }
        let filter = filter, channel = channel
        preparation = Task {
            // 文件读取由 Core 的文件 actor 负责，过滤和摘要不进入列表渲染链路。
            let events = await logs.loadEvents(for: run)
            let prepared = await Task.detached(priority: .utility) {
                AppLogFilterEngine.filter(events.compactMap { $0.presented(in: channel) }, with: filter)
                    .reversed().map { MacLogRow(event: $0, preview: String($0.message.prefix(400))) }
            }.value
            if !Task.isCancelled && available { rows = prepared }
        }
    }
}

private struct MacLogEventView: View {
    let event: AppLogEvent
    let isActive: Bool
    @State private var pages: [AppLogTextPage] = []
    @State private var text = ""
    var body: some View {
        List {
            LabeledContent(NSLocalizedString("时间", comment: "")) { Text(event.timestamp, style: .date) }
            LabeledContent(NSLocalizedString("分类", comment: ""), value: event.category)
            LabeledContent(NSLocalizedString("操作", comment: ""), value: event.action)
            ForEach(pages) { page in Text(page.content).font(.body.monospaced()).textSelection(.enabled) }
        }
        .navigationTitle(NSLocalizedString("日志详情", comment: ""))
        .toolbar { Button(NSLocalizedString("复制", comment: "")) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }.disabled(!isActive) }
        .task {
            let prepared = await Task.detached(priority: .utility) {
                let payload = (event.payload ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key):\n\($0.value)" }.joined(separator: "\n\n")
                let text = event.message + (payload.isEmpty ? "" : "\n\n" + payload)
                return (text, AppLogTextPaginator.paginate(text))
            }.value
            if !Task.isCancelled && isActive { text = prepared.0; pages = prepared.1 }
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-log-event-\(event.id)"), title: NSLocalizedString("日志详情", comment: ""),
            documents: [GuideDocumentReference(id: "mac-app-information", title: NSLocalizedString("应用日志", comment: ""))],
            isActive: isActive, settings: [
                .readOnly("level", label: NSLocalizedString("级别", comment: ""), value: { .string(event.level.rawValue) }),
                .readOnly("content_private", label: NSLocalizedString("日志详情", comment: ""), value: { .bool(true) })
            ])
    }
}

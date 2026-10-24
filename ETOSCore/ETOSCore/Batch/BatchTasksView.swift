import SwiftUI

/// 平台入口注入各自的向导工具栏；列表、详情和草稿共享同一任务状态。
public struct BatchTasksView: View {
    @StateObject private var model = BatchTasksModel()
    @ObservedObject private var appConfig = AppConfigStore.shared
    private let isActive: Bool
    private let pageChrome: @MainActor @Sendable (AnyView) -> AnyView

    public init(isActive: Bool = true, pageChrome: @escaping @MainActor @Sendable (AnyView) -> AnyView = { $0 }) {
        self.isActive = isActive
        self.pageChrome = pageChrome
    }

    public var body: some View {
        pageChrome(AnyView(list))
            .task { await model.reload() }
            .onReceive(NotificationCenter.default.publisher(for: .batchJobsChanged)) { _ in
                Task { await model.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .snapshotRestoreDidFinish)) { _ in
                Task { await model.reload() }
            }
            .onChange(of: appConfig.appLanguage) { _, _ in
                Task { await model.reload() }
            }
            .alert(NSLocalizedString("错误", comment: ""), isPresented: Binding(
                get: { model.error != nil }, set: { if !$0 { model.error = nil } }
            )) {
                Button(NSLocalizedString("好", comment: ""), role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }

    private var list: some View {
        List {
            Section {
                settingsIntroCard
                // 设置父页面使用视图导航；这里保持一致，避免值导航弹出父页面并丢失草稿。
                NavigationLink {
                    pageChrome(AnyView(BatchEditorView(model: model, isActive: isActive,
                        pageChrome: { view in pageChrome(view) })))
                } label: {
                    Label(NSLocalizedString("batch.new", value: "New Batch", comment: "新建批量任务"), systemImage: "plus")
                }
                .accessibilityIdentifier("batch.new")
                Button {
                    Task { await model.perform { await BatchService.shared.refreshPending(force: true) } }
                } label: {
                    Label(NSLocalizedString("batch.refresh", value: "Refresh Tasks", comment: "刷新批量任务"), systemImage: "arrow.clockwise")
                }
                .disabled(model.busy)
            }
            if let notice = model.submissionNotice {
                Section {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                if model.snapshot.jobs.isEmpty {
                    Text(NSLocalizedString("batch.empty", value: "No batch tasks yet.", comment: "批量任务空状态"))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.snapshot.jobs) { job in
                    NavigationLink {
                        pageChrome(AnyView(BatchJobDetailView(model: model, id: job.id,
                            isActive: isActive, pageChrome: { view in pageChrome(view) })))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(job.title)
                            Text(job.model).font(.caption).foregroundStyle(.secondary)
                            Text(job.status).font(.caption).foregroundStyle(.secondary)
                            Text(job.progress).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("batch.tasks", value: "Tasks", comment: "批量任务列表"))
            } footer: {
                Text(NSLocalizedString("batch.refresh.footer", value: "Tasks run on the provider's servers. Open the app or refresh to retrieve results.", comment: "批量刷新说明"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("batch.title", value: "Batch Tasks", comment: "批量任务标题"))
        .guideSettingsPageContext(id: "batch-tasks", title: NSLocalizedString("batch.title", value: "Batch Tasks", comment: ""),
            documents: BatchGuideSupport.documents, isActive: isActive,
            settings: [.readOnly("job_count", label: NSLocalizedString("batch.tasks", value: "Tasks", comment: ""), value: { .int(model.snapshot.jobs.count) })])
    }

    private var settingsIntroCard: some View {
        NavigationLink {
            pageChrome(AnyView(BatchIntroductionView(isActive: isActive)))
        } label: {
            VStack(alignment: .leading) {
                Text(NSLocalizedString("batch.help.title", value: "Using Batch Tasks", comment: "批量介绍标题"))
                Text(NSLocalizedString("batch.help.summary", value: "Send independent requests together and collect their results later.", comment: "批量介绍摘要"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("batch.introduction")
    }
}

private struct BatchJobDetailView: View {
    @ObservedObject var model: BatchTasksModel
    let id: UUID
    let isActive: Bool
    let pageChrome: @MainActor @Sendable (AnyView) -> AnyView
    @Environment(\.dismiss) private var dismiss
    @State private var action: String?
    private var job: BatchJobRow? { model.snapshot.byID[id] }

    var body: some View {
        List {
            if let job {
                Section {
                    Text(job.model)
                    Text(job.status)
                    Text(job.progress).font(.caption).foregroundStyle(.secondary)
                    Text(job.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    if let remoteID = job.remoteID { Text(remoteID).font(.caption).foregroundStyle(.secondary) }
                    if let error = job.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    if job.remoteID != nil {
                        Button(NSLocalizedString("batch.refresh", value: "Refresh Tasks", comment: "")) {
                            Task { await model.perform { try await BatchService.shared.refresh(id: id) } }
                        }
                    }
                    if job.canResume {
                        Button(NSLocalizedString("batch.recover", value: "Resume or Recover Submission", comment: "批量恢复提交")) { action = "recover" }
                    }
                    if job.canCancel {
                        Button(NSLocalizedString("batch.cancel", value: "Cancel Remote Task", comment: "取消远端批量任务"), role: .destructive) { action = "cancel" }
                    }
                    if job.canRetry {
                        Button(NSLocalizedString("batch.retry", value: "Retry Failed Requests", comment: "批量失败重试")) { action = "retry" }
                    }
                    #if !os(watchOS)
                    if job.canExport {
                        Button(NSLocalizedString("batch.export", value: "Prepare JSONL Export", comment: "批量导出")) {
                            Task { await model.export(id: id) }
                        }
                        if model.exportJobID == id, let url = model.exportURL {
                            ShareLink(item: url) {
                                Label(NSLocalizedString("batch.share", value: "Share JSONL", comment: "分享批量结果"), systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    #endif
                    if job.canRemove {
                        Button(NSLocalizedString("batch.remove", value: "Remove Local Record", comment: "删除本地批量任务"), role: .destructive) { action = "remove" }
                    }
                }
                .disabled(model.busy)
                Section(NSLocalizedString("batch.results", value: "Results", comment: "批量结果")) {
                    ForEach(job.results) { result in
                        NavigationLink {
                            pageChrome(AnyView(BatchResultDetailView(model: model, jobID: id,
                                resultID: result.id, isActive: isActive)))
                        } label: {
                            VStack(alignment: .leading) {
                                Text(result.preview).lineLimit(3)
                                Label(result.isPending
                                      ? NSLocalizedString("batch.result.pending", value: "Awaiting results", comment: "结果尚未下载")
                                      : result.error == nil
                                      ? NSLocalizedString("batch.status.completed", value: "Completed", comment: "")
                                      : NSLocalizedString("batch.status.failed", value: "Failed", comment: ""),
                                      systemImage: result.isPending ? "clock" : result.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let error = result.error { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(job?.title ?? NSLocalizedString("batch.title", value: "Batch Tasks", comment: ""))
        .onAppear { model.exportURL = nil }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "batch-job-\(id.uuidString)"), title: NSLocalizedString("batch.title", value: "Batch Tasks", comment: ""),
            documents: BatchGuideSupport.documents, isActive: isActive && action == nil,
            settings: [
                .readOnly("status", label: NSLocalizedString("batch.tasks", value: "Tasks", comment: ""), value: { .string(job?.status ?? "") }),
                .readOnly("progress", label: NSLocalizedString("batch.results", value: "Results", comment: ""), value: { .string(job?.progress ?? "") })
            ])
        .confirmationDialog(NSLocalizedString("batch.action.confirm", value: "Confirm task operation", comment: "批量操作确认"),
            isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), titleVisibility: .visible) {
            let selected = action
            Button(NSLocalizedString("确认", comment: ""), role: selected == "remove" || selected == "cancel" ? .destructive : nil) {
                action = nil
                Task {
                    await model.perform {
                        switch selected {
                        case "recover": try await BatchService.shared.resumeSubmission(id: id)
                        case "cancel": try await BatchService.shared.refresh(id: id, cancel: true)
                        case "retry": try await BatchService.shared.retryFailures(id: id)
                        case "remove": try await BatchService.shared.remove(id: id)
                        default: break
                        }
                    }
                    if selected == "remove", model.snapshot.byID[id] == nil { dismiss() }
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { action = nil }
        } message: {
            Text(NSLocalizedString("batch.action.notice", value: "Retrying creates a new billable task. Cancelling keeps completed results. Removing a record only deletes its local copy.", comment: "批量操作影响"))
        }
    }
}

private struct BatchResultDetailView: View {
    @ObservedObject var model: BatchTasksModel
    let jobID: UUID
    let resultID: String
    let isActive: Bool
    private var result: BatchResultRow? { model.snapshot.byID[jobID]?.resultsByID[resultID] }

    var body: some View {
        List {
            if let result {
                Section(NSLocalizedString("batch.input", value: "Input", comment: "批量原始输入")) { Text(result.input) }
                Section(NSLocalizedString("batch.output", value: "Output", comment: "批量输出")) {
                    if result.isPending {
                        Text(NSLocalizedString("batch.result.pending", value: "Awaiting results", comment: "结果尚未下载"))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(result.error ?? result.text)
                            #if !os(watchOS)
                            .textSelection(.enabled)
                            #endif
                    }
                }
                if let reasoning = result.reasoning, !reasoning.isEmpty {
                    Section(NSLocalizedString("思考过程", comment: "")) { Text(reasoning) }
                }
            }
        }
        .navigationTitle(NSLocalizedString("batch.results", value: "Results", comment: ""))
        .guideSettingsPageContext(id: GuidePageID(rawValue: "batch-result-\(jobID.uuidString)-\(resultID)"),
            title: NSLocalizedString("batch.results", value: "Results", comment: ""), documents: BatchGuideSupport.documents, isActive: isActive,
            settings: [.readOnly("read_only", label: NSLocalizedString("batch.results", value: "Results", comment: ""), value: { .bool(true) })])
    }
}

private struct BatchIntroductionView: View {
    let isActive: Bool
    var body: some View {
        ScrollView {
            Text(NSLocalizedString("batch.help.body", value: "Add each request separately to preserve its line breaks. Use Add Multiple Lines only when each nonempty line should become a separate request; check the count before saving. Search and filter models by provider, or show only selected models. Bulk selection affects only shown models. Review the models and total request count before submitting. Each model gets a separate task. Compatible API format does not guarantee Batch availability; provider pricing and limits apply.\n\nTasks run asynchronously on the server and may take up to 24 hours. The app refreshes periodically while active and resumes when reopened. Notifications arrive after results are retrieved; they are not guaranteed while the app is suspended.\n\nRefresh a task to save its results, including partial results from cancelled or expired tasks. Retry Failed Requests sends only failed items as a new task. If submission is uncertain, recover it first and check the provider dashboard before submitting again. Keep the original provider address, headers and API key available.\n\nTasks and results are stored in the chat database and included in snapshot backups and phone/watch chat database sync. Sync the provider configuration as well. iOS and macOS can share JSONL results; watch users can sync to iPhone to export. Removing a local record does not delete remote files.\n\nThe page guide can edit the new-task draft after confirmation, but cannot submit, cancel, retry, delete or export tasks. Requests do not include chat history, attachments or app tools.", comment: "批量完整使用说明"))
                .font(.footnote).foregroundStyle(.secondary).padding()
        }
        .navigationTitle(NSLocalizedString("batch.help.title", value: "Using Batch Tasks", comment: ""))
        .guideSettingsPageContext(id: "batch-introduction", title: NSLocalizedString("batch.help.title", value: "Using Batch Tasks", comment: ""),
            documents: BatchGuideSupport.documents, isActive: isActive,
            settings: [.readOnly("read_only", label: NSLocalizedString("使用说明", comment: ""), value: { .bool(true) })])
    }
}

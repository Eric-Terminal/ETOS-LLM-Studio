import SwiftUI

struct BatchEditorView: View {
    @ObservedObject var model: BatchTasksModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @StateObject private var draft = BatchDraftModel()
    @Environment(\.dismiss) private var dismiss
    @State private var editingRequest: BatchDraftRequest?
    @State private var importingLines = false
    @State private var reviewsSubmission = false
    @State private var submitted = false
    let isActive: Bool
    let pageChrome: @MainActor @Sendable (AnyView) -> AnyView

    var body: some View {
        Form {
            Section {
                TextField(NSLocalizedString("batch.name.optional", value: "Name (optional)", comment: "任务名称"), text: $draft.title)
            }
            Section {
                ForEach(draft.requests) { request in
                    Button {
                        importingLines = false
                        editingRequest = request
                    } label: {
                        Text(request.preview).lineLimit(3).foregroundStyle(.primary)
                    }
                }
                .onDelete { draft.removeRequests(at: $0) }
                Button {
                    importingLines = false
                    editingRequest = BatchDraftRequest(text: "")
                } label: {
                    Label(NSLocalizedString("batch.add", value: "Add Request", comment: ""), systemImage: "plus")
                }
                .accessibilityIdentifier("batch.request.add")
                Button {
                    importingLines = true
                    editingRequest = BatchDraftRequest(text: "")
                } label: {
                    Label(NSLocalizedString("batch.requests.paste", value: "Add Multiple Lines", comment: "明确按行拆分的批量输入"), systemImage: "text.badge.plus")
                }
                .accessibilityIdentifier("batch.request.import")
            } header: {
                Text(NSLocalizedString("batch.requests", value: "Requests", comment: ""))
            } footer: {
                Text(NSLocalizedString("batch.requests.footer", value: "Add requests separately. Line breaks stay within a request. No chat history or attachments are included.", comment: "独立请求说明"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink {
                    pageChrome(AnyView(BatchModelPickerView(draft: draft, isActive: isActive)))
                } label: {
                    VStack(alignment: .leading) {
                        Text(NSLocalizedString("batch.models.choose", value: "Choose Models", comment: "模型选择入口"))
                        if !draft.selectedIDs.isEmpty {
                            Text(draft.snapshot.modelSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("batch.models.choose")
                if model.snapshot.models.isEmpty {
                    Text(NSLocalizedString("batch.models.empty", value: "Enable an OpenAI-compatible chat model in Model Management first.", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(NSLocalizedString("batch.models", value: "Models", comment: ""))
            } footer: {
                Text(NSLocalizedString("batch.models.compatibility", value: "These models use a compatible API format. Batch availability and pricing still depend on the provider.", comment: "不将协议兼容误称为已经支持"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text(draft.snapshot.summary).font(.footnote).foregroundStyle(.secondary)
                Button(NSLocalizedString("batch.review", value: "Review Batch", comment: "提交前核对")) {
                    model.error = nil
                    reviewsSubmission = true
                }
                .disabled(!draft.canSubmit || model.busy)
                .accessibilityIdentifier("batch.review")
            }
        }
        .navigationTitle(NSLocalizedString("batch.new", value: "New Batch", comment: ""))
        .onAppear { draft.configure(models: model.snapshot.models) }
        .onChange(of: model.snapshot.models) { _, options in draft.configure(models: options) }
        .onChange(of: appConfig.appLanguage) { _, _ in draft.configure(models: model.snapshot.models) }
        .guideSettingsPageContext(id: "batch-editor", title: NSLocalizedString("batch.new", value: "New Batch", comment: ""),
            documents: BatchGuideSupport.documents, isActive: isActive && editingRequest == nil && !reviewsSubmission,
            settings: draft.guideSettings)
        .sheet(item: $editingRequest) { request in
            NavigationStack {
                pageChrome(AnyView(BatchRequestEditorView(draft: draft, request: request, splitsLines: importingLines, isActive: isActive)))
            }
        }
        .sheet(isPresented: $reviewsSubmission, onDismiss: {
            if submitted { dismiss() }
        }) {
            NavigationStack {
                pageChrome(AnyView(BatchReviewView(model: model, draft: draft, isActive: isActive) {
                    submitted = true
                    reviewsSubmission = false
                }))
            }
        }
    }
}

private struct BatchRequestEditorView: View {
    @ObservedObject var draft: BatchDraftModel
    @ObservedObject private var appConfig = AppConfigStore.shared
    @StateObject private var editor: BatchRequestEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    let request: BatchDraftRequest
    let splitsLines: Bool
    let isActive: Bool

    init(draft: BatchDraftModel, request: BatchDraftRequest, splitsLines: Bool, isActive: Bool) {
        self.draft = draft
        self.request = request
        self.isActive = isActive
        self.splitsLines = splitsLines
        _editor = StateObject(wrappedValue: BatchRequestEditorModel(text: request.text, splitsLines: splitsLines))
    }

    private var title: String {
        splitsLines ? NSLocalizedString("batch.requests.paste", value: "Add Multiple Lines", comment: "")
            : NSLocalizedString("batch.request.edit", value: "Edit Request", comment: "")
    }

    private var footer: String {
        splitsLines
            ? NSLocalizedString("batch.requests.lines.footer", value: "Each nonempty line will become a separate request. To keep line breaks in one request, use Add Request instead. Save to add these requests to the draft.", comment: "显式按行导入说明")
            : NSLocalizedString("batch.request.footer", value: "This entire text is one request, including line breaks. Save to add it to your batch draft.", comment: "请求编辑边界")
    }

    var body: some View {
        Form {
            Section {
                #if os(watchOS)
                TextField(NSLocalizedString("batch.input", value: "Input", comment: ""), text: $editor.text)
                #else
                TextEditor(text: $editor.text)
                    .frame(minHeight: 180)
                    .accessibilityLabel(NSLocalizedString("batch.input", value: "Input", comment: ""))
                #endif
            } footer: {
                Text(footer)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if splitsLines {
                Section { Text(editor.countSummary).font(.footnote).foregroundStyle(.secondary) }
            }
            if !splitsLines && !request.text.isEmpty {
                Section {
                    Button(NSLocalizedString("删除", comment: "删除未提交请求"), role: .destructive) {
                        draft.removeRequest(id: request.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(title)
        .onChange(of: appConfig.appLanguage) { _, _ in editor.refreshLanguage() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                    .disabled(saving)
                    .accessibilityIdentifier("batch.request.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    saving = true
                    let text = editor.text
                    Task {
                        if splitsLines { await draft.appendLines(text) }
                        else { await draft.saveRequest(id: request.id, text: text) }
                        dismiss()
                    }
                }
                .disabled(!editor.canSave || saving)
            }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving || editor.hasChanges)
        .guideSettingsPageContext(id: GuidePageID(rawValue: splitsLines ? "batch-request-import" : "batch-request-editor-\(request.id.uuidString)"),
            title: title,
            documents: BatchGuideSupport.documents, isActive: isActive && !saving,
            settings: [
                .string("text", label: NSLocalizedString("batch.input", value: "Input", comment: ""),
                        get: { editor.text }, set: { editor.text = $0 }),
                .readOnly("save_required", label: footer, value: { .bool(true) }),
                .readOnly("request_count", label: NSLocalizedString("batch.requests", value: "Requests", comment: ""),
                          value: { .string(editor.countSummary) })
            ])
    }
}

private struct BatchReviewView: View {
    @ObservedObject var model: BatchTasksModel
    @ObservedObject var draft: BatchDraftModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    let isActive: Bool
    let onSubmitted: () -> Void

    var body: some View {
        List {
            Section {
                if !draft.title.isEmpty { Text(draft.title) }
                Text(draft.snapshot.summary)
                Text(draft.snapshot.totalSummary).font(.footnote).foregroundStyle(.secondary)
            }
            Section(NSLocalizedString("batch.models", value: "Models", comment: "")) {
                ForEach(draft.snapshot.selectedModels) { option in
                    VStack(alignment: .leading) {
                        Text(option.name)
                        Text(option.providerName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text(NSLocalizedString("batch.review.notice", value: "Every request will be sent to every selected model. Tasks run asynchronously and may take up to 24 hours. Availability, charges and discounts depend on the provider.", comment: "提交前明确次数与异步处理"))
                    .font(.footnote).foregroundStyle(.secondary)
                if model.busy {
                    ProgressView(NSLocalizedString("batch.status.creating", value: "Submitting", comment: ""))
                } else {
                    Button(NSLocalizedString("batch.submit", value: "Submit Batch", comment: ""), action: submit)
                        .disabled(!draft.canSubmit)
                }
            }
        }
        .navigationTitle(NSLocalizedString("batch.review", value: "Review Batch", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.busy)
            }
        }
        .interactiveDismissDisabled(model.busy)
        .guideSettingsPageContext(id: "batch-review", title: NSLocalizedString("batch.review", value: "Review Batch", comment: ""),
            documents: BatchGuideSupport.documents, isActive: isActive && !model.busy,
            settings: [
                .readOnly("summary", label: NSLocalizedString("batch.review", value: "Review Batch", comment: ""),
                          value: { .string(draft.snapshot.totalSummary) }),
                .readOnly("models", label: NSLocalizedString("batch.models", value: "Models", comment: ""),
                          value: { .string(draft.snapshot.selectedNames) })
            ])
        .alert(NSLocalizedString("错误", comment: ""), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button(NSLocalizedString("好", comment: ""), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func submit() {
        guard draft.canSubmit, !model.busy else { return }
        let title = draft.title, inputs = draft.snapshot.inputs
        let ids = Array(draft.selectedIDs)
        let config = AppConfigStore.shared
        let temperature = config.aiTemperatureEnabled ? config.aiTemperature : nil
        let topP = config.aiTopPEnabled ? config.aiTopP : nil
        model.busy = true
        Task {
            defer { model.busy = false }
            do {
                _ = await AppLocalNotificationCenter.shared.requestAuthorizationIfNeeded()
                let report = try await BatchService.shared.submit(title: title, inputs: inputs, modelIDs: ids, temperature: temperature, topP: topP)
                model.submissionReport = report
                await model.reload()
                // 部分失败也返回已保存的任务列表，不能留在原表单让用户重复提交成功项。
                onSubmitted()
            } catch { self.error = error.localizedDescription }
        }
    }
}

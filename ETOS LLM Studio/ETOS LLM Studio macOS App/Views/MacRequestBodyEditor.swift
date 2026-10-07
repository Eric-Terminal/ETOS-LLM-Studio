import ETOSCore
import SwiftUI

struct MacRequestBodyEditor: View {
    let modelID: UUID
    let apiFormat: String
    let onSave: (MacRequestBodyDraft) -> Void
    @State private var draft: MacRequestBodyDraft
    @State private var editing: ModelRequestBodyControl?
    @State private var editsParameters = false
    @State private var importsControls = false
    @State private var preview = ""
    @State private var error: String?
    @State private var validatedDraft: MacRequestBodyDraft?
    @State private var busy = true
    @State private var revision = UUID()
    @State private var preparation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel

    init(model: Model, apiFormat: String, onSave: @escaping (MacRequestBodyDraft) -> Void) {
        modelID = model.id; self.apiFormat = apiFormat; self.onSave = onSave
        _draft = State(initialValue: MacRequestBodyDraft(model: model))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "request-body-\(modelID)", title: NSLocalizedString("自定义Body", comment: ""),
                                         details: NSLocalizedString("Mac 请求体控制使用说明", comment: ""), documentID: "model-request-body")
                    Button(NSLocalizedString("覆盖参数", comment: "")) { editsParameters = true }
                }
                Section {
                    ForEach(draft.controls) { control in
                        Button { editing = control } label: {
                            Label(control.title, systemImage: control.isEnabled ? "checkmark.circle" : "circle")
                        }.buttonStyle(.borderless)
                        .contextMenu {
                            Button(NSLocalizedString("上移", comment: "")) { move(control.id, by: -1) }
                            Button(NSLocalizedString("下移", comment: "")) { move(control.id, by: 1) }
                            Button(NSLocalizedString("复制", comment: "")) {
                                let source = control
                                Task {
                                    let copy = await Task.detached { source.duplicatedWithNewIdentifiers() }.value
                                    guard !workspace.isRestoringData else { return }
                                    draft.controls.append(copy)
                                }
                            }
                            Button(NSLocalizedString("删除", comment: ""), role: .destructive) { draft.controls.removeAll { $0.id == control.id } }
                        }
                    }
                    Button(NSLocalizedString("添加开关", comment: "")) { add(.toggle) }
                    Button(NSLocalizedString("添加选项组", comment: "")) { add(.optionGroup) }
                    Button(NSLocalizedString("从其他模型导入", comment: "")) { importsControls = true }
                } header: { Text(NSLocalizedString("结构化控制", comment: "")) }
                Section {
                    if busy { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                    else { Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                } header: { Text(NSLocalizedString("当前有效请求参数", comment: "")) } footer: {
                    Text(NSLocalizedString("Mac 默认请求参数预览说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("自定义Body", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        guard !busy, validatedDraft == draft, !workspace.isRestoringData else { return }
                        onSave(draft); dismiss()
                    }
                        .disabled(busy || error != nil || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-request-body-\(modelID)"), title: NSLocalizedString("自定义Body", comment: ""),
                documents: [GuideDocumentReference(id: "model-request-body", title: "Request Body Controls")], settings: [
                    .readOnly("editing_mode", label: NSLocalizedString("应用方式", comment: ""), value: { .string("model_then_provider_draft_until_save") }),
                    .readOnly("control_count", label: NSLocalizedString("结构化控制", comment: ""), value: { .int(draft.controls.count) }),
                    .readOnly("api_format", label: NSLocalizedString("API 格式", comment: ""), value: { .string(apiFormat) }),
                    .readOnly("valid", label: NSLocalizedString("配置有效", comment: ""), value: { .bool(!busy && error == nil) })
                ])
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 580, minHeight: 580)
        .sheet(isPresented: $editsParameters) {
            MacRequestParameterEditor(pageID: GuidePageID(rawValue: "mac-request-body-\(modelID)-parameters"), parameters: draft.parameters,
                                      mode: draft.mode, rawJSON: draft.mode == .rawJSON ? draft.rawJSON : nil) { values, mode, raw in
                draft.parameters = values; draft.mode = mode; draft.rawJSON = raw
            }
        }
        .sheet(item: $editing) { control in
            MacRequestControlEditor(modelID: modelID, control: control, mode: draft.mode) { values in
                guard !workspace.isRestoringData else { return }
                if let index = draft.controls.firstIndex(where: { $0.id == control.id }) { draft.controls.replaceSubrange(index...index, with: values) }
                else { draft.controls.append(contentsOf: values) }
            }
        }
        .sheet(isPresented: $importsControls) {
            MacRequestControlImportView(modelID: modelID) { controls in draft.controls.append(contentsOf: controls) }
        }
        .onAppear { refresh() }
        .onChange(of: draft) { _, _ in refresh() }
        .onDisappear { preparation?.cancel(); revision = UUID() }
        .onReceive(AppConfigStore.shared.$appLanguage.dropFirst()) { _ in refresh() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }

    private func refresh() {
        preparation?.cancel()
        revision = UUID()
        let token = revision, source = draft
        busy = true; validatedDraft = nil; preview = ""
        preparation = Task {
            let result = await Task.detached { Result { try source.preview() } }.value
            guard !Task.isCancelled, token == revision else { return }
            busy = false
            switch result {
            case .success(let value): preview = value; validatedDraft = source; error = nil
            case .failure(let failure): preview = ""; error = failure.localizedDescription
            }
        }
    }

    private func move(_ id: String, by delta: Int) {
        guard let index = draft.controls.firstIndex(where: { $0.id == id }), draft.controls.indices.contains(index + delta) else { return }
        draft.controls.swapAt(index, index + delta)
    }

    private func add(_ kind: ModelRequestBodyControl.Kind) {
        let controls = draft.controls, format = apiFormat
        Task {
            let control = await Task.detached {
                kind == .toggle ? ModelRequestBodyControlDefaults.initialToggleControl(existingControls: controls)
                    : ModelRequestBodyControlDefaults.initialOptionGroupControl(existingControls: controls, apiFormat: format)
            }.value
            guard !workspace.isRestoringData else { return }
            editing = control
        }
    }
}

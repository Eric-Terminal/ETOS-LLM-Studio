import ETOSCore
import SwiftUI

struct MacRequestControlEditor: View {
    let modelID: UUID
    let mode: Model.RequestBodyOverrideMode
    let onSave: ([ModelRequestBodyControl]) -> Void
    @State private var draft: MacRequestControlDraft
    @State private var editsPayload = false
    @State private var editingOption: ModelRequestBodyControlOption?
    @State private var prepared: ModelRequestBodyControl?
    @State private var preparedDraft: MacRequestControlDraft?
    @State private var optionIDs: [String] = []
    @State private var canSplit = false
    @State private var canSort = false
    @State private var error: String?
    @State private var busy = true
    @State private var revision = UUID()
    @State private var preparation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel

    init(modelID: UUID, control: ModelRequestBodyControl, mode: Model.RequestBodyOverrideMode, onSave: @escaping ([ModelRequestBodyControl]) -> Void) {
        self.modelID = modelID; self.mode = mode; self.onSave = onSave
        _draft = State(initialValue: MacRequestControlDraft(control))
    }

    private var pageID: GuidePageID { GuidePageID(rawValue: "mac-request-control-\(modelID)-\(draft.control.id)") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("显示名称", comment: ""), text: $draft.control.title)
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $draft.control.isEnabled)
                }
                if draft.control.kind == .toggle {
                    Section {
                        Toggle(NSLocalizedString("默认开启", comment: ""), isOn: $draft.control.defaultIsActive)
                        Button(NSLocalizedString("请求体参数", comment: "")) { editsPayload = true }
                    }
                } else {
                    Section {
                        Picker(NSLocalizedString("默认选项", comment: ""), selection: Binding(
                            get: { draft.control.defaultOptionID ?? "" }, set: { draft.control.defaultOptionID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text(NSLocalizedString("无", comment: "")).tag("")
                            ForEach(draft.control.options) { Text($0.title).tag($0.id) }
                        }
                        ForEach(draft.control.options) { option in
                            Button(option.title) { editingOption = option }.buttonStyle(.borderless)
                                .contextMenu {
                                    Button(NSLocalizedString("上移", comment: "")) { moveOption(option.id, by: -1) }
                                    Button(NSLocalizedString("下移", comment: "")) { moveOption(option.id, by: 1) }
                                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                                        draft.control.options.removeAll { $0.id == option.id }
                                        if draft.control.defaultOptionID == option.id { draft.control.defaultOptionID = nil }
                                        if draft.control.options.count < 2 { draft.control.isSliderEnabled = false }
                                    }
                                }
                        }
                        Button(NSLocalizedString("添加", comment: "")) { editingOption = .init(title: NSLocalizedString("选项", comment: "")) }
                        if canSort { Button(NSLocalizedString("按数值从小到大排序", comment: "")) { transform(split: false) } }
                    } header: { Text(NSLocalizedString("选项列表", comment: "")) }
                    Section {
                        Toggle(NSLocalizedString("启用滑块", comment: ""), isOn: $draft.control.isSliderEnabled).disabled(draft.control.options.count < 2)
                        if draft.control.isSliderEnabled {
                            TextField(NSLocalizedString("粒度", comment: ""), text: $draft.granularity)
                            TextField(NSLocalizedString("低值颜色", comment: ""), text: $draft.startColor)
                            TextField(NSLocalizedString("高值颜色", comment: ""), text: $draft.endColor)
                            Toggle(NSLocalizedString("最高档彩虹效果", comment: ""), isOn: $draft.control.usesRainbowAtMaximum)
                            Button(NSLocalizedString("恢复默认颜色", comment: "")) { draft.startColor = ""; draft.endColor = "" }
                        }
                    } header: { Text(NSLocalizedString("滑块", comment: "")) } footer: {
                        Text(NSLocalizedString("Mac 请求体滑块配置说明", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if canSplit {
                    Section { Button(NSLocalizedString("Split by nested paths", comment: "")) { transform(split: true) } }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("结构化控制", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        guard !busy, let prepared, preparedDraft == draft, !workspace.isRestoringData else { return }
                        onSave([prepared]); dismiss()
                    }.disabled(busy || prepared == nil || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(id: pageID, title: NSLocalizedString("结构化控制", comment: ""),
                documents: [GuideDocumentReference(id: "model-request-body", title: "Request Body Controls")], settings: guideSettings)
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 500, minHeight: 550)
        .sheet(isPresented: $editsPayload) {
            MacRequestParameterEditor(pageID: GuidePageID(rawValue: "\(pageID.rawValue)-payload"), parameters: draft.control.payload, mode: mode) { values, _, _ in
                draft.control.payload = values
            }
        }
        .sheet(item: $editingOption) { option in
            MacRequestOptionEditor(pageID: GuidePageID(rawValue: "\(pageID.rawValue)-option-\(option.id)"), option: option, mode: mode) { value in
                if let index = draft.control.options.firstIndex(where: { $0.id == value.id }) { draft.control.options[index] = value }
                else { draft.control.options.append(value) }
            }
        }
        .onAppear { refresh() }
        .onChange(of: draft) { _, _ in refresh() }
        .onDisappear { preparation?.cancel(); revision = UUID() }
        .onReceive(AppConfigStore.shared.$appLanguage.dropFirst()) { _ in refresh() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }

    private var guideSettings: [GuidePageSetting] {
        let state: [GuidePageSetting] = [
            .readOnly("editing_mode", label: NSLocalizedString("应用方式", comment: ""), value: { .string("request_body_draft_until_done") }),
            .readOnly("control_id", label: NSLocalizedString("控制项 ID", comment: ""), value: { .string(draft.control.id) }),
            .readOnly("kind", label: NSLocalizedString("控制类型", comment: ""), value: { .string(draft.control.kind.rawValue) })
        ]
        guard !busy, !workspace.isRestoringData else { return state }
        var fields = state + [
            .string("title", label: NSLocalizedString("显示名称", comment: ""), allowsEmpty: false, get: { draft.control.title }, set: { draft.control.title = $0 }),
            .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { draft.control.isEnabled }, set: { draft.control.isEnabled = $0 })
        ]
        if draft.control.kind == .toggle {
            fields.append(.bool("default_active", label: NSLocalizedString("默认开启", comment: ""), get: { draft.control.defaultIsActive }, set: { draft.control.defaultIsActive = $0 }))
        } else {
            fields.append(.string("default_option", label: NSLocalizedString("默认选项", comment: ""), allowedValues: [""] + optionIDs,
                                  get: { draft.control.defaultOptionID ?? "" }, set: { draft.control.defaultOptionID = $0.isEmpty ? nil : $0 }))
            if draft.control.options.count >= 2 {
                fields.append(.bool("slider_enabled", label: NSLocalizedString("启用滑块", comment: ""), get: { draft.control.isSliderEnabled }, set: { draft.control.isSliderEnabled = $0 }))
            }
            if draft.control.isSliderEnabled {
                fields += [
                    .string("granularity", label: NSLocalizedString("粒度", comment: ""), get: { draft.granularity }, set: { draft.granularity = $0 }),
                    .string("start_color", label: NSLocalizedString("低值颜色", comment: ""), get: { draft.startColor }, set: { draft.startColor = $0 }),
                    .string("end_color", label: NSLocalizedString("高值颜色", comment: ""), get: { draft.endColor }, set: { draft.endColor = $0 }),
                    .bool("rainbow_at_maximum", label: NSLocalizedString("最高档彩虹效果", comment: ""), get: { draft.control.usesRainbowAtMaximum }, set: { draft.control.usesRainbowAtMaximum = $0 })
                ]
            }
        }
        return fields
    }

    private func refresh() {
        preparation?.cancel()
        revision = UUID()
        let token = revision, source = draft
        busy = true; prepared = nil; preparedDraft = nil; canSplit = false; canSort = false
        preparation = Task {
            let result = await Task.detached { Result { () -> (ModelRequestBodyControl, Bool, Bool, [String]) in
                let control = try source.prepared()
                let slider = ModelRequestBodyControlSliderDescriptor(control: control)
                return (control, ModelRequestBodyControlSplitter.canSplit(control), slider?.mode == .continuousNumeric,
                        control.options.map(\.id))
            } }.value
            guard !Task.isCancelled, revision == token else { return }
            busy = false
            switch result {
            case .success(let value): prepared = value.0; preparedDraft = source; canSplit = value.1; canSort = value.2; optionIDs = value.3; error = nil
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func moveOption(_ id: String, by delta: Int) {
        guard let index = draft.control.options.firstIndex(where: { $0.id == id }), draft.control.options.indices.contains(index + delta) else { return }
        draft.control.options.swapAt(index, index + delta)
    }

    private func transform(split: Bool) {
        guard !busy, let prepared, preparedDraft == draft else { return }
        let token = revision
        busy = true
        preparation = Task {
            let values = await Task.detached { () -> [ModelRequestBodyControl]? in
                if split { return ModelRequestBodyControlSplitter.split(prepared) }
                guard let options = ModelRequestBodyControlSliderDescriptor(control: prepared)?.optionsSortedByNumericValue() else { return nil }
                var control = prepared; control.options = options
                return [control]
            }.value
            guard !Task.isCancelled, token == revision, !workspace.isRestoringData else { return }
            busy = false
            guard let values else { return }
            if split { onSave(values); dismiss() }
            else if let value = values.first { draft = MacRequestControlDraft(value) }
        }
    }
}

private struct MacRequestOptionEditor: View {
    let pageID: GuidePageID
    let mode: Model.RequestBodyOverrideMode
    let onSave: (ModelRequestBodyControlOption) -> Void
    @State private var option: ModelRequestBodyControlOption
    @State private var editsPayload = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var workspace: MacWorkspaceModel

    init(pageID: GuidePageID, option: ModelRequestBodyControlOption, mode: Model.RequestBodyOverrideMode, onSave: @escaping (ModelRequestBodyControlOption) -> Void) {
        self.pageID = pageID; self.mode = mode; self.onSave = onSave
        _option = State(initialValue: option)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("显示名称", comment: ""), text: $option.title)
                Button(NSLocalizedString("请求体参数", comment: "")) { editsPayload = true }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("选项", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { onSave(option); dismiss() }.disabled(option.title.isEmpty || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(id: pageID, title: NSLocalizedString("选项", comment: ""),
                documents: [GuideDocumentReference(id: "model-request-body", title: "Request Body Controls")], settings: [
                    .readOnly("editing_mode", label: NSLocalizedString("应用方式", comment: ""), value: { .string("control_draft_until_done") }),
                    .readOnly("option_id", label: NSLocalizedString("选项 ID", comment: ""), value: { .string(option.id) }),
                    .string("title", label: NSLocalizedString("显示名称", comment: ""), allowsEmpty: false, get: { option.title }, set: { option.title = $0 })
                ])
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 460, minHeight: 300)
        .sheet(isPresented: $editsPayload) {
            MacRequestParameterEditor(pageID: GuidePageID(rawValue: "\(pageID.rawValue)-payload"), parameters: option.payload, mode: mode) { values, _, _ in option.payload = values }
        }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }
}

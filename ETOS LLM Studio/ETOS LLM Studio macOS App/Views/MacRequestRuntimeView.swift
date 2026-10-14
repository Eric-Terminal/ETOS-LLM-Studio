import ETOSCore
import SwiftUI

struct MacRequestRuntimeView: View {
    @ObservedObject var model: MacRequestRuntimeModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    private var pageID: GuidePageID {
        GuidePageID(rawValue: "mac-request-runtime-\(model.source?.modelKey ?? "none")-\(model.source?.sessionID?.uuidString ?? "none")")
    }

    private static var tool: InternalToolDefinition {
        InternalToolDefinition(name: "propose_mac_runtime_control",
            description: NSLocalizedString("修改当前模型的一项聊天控制，确认后保存并用于后续请求。", comment: ""),
            parameters: .dictionary(["type": .string("object"), "properties": .dictionary([
                "control_id": .dictionary(["type": .string("string")]),
                "active": .dictionary(["type": .string("boolean")]),
                "option_id": .dictionary(["type": .string("string")]),
                "position": .dictionary(["type": .string("number"), "minimum": .int(0), "maximum": .int(1)])
            ]), "required": .array([.string("control_id")]), "additionalProperties": .bool(false)]))
    }

    var body: some View {
        let revision = model.revision
        NavigationStack {
            Form {
                Section {
                    if let title = model.source?.title { Text(title).font(.headline) }
                    if model.isWorking { ProgressView() }
                    if let prepared = model.presentation {
                        ForEach(prepared.rows) { row in
                            if row.kind == .toggle {
                                Toggle(row.title, isOn: Binding(get: { row.active }, set: { apply(.init(controlID: row.id, value: .toggle($0)), revision: revision) }))
                            } else if row.slider != nil {
                                MacRequestRuntimeSlider(row: row) { apply(.init(controlID: row.id, value: .slider($0)), revision: revision) }
                                    .id("\(model.revision)-\(row.id)")
                            } else {
                                Picker(row.title, selection: Binding(get: { row.selectedOptionID }, set: { apply(.init(controlID: row.id, value: .option($0.isEmpty ? nil : $0)), revision: revision) })) {
                                    Text(row.defaultSelectionTitle).tag("")
                                    ForEach(row.options) { Text($0.title).tag($0.id) }
                                }
                            }
                        }
                        if prepared.rows.isEmpty { Text(NSLocalizedString("当前模型没有启用的聊天控制。", comment: "")).foregroundStyle(.secondary) }
                    }
                } footer: { Text(NSLocalizedString("聊天控制的更改会保存，并用于后续请求。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                .disabled(!workspace.canEditRequestControls || model.isWorking)
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let prepared = model.presentation, !model.isWorking {
                    Section {
                        Text(prepared.preview).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    } header: { Text(NSLocalizedString("有效覆盖参数", comment: "")) } footer: {
                        Text(NSLocalizedString("这里只显示模型参数与当前控制合并后的结果，不包含消息、工具或完整 HTTP 请求。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    MacSettingsIntroCard(id: "mac-request-runtime", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 聊天控制使用说明", comment: ""), documentID: "model-request-body")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(NSLocalizedString("聊天控制", comment: ""))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(NSLocalizedString("完成", comment: "")) { dismiss() } } }
            .guidePageContext(descriptor: GuidePageDescriptor(id: pageID, title: NSLocalizedString("聊天控制", comment: ""),
                documents: [GuideDocumentReference(id: "model-request-body", title: "Request Body Controls")],
                tools: workspace.canEditRequestControls && !model.isWorking && model.presentation != nil ? [GuidePageTool(definition: Self.tool, access: .proposeChange)] : []),
                snapshot: { GuidePageSnapshot(fields: [
                    "model_id": GuideSnapshotField(label: NSLocalizedString("模型", comment: ""), value: .string(model.source?.modelKey ?? ""), access: .readOnly),
                    "controls": GuideSnapshotField(label: NSLocalizedString("聊天控制", comment: ""), value: model.presentation?.guideValues ?? .array([])),
                    "editing_mode": GuideSnapshotField(label: NSLocalizedString("应用方式", comment: ""), value: .string("persist_for_future_requests_after_confirmation"), access: .readOnly),
                    "revision": GuideSnapshotField(label: NSLocalizedString("版本", comment: ""), value: .string(model.revision.uuidString), access: .readOnly)
                ]) }, buildProposal: { call, _ in
                    guard call.toolName == Self.tool.name, workspace.canEditRequestControls, !model.isWorking,
                          let source = model.source, let prepared = model.presentation else { throw GuideError.pageChanged }
                    let revision = model.revision, page = pageID
                    let result = try await Task.detached {
                        let args = try GuideToolArguments.decode(call.arguments)
                        let change = try MacRequestRuntimeChange(arguments: args)
                        let updated = try change.applying(to: .init(), controls: source.controls)
                        guard let row = prepared.rows.first(where: { $0.id == change.controlID }) else { throw GuideError.pageChanged }
                        let old: JSONValue, new: JSONValue
                        switch change.value {
                        case .toggle(let value): old = .bool(row.active); new = .bool(value)
                        case .option(let value): old = .string(row.selectedOptionID); new = .string(value ?? "")
                        case .slider: old = .double(row.position); new = .double(updated.sliderPositionsByControlID[row.id] ?? row.position)
                        }
                        return (args, GuideSettingMutation(path: "controls.\(row.id)", label: row.title, oldValue: old, newValue: new))
                    }.value
                    guard model.revision == revision, workspace.canEditRequestControls else { throw GuideError.pageChanged }
                    var arguments = result.0
                    arguments["revision"] = .string(revision.uuidString)
                    return GuideActionProposal(pageID: page, toolCallID: call.id, toolName: Self.tool.name,
                        summary: NSLocalizedString("调整聊天控制", comment: ""), mutations: [result.1], arguments: arguments)
                }, execute: { proposal in
                    guard proposal.toolName == Self.tool.name, workspace.canEditRequestControls,
                          case .string(let value)? = proposal.arguments["revision"], let revision = UUID(uuidString: value) else { throw GuideError.pageChanged }
                    let change = try await Task.detached {
                        var args = proposal.arguments; args.removeValue(forKey: "revision")
                        return try MacRequestRuntimeChange(arguments: args)
                    }.value
                    guard workspace.canEditRequestControls else { throw GuideError.pageChanged }
                    try await model.apply(change, expectedRevision: revision)
                    return GuideActionExecution(message: NSLocalizedString("聊天控制已保存，将用于后续请求。", comment: ""))
                })
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 520, minHeight: 480)
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }

    private func apply(_ change: MacRequestRuntimeChange, revision: UUID) {
        Task {
            guard workspace.canEditRequestControls else { return }
            do { try await model.apply(change, expectedRevision: revision) }
            catch { if !workspace.isRestoringData { workspace.errorMessage = error.localizedDescription } }
        }
    }
}

private struct MacRequestRuntimeSlider: View {
    let row: MacRequestRuntimeRow
    let commit: (Double) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var position: Double
    @State private var label: String
    @State private var isDragging = false
    @State private var submittedPosition: Double?

    init(row: MacRequestRuntimeRow, commit: @escaping (Double) -> Void) {
        self.row = row; self.commit = commit
        _position = State(initialValue: row.position); _label = State(initialValue: row.valueLabel)
    }

    var body: some View {
        let color = row.palette.color(at: position)
        let rainbow = row.usesRainbowAtMaximum && row.slider?.isMaximumPosition(position) == true
        VStack(alignment: .leading) {
            LabeledContent(row.title) {
                if rainbow, scenePhase == .active {
                    FlowingRainbowForeground(startingColor: row.palette.color(at: 1)) { Text(label).monospacedDigit() }
                } else { Text(label).monospacedDigit().foregroundStyle(color) }
            }.font(.callout)
            Slider(value: $position, in: 0...1, step: row.slider?.crownStep ?? 1, onEditingChanged: { editing in
                isDragging = editing
                if !editing { submit() }
            }) { Text(row.title) }
            .tint(color)
            .accessibilityValue(label)
        }
        .onChange(of: position) { _, _ in if !isDragging { submit() } }
        .onChange(of: row.position) { _, value in position = value; submittedPosition = value; label = row.valueLabel }
        .onChange(of: row.valueLabel) { _, value in label = value }
        .task(id: position) {
            let value = position, descriptor = row.slider
            let prepared = await Task.detached { descriptor?.displayValue(at: value) ?? "" }.value
            guard !Task.isCancelled else { return }
            label = prepared
        }
    }

    private func submit() {
        guard position != row.position, submittedPosition != position else { return }
        submittedPosition = position
        commit(position)
    }
}

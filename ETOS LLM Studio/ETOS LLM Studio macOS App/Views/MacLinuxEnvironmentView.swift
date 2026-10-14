import ETOSCore
import SwiftUI

struct MacLinuxEnvironmentView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxConfigurationModel()
    @State private var visible = false
    @State private var editor: MacLinuxVariableEditorTarget?
    private var allowed: Bool { isActive && workspace.canManageLocalModels && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "linux-environment", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 环境变量使用说明", comment: ""), documentID: "macos-workspace", isActive: allowed && editor == nil)
                Button(NSLocalizedString("添加环境变量", comment: "")) { editor = MacLinuxVariableEditorTarget(original: nil) }.disabled(model.isWorking)
                Button(NSLocalizedString("刷新", comment: "")) { model.error = nil; model.reload() }.disabled(model.isLoading || model.isWorking)
            }
            Section(NSLocalizedString("变量", comment: "")) {
                if let catalog = model.catalog {
                    if catalog.snapshot.variables.isEmpty { Text(NSLocalizedString("还没有环境变量。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(catalog.snapshot.variables) { variable in
                        Button { editor = MacLinuxVariableEditorTarget(original: variable) } label: {
                            VStack(alignment: .leading) {
                                Text(variable.name).font(.body.monospaced())
                                if !variable.isEnabled { Text(NSLocalizedString("已停用", comment: "")).font(.caption).foregroundStyle(.secondary) }
                                Text(NSLocalizedString("值已隐藏", comment: "")).font(.caption).foregroundStyle(.secondary)
                                if !variable.note.isEmpty { Text(variable.note).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                            }
                        }.buttonStyle(.plain).disabled(model.isWorking)
                    }
                }
            }
            if model.isLoading || model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(NSLocalizedString("环境变量", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; editor = nil; model.close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { editor = nil; model.close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in editor = nil; model.close(); if active { model.open() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .sheet(item: $editor) { target in MacLinuxEnvironmentEditor(target: target, isActive: active, model: model) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-environment-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("环境变量", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && editor == nil && !model.isWorking,
            settings: [.readOnly("variables", label: NSLocalizedString("变量", comment: ""), value: { model.catalog?.guideVariables ?? .array([]) })])
    }
}

private struct MacLinuxEnvironmentEditor: View {
    let target: MacLinuxVariableEditorTarget
    let isActive: Bool
    @ObservedObject var model: MacLinuxConfigurationModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var validation = MacLinuxDraftValidationModel()
    @State private var draft: LocalLinuxEnvironmentVariable
    @State private var visible = false
    @State private var showValue = false
    @State private var deleting = false

    init(target: MacLinuxVariableEditorTarget, isActive: Bool, model: MacLinuxConfigurationModel) {
        self.target = target; self.isActive = isActive; self.model = model
        _draft = State(initialValue: target.original ?? LocalLinuxEnvironmentVariable(name: "", value: ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "linux-variable-editor", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac Linux 环境变量使用说明", comment: ""), documentID: "macos-workspace", isActive: isActive && !deleting)
                    TextField(NSLocalizedString("名称", comment: ""), text: $draft.name).autocorrectionDisabled()
                    if showValue { TextField(NSLocalizedString("值", comment: ""), text: $draft.value, axis: .vertical).lineLimit(1...6).autocorrectionDisabled() }
                    else { SecureField(NSLocalizedString("值", comment: ""), text: $draft.value) }
                    Toggle(NSLocalizedString("显示值", comment: ""), isOn: $showValue)
                    TextField(NSLocalizedString("备注（可选）", comment: ""), text: $draft.note, axis: .vertical).lineLimit(1...4)
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $draft.isEnabled)
                } footer: {
                    Text(NSLocalizedString("变量只在进程启动时注入，不会写入 .profile，也不会自动发送给模型。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if target.original != nil {
                    Section { Button(NSLocalizedString("删除变量", comment: ""), role: .destructive) { deleting = true } }
                }
                if let error = model.error ?? validation.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            }
            .formStyle(.grouped).navigationTitle(NSLocalizedString("环境变量", comment: "")).disabled(!isActive || model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(!isActive || !validation.canSave || model.isWorking)
                }
            }
            .onAppear { visible = true; validation.validate(draft) }
            .onDisappear { visible = false; deleting = false; validation.invalidate() }
            .onChange(of: draft) { _, value in if visible { validation.validate(value) } }
            .onChange(of: isActive) { _, value in
                if !value { draft = LocalLinuxEnvironmentVariable(name: "", value: ""); showValue = false; validation.invalidate(); dismiss() }
            }
            .confirmationDialog(NSLocalizedString("删除变量", comment: ""), isPresented: $deleting, titleVisibility: .visible) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) { remove() }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-linux-variable-editor-\(target.id)-\(model.lease)"), title: NSLocalizedString("环境变量", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                isActive: visible && isActive && !model.isWorking && !deleting,
                settings: [
                    .string("name", label: NSLocalizedString("名称", comment: ""), allowsEmpty: false, get: { draft.name }, set: { draft.name = $0 }),
                    .writeOnlyString("value", label: NSLocalizedString("值", comment: ""), isConfigured: { !draft.value.isEmpty }, set: { draft.value = $0 }),
                    .readOnly("value_visible", label: NSLocalizedString("显示值", comment: ""), value: { .bool(showValue) }),
                    .string("note", label: NSLocalizedString("备注", comment: ""), get: { draft.note }, set: { draft.note = $0 }),
                    .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { draft.isEnabled }, set: { draft.isEnabled = $0 }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ])
        }.frame(minWidth: 520, minHeight: 440)
    }

    private func save() {
        let draft = draft, original = target.original, lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            guard visible, isActive else { return }
            do {
                try await model.perform(expectedLease: lease, revision: revision) { try await $0.saveVariable(draft, original: original) }
                if visible, isActive { dismiss() }
            } catch { }
        }
    }
    private func remove() {
        guard let original = target.original else { return }
        let lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            guard visible, isActive else { return }
            do {
                try await model.perform(expectedLease: lease, revision: revision) { try await $0.deleteVariable(original) }
                if visible, isActive { dismiss() }
            } catch { }
        }
    }
}

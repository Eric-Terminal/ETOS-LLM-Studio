import ETOSCore
import SwiftUI

struct MacLinuxRulesView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxConfigurationModel()
    @State private var visible = false
    @State private var editor: MacLinuxRuleEditorTarget?
    private var allowed: Bool { isActive && workspace.canManageLocalModels && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "linux-rules", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 命令规则使用说明", comment: ""), documentID: "macos-workspace", isActive: allowed && editor == nil)
                Toggle(NSLocalizedString("启用命令安全策略", comment: ""), isOn: $configuration.localLinuxCommandSafetyEnabled)
                Button(NSLocalizedString("添加规则", comment: "")) { editor = MacLinuxRuleEditorTarget(original: nil) }.disabled(model.isWorking)
                Button(NSLocalizedString("刷新", comment: "")) { model.error = nil; model.reload() }.disabled(model.isLoading || model.isWorking)
            }
            Section(NSLocalizedString("规则", comment: "")) {
                if let catalog = model.catalog {
                    if catalog.rules.isEmpty { Text(NSLocalizedString("还没有命令规则。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(catalog.rules) { row in
                        Button { editor = MacLinuxRuleEditorTarget(original: row.rule) } label: {
                            VStack(alignment: .leading) {
                                Text(row.rule.name)
                                Text(row.rule.pattern).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                HStack { Text(row.action); Text(row.scope) }.font(.caption).foregroundStyle(.secondary)
                                if !row.rule.isEnabled { Text(NSLocalizedString("已停用", comment: "")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.buttonStyle(.plain).disabled(model.isWorking)
                        .contextMenu {
                            Button(NSLocalizedString("上移", comment: "")) { move(row.id, offset: -1) }.disabled(!row.canMoveUp || model.isWorking)
                            Button(NSLocalizedString("下移", comment: "")) { move(row.id, offset: 1) }.disabled(!row.canMoveDown || model.isWorking)
                        }
                    }
                }
            }
            if model.isLoading || model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(NSLocalizedString("命令规则", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; editor = nil; model.close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { editor = nil; model.close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in editor = nil; model.close(); if active { model.open() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .sheet(item: $editor) { target in MacLinuxRuleEditor(target: target, isActive: active, model: model) }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-rules-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("命令规则", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && editor == nil && !model.isWorking,
            settings: [
                .bool("enabled", label: NSLocalizedString("启用命令安全策略", comment: ""), get: { configuration.localLinuxCommandSafetyEnabled }, set: { configuration.localLinuxCommandSafetyEnabled = $0 }),
                .readOnly("rules", label: NSLocalizedString("规则", comment: ""), value: { model.catalog?.guideRules ?? .array([]) })
            ])
    }

    private func move(_ id: UUID, offset: Int) {
        guard let original = model.catalog?.snapshot.rules else { return }
        let lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            guard active else { return }
            _ = try? await model.perform(expectedLease: lease, revision: revision) { try await $0.moveRule(id: id, offset: offset, original: original) }
        }
    }
}

private struct MacLinuxRuleEditor: View {
    let target: MacLinuxRuleEditorTarget
    let isActive: Bool
    @ObservedObject var model: MacLinuxConfigurationModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var validation = MacLinuxDraftValidationModel()
    @State private var draft: LocalLinuxCommandRule
    @State private var visible = false
    @State private var deleting = false

    init(target: MacLinuxRuleEditorTarget, isActive: Bool, model: MacLinuxConfigurationModel) {
        self.target = target; self.isActive = isActive; self.model = model
        _draft = State(initialValue: target.original ?? LocalLinuxCommandRule(name: "", pattern: "", matchKind: .prefix, scope: .all, action: .confirm))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "linux-rule-editor", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac Linux 命令规则使用说明", comment: ""), documentID: "macos-workspace", isActive: isActive && !deleting)
                    TextField(NSLocalizedString("规则名称", comment: ""), text: $draft.name)
                    TextField(NSLocalizedString("匹配内容", comment: ""), text: $draft.pattern, axis: .vertical).lineLimit(1...6).autocorrectionDisabled()
                    Picker(NSLocalizedString("匹配方式", comment: ""), selection: $draft.matchKind) {
                        ForEach(LocalLinuxCommandRuleMatchKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker(NSLocalizedString("作用范围", comment: ""), selection: $draft.scope) {
                        ForEach(LocalLinuxCommandRuleScope.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker(NSLocalizedString("处理", comment: ""), selection: $draft.action) {
                        ForEach(LocalLinuxCommandRuleAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle(NSLocalizedString("启用规则", comment: ""), isOn: $draft.isEnabled)
                } footer: {
                    Text(NSLocalizedString("规则只用于提示、确认或拒绝匹配文本；它不是 shell sandbox。关闭总开关后不会保留隐藏黑名单。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if target.original != nil { Section { Button(NSLocalizedString("删除规则", comment: ""), role: .destructive) { deleting = true } } }
                if let error = model.error ?? validation.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            }
            .formStyle(.grouped).navigationTitle(NSLocalizedString("命令规则", comment: "")).disabled(!isActive || model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(!isActive || !validation.canSave || model.isWorking) }
            }
            .onAppear { visible = true; validation.validate(draft) }
            .onDisappear { visible = false; deleting = false; validation.invalidate() }
            .onChange(of: draft) { _, value in if visible { validation.validate(value) } }
            .onChange(of: isActive) { _, value in if !value { validation.invalidate(); dismiss() } }
            .confirmationDialog(NSLocalizedString("删除规则", comment: ""), isPresented: $deleting, titleVisibility: .visible) {
                Button(NSLocalizedString("删除", comment: ""), role: .destructive) { remove() }
                Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-linux-rule-editor-\(target.id)-\(model.lease)"), title: NSLocalizedString("命令规则", comment: ""),
                documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                isActive: visible && isActive && !model.isWorking && !deleting,
                settings: [
                    .string("name", label: NSLocalizedString("规则名称", comment: ""), get: { draft.name }, set: { draft.name = $0 }),
                    .string("pattern", label: NSLocalizedString("匹配内容", comment: ""), allowsEmpty: false, get: { draft.pattern }, set: { draft.pattern = $0 }),
                    .string("match_kind", label: NSLocalizedString("匹配方式", comment: ""), allowedValues: ["prefix", "suffix", "regular_expression"], get: { draft.matchKind.rawValue }, set: { if let value = LocalLinuxCommandRuleMatchKind(rawValue: $0) { draft.matchKind = value } }),
                    .string("scope", label: NSLocalizedString("作用范围", comment: ""), allowedValues: ["run", "shell", "all"], get: { draft.scope.rawValue }, set: { if let value = LocalLinuxCommandRuleScope(rawValue: $0) { draft.scope = value } }),
                    .string("action", label: NSLocalizedString("处理", comment: ""), allowedValues: ["warn", "confirm", "deny"], get: { draft.action.rawValue }, set: { if let value = LocalLinuxCommandRuleAction(rawValue: $0) { draft.action = value } }),
                    .bool("enabled", label: NSLocalizedString("启用规则", comment: ""), get: { draft.isEnabled }, set: { draft.isEnabled = $0 }),
                    .readOnly("priority", label: NSLocalizedString("优先级", comment: ""), value: { target.original.map { .int($0.sortIndex) } ?? .null }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ])
        }.frame(minWidth: 560, minHeight: 500)
    }

    private func save() {
        let draft = draft, original = target.original, lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            guard visible, isActive else { return }
            do {
                try await model.perform(expectedLease: lease, revision: revision) { try await $0.saveRule(draft, original: original) }
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
                try await model.perform(expectedLease: lease, revision: revision) { try await $0.deleteRule(original) }
                if visible, isActive { dismiss() }
            } catch { }
        }
    }
}

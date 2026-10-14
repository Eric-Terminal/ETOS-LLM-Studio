import ETOSCore
import SwiftUI

struct MacLinuxShortcutsView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxConfigurationModel()
    @State private var visible = false
    @State private var editor: MacLinuxShortcutEditorTarget?
    @State private var confirmation: MacLinuxShortcutConfirmation?
    private var allowed: Bool { isActive && workspace.canManageLocalModels && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "linux-shortcuts", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 快捷键使用说明", comment: ""), documentID: "macos-workspace",
                    isActive: allowed && editor == nil && confirmation == nil)
                Button(NSLocalizedString("添加快捷键", comment: "")) { edit(nil) }.disabled(model.catalog == nil || model.isWorking)
                Button(NSLocalizedString("恢复默认", comment: "")) { confirm(.reset) }.disabled(model.catalog == nil || model.isWorking)
                Button(NSLocalizedString("刷新", comment: "")) { model.error = nil; model.reload() }.disabled(model.isLoading || model.isWorking)
            }
            Section(NSLocalizedString("已显示的按键", comment: "")) {
                if let catalog = model.catalog {
                    if catalog.shortcuts.isEmpty { Text(NSLocalizedString("还没有选择终端快捷键。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(catalog.shortcuts) { row in
                        Button { edit(row.shortcut) } label: { Text(row.title).font(.body.monospaced()) }
                            .buttonStyle(.plain).disabled(model.isWorking)
                            .contextMenu {
                                Button(NSLocalizedString("上移", comment: "")) { move(row.id, offset: -1) }.disabled(!row.canMoveUp || model.isWorking)
                                Button(NSLocalizedString("下移", comment: "")) { move(row.id, offset: 1) }.disabled(!row.canMoveDown || model.isWorking)
                                Button(NSLocalizedString("删除", comment: ""), role: .destructive) { confirm(.delete(row.id)) }.disabled(model.isWorking)
                            }
                    }
                }
            }
            if model.isLoading || model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(NSLocalizedString("终端快捷键", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in close(); if active { model.open() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.reload() }
        .onChange(of: configuration.localLinuxTerminalShortcutIDs) { _, _ in model.reload() }
        .sheet(item: $editor) { target in MacLinuxShortcutEditor(target: target, isActive: active, model: model) }
        .confirmationDialog(NSLocalizedString("修改终端快捷栏", comment: ""), isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { target in
            Button(NSLocalizedString("确认", comment: ""), role: .destructive) { apply(target) }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { confirmation = nil }
        } message: { target in
            Text(target.action.isReset ? NSLocalizedString("恢复默认会替换当前快捷栏，不会向终端发送按键。", comment: "") : NSLocalizedString("删除后该组合将从快捷栏移除。", comment: ""))
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-shortcuts-\(model.lease)-\(runtime.epoch)"), title: NSLocalizedString("终端快捷键", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && editor == nil && confirmation == nil && !model.isWorking,
            settings: [.readOnly("shortcuts", label: NSLocalizedString("终端快捷键列表", comment: ""), value: { model.catalog?.guideShortcuts ?? .array([]) })])
    }

    private func close(clearContent: Bool = true) { editor = nil; confirmation = nil; model.close(clearContent: clearContent) }
    private func edit(_ original: LocalLinuxTerminalShortcut?) {
        guard let snapshot = model.catalog?.snapshot else { return }
        editor = MacLinuxShortcutEditorTarget(original: original, shortcuts: snapshot.shortcuts, encoding: snapshot.shortcutEncoding)
    }
    private func confirm(_ action: MacLinuxShortcutConfirmation.Action) {
        guard let snapshot = model.catalog?.snapshot else { return }
        confirmation = MacLinuxShortcutConfirmation(action: action, shortcuts: snapshot.shortcuts, encoding: snapshot.shortcutEncoding, lease: model.lease)
    }
    private func move(_ id: UUID, offset: Int) {
        guard let snapshot = model.catalog?.snapshot else { return }
        let shortcuts = snapshot.shortcuts, encoding = snapshot.shortcutEncoding, lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            guard active else { return }
            _ = try? await model.perform(expectedLease: lease, revision: revision) { library in
                guard let index = shortcuts.firstIndex(where: { $0.id == id }), shortcuts.indices.contains(index + offset) else { throw LocalLinuxConfigurationError.changed }
                var values = shortcuts; values.swapAt(index, index + offset)
                return try await library.saveShortcuts(values, expectedEncoding: encoding)
            }
        }
    }
    private func apply(_ target: MacLinuxShortcutConfirmation) {
        Task {
            guard active else { return }
            _ = try? await model.perform(expectedLease: target.lease, revision: target.revision) { library in
                let values: [LocalLinuxTerminalShortcut]
                switch target.action {
                case .reset: values = LocalLinuxTerminalShortcutConfiguration.defaults
                case .delete(let id): values = target.shortcuts.filter { $0.id != id }
                }
                return try await library.saveShortcuts(values, expectedEncoding: target.encoding)
            }
        }
    }
}

private struct MacLinuxShortcutConfirmation: Identifiable, Sendable {
    enum Action: Sendable {
        case reset, delete(UUID)
        var isReset: Bool { if case .reset = self { return true }; return false }
    }
    let id = UUID()
    let action: Action
    let shortcuts: [LocalLinuxTerminalShortcut]
    let encoding: String
    let lease: UUID
    let revision = LocalLinuxActivityBarrier.shared.revision
}

private struct MacLinuxShortcutEditor: View {
    let target: MacLinuxShortcutEditorTarget
    let isActive: Bool
    @ObservedObject var model: MacLinuxConfigurationModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: MacLinuxShortcutDraftModel
    @State private var visible = false
    private let columns = [GridItem(.adaptive(minimum: 64))]

    init(target: MacLinuxShortcutEditorTarget, isActive: Bool, model: MacLinuxConfigurationModel) {
        self.target = target; self.isActive = isActive; self.model = model
        _draft = StateObject(wrappedValue: MacLinuxShortcutDraftModel(target.original))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "linux-shortcut-editor", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac Linux 快捷键使用说明", comment: ""), documentID: "macos-workspace", isActive: isActive)
                    LabeledContent(NSLocalizedString("快捷键组合", comment: ""), value: draft.title.isEmpty ? NSLocalizedString("未选择按键", comment: "") : draft.title)
                }
                ForEach(draft.groups) { group in
                    Section(group.title) {
                        LazyVGrid(columns: columns) {
                            ForEach(group.choices) { choice in
                                Button { draft.toggle(choice.key) } label: {
                                    HStack {
                                        if draft.selected.contains(choice.key) { Image(systemName: "checkmark") }
                                        Text(choice.title).font(.body.monospaced())
                                    }.frame(maxWidth: .infinity)
                                }.buttonStyle(.borderless).accessibilityAddTraits(draft.selected.contains(choice.key) ? .isSelected : [])
                            }
                        }
                    }
                }
                if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped).navigationTitle(NSLocalizedString("编辑快捷键", comment: "")).disabled(!isActive || model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(!isActive || draft.prepared == nil || model.isWorking) }
            }
            .onAppear { visible = true; draft.refresh() }.onDisappear { visible = false; draft.stop() }
            .onChange(of: isActive) { _, value in if !value { draft.stop(); dismiss() } }
            .onChange(of: configuration.appLanguage) { _, _ in if visible { draft.refresh() } }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-linux-shortcut-editor-\(target.id)-\(model.lease)"), title: NSLocalizedString("编辑快捷键", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                isActive: visible && isActive && !model.isWorking && !draft.isPreparing,
                settings: [
                    .json("keys", label: NSLocalizedString("快捷键组合", comment: ""), schema: GuideLocalLinuxTerminalShortcutSettingsSupport.keyListSchema,
                        get: { draft.guideKeys }, normalize: { try GuideLocalLinuxTerminalShortcutSettingsSupport.normalizeKeys($0) },
                        set: { draft.replace(try GuideLocalLinuxTerminalShortcutSettingsSupport.keys(from: $0)) }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ])
        }.frame(minWidth: 560, minHeight: 520)
    }

    private func save() {
        guard let shortcut = draft.prepared else { return }
        let target = target, lease = model.lease, revision = LocalLinuxActivityBarrier.shared.revision
        Task {
            guard visible, isActive else { return }
            do {
                try await model.perform(expectedLease: lease, revision: revision) { library in
                    var shortcuts = target.shortcuts
                    if let original = target.original {
                        guard let index = shortcuts.firstIndex(where: { $0.id == original.id }) else { throw LocalLinuxConfigurationError.changed }
                        shortcuts[index] = shortcut
                    } else { shortcuts.append(shortcut) }
                    return try await library.saveShortcuts(shortcuts, expectedEncoding: target.encoding)
                }
                if visible, isActive { dismiss() }
            } catch { }
        }
    }
}

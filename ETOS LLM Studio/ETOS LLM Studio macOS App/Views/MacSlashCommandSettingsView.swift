import ETOSCore
import SwiftUI

@MainActor
struct MacSlashCommandSettingsView: View {
    let isActive: Bool
    @ObservedObject var model: MacSlashCommandsModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @State private var visible = false
    @State private var editor: MacSlashCommandEditorTarget?
    @State private var deleting: MacSlashCommandEditorTarget?
    private var active: Bool { visible && isActive && workspace.canManageLocalModels && !model.isSuspended }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "slash-commands", title: NSLocalizedString("快速指令", comment: ""),
                    details: NSLocalizedString("Mac 快速指令使用说明", comment: ""), documentID: "slash-commands",
                    isActive: isActive && workspace.canManageLocalModels)
                Toggle(NSLocalizedString("启用快速指令", comment: ""), isOn: $configuration.enableSlashCommands)
                    .disabled(!active)
            } footer: {
                Text(NSLocalizedString("开启后，在聊天输入框输入 / 选择命令。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(NSLocalizedString("添加快速指令", comment: "")) { presentEditor(nil) }.disabled(!model.canWrite)
                if model.isLoading { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                if let catalog = model.catalog {
                    if catalog.custom.isEmpty {
                        Text(NSLocalizedString("尚未添加自定义命令。", comment: "")).foregroundStyle(.secondary)
                    }
                    ForEach(catalog.custom) { row in
                        Button {
                            if case .custom(let command) = row.suggestion { presentEditor(command) }
                        } label: { MacSlashCommandLabel(row: row) }
                            .buttonStyle(.plain).disabled(!model.canWrite)
                            .contextMenu {
                                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                                    if case .custom(let command) = row.suggestion {
                                        deleting = MacSlashCommandEditorTarget(command: command, original: catalog.snapshot, epoch: model.epoch)
                                    }
                                }.disabled(!model.canWrite)
                            }
                    }
                }
            } header: { Text(NSLocalizedString("自定义命令", comment: "")) }
            footer: {
                Text(NSLocalizedString("自定义命令会把提示词填入聊天输入框，不会自动发送。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let catalog = model.catalog {
                Section(NSLocalizedString("可用命令", comment: "")) {
                    ForEach(catalog.builtIn) { row in MacSlashCommandLabel(row: row) }
                }
            }
            if let error = model.error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
                Button(NSLocalizedString("刷新", comment: ""), action: model.reload).disabled(model.isWorking)
            }
        }
        .formStyle(.grouped).disabled(!isActive || !workspace.canManageLocalModels)
        .navigationTitle(NSLocalizedString("快速指令", comment: ""))
        .onAppear { visible = true; if model.catalog == nil { model.reload() } }
        .onDisappear { visible = false; editor = nil; deleting = nil }
        .onChange(of: active) { _, value in if !value { editor = nil; deleting = nil } }
        .onChange(of: model.epoch) { _, _ in editor = nil; deleting = nil }
        .sheet(item: $editor) { target in MacSlashCommandEditor(target: target, isActive: active, model: model) }
        .sheet(item: $deleting) { target in MacSlashCommandDeletionView(target: target, isActive: active, model: model) }
        .modifier(MacSlashCommandSettingsGuide(model: model, isActive: active && editor == nil && deleting == nil))
    }

    private func presentEditor(_ command: CustomChatSlashCommand?) {
        guard active, model.canWrite, let snapshot = model.catalog?.snapshot else { return }
        editor = MacSlashCommandEditorTarget(command: command, original: snapshot, epoch: model.epoch)
    }
}

@MainActor
struct MacSlashCommandLabel: View {
    let row: MacSlashCommandRow
    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(row.invocation).font(.body.monospaced())
                Text(row.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if !row.aliases.isEmpty { Text(row.aliases).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
        } icon: { Image(systemName: row.systemImage).foregroundStyle(.tint) }
    }
}

@MainActor
private struct MacSlashCommandEditor: View {
    let isActive: Bool
    @ObservedObject var model: MacSlashCommandsModel
    @StateObject private var draft: MacSlashCommandDraft
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private var available: Bool { isActive && model.canWrite && model.epoch == draft.target.epoch }
    private var title: String { draft.target.command == nil ? NSLocalizedString("新增快速指令", comment: "") : NSLocalizedString("编辑快速指令", comment: "") }

    init(target: MacSlashCommandEditorTarget, isActive: Bool, model: MacSlashCommandsModel) {
        self.isActive = isActive; self.model = model
        _draft = StateObject(wrappedValue: MacSlashCommandDraft(target: target))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NSLocalizedString("激活指令", comment: ""), text: $draft.trigger).autocorrectionDisabled()
                } footer: {
                    Text(NSLocalizedString("输入 / 后使用此名称查找命令。可使用字母、数字、短横线和下划线。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    TextField(NSLocalizedString("提示词", comment: ""), text: $draft.prompt, axis: .vertical).lineLimit(6...16)
                } footer: {
                    Text(NSLocalizedString("选择命令后，提示词会先填入输入框，确认后再发送。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if draft.isValidating { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                if let message = error ?? draft.validationMessage { Text(message).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped).disabled(!available)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        guard available, let replacement = draft.replacement else { return }
                        Task {
                            do { try await model.replace(replacement, original: draft.target.original, expectedEpoch: draft.target.epoch); dismiss() }
                            catch { error = error.localizedDescription }
                        }
                    }.disabled(!available || draft.replacement == nil || draft.isValidating)
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-slash-command-editor-\(draft.target.id)-\(model.revision)"),
                title: title, documents: [GuideDocumentReference(id: "slash-commands", title: "Quick Commands")], isActive: available,
                settings: [
                    .readOnly("save_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("draft_requires_native_save") }),
                    .string("trigger", label: NSLocalizedString("激活指令", comment: ""), get: { draft.trigger }, set: { draft.trigger = $0 }),
                    .string("prompt", label: NSLocalizedString("提示词", comment: ""), allowsEmpty: false, get: { draft.prompt }, set: { draft.prompt = $0 })
                ])
        }
        .modifier(MacGuideInspector()).frame(minWidth: 580, minHeight: 460)
        .interactiveDismissDisabled(model.isWorking)
    }
}

@MainActor
private struct MacSlashCommandDeletionView: View {
    let target: MacSlashCommandEditorTarget
    let isActive: Bool
    @ObservedObject var model: MacSlashCommandsModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private var available: Bool { isActive && model.canWrite && model.epoch == target.epoch }

    var body: some View {
        NavigationStack {
            Form {
                Text(target.command?.invocation ?? "").font(.body.monospaced())
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped).navigationTitle(NSLocalizedString("删除", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                        guard available, let command = target.command else { return }
                        Task {
                            do { try await model.delete(command, original: target.original, expectedEpoch: target.epoch); dismiss() }
                            catch { error = error.localizedDescription }
                        }
                    }.disabled(!available)
                }
            }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-slash-command-delete-\(target.id)"),
                title: NSLocalizedString("删除", comment: ""), documents: [GuideDocumentReference(id: "slash-commands", title: "Quick Commands")],
                isActive: available, settings: [.readOnly("command", label: NSLocalizedString("激活指令", comment: ""), value: { .string(target.command?.invocation ?? "") })])
        }
        .modifier(MacGuideInspector()).frame(minWidth: 420, minHeight: 240)
        .interactiveDismissDisabled(model.isWorking)
    }
}

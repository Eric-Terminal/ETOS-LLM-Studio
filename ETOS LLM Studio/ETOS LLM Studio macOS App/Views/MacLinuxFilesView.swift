import ETOSCore
import SwiftUI

struct MacLinuxFilesView: View {
    let isActive: Bool
    @ObservedObject var runtime: MacLinuxModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacLinuxFileModel()
    @State private var visible = false
    @State private var deletion: MacLinuxFileDeletion?
    private var allowed: Bool { isActive && workspace.canManageLocalModels && configuration.localLinuxEnabled && !runtime.isSuspended }
    private var active: Bool { visible && allowed }

    var body: some View {
        List {
            Section {
                MacSettingsIntroCard(id: "linux-files", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac Linux 文件浏览使用说明", comment: ""), documentID: "macos-workspace",
                    isActive: allowed && model.editor == nil && deletion == nil)
                if let directory = model.directory {
                    Text(directory.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if directory.path != "/" {
                        Button { model.load(path: directory.parentPath) } label: { Label(NSLocalizedString("上一级", comment: ""), systemImage: "arrow.up") }
                            .disabled(model.isWorking)
                    }
                }
                Button(NSLocalizedString("刷新", comment: "")) { model.load() }.disabled(model.isWorking)
            }
            if let directory = model.directory {
                Section {
                    ForEach(directory.rows) { row in
                        Button { model.open(row) } label: {
                            HStack {
                                Image(systemName: row.symbol).foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(row.name)
                                    if !row.node.info.isDirectory { Text(row.size).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }.buttonStyle(.plain).disabled(model.isWorking)
                        .contextMenu {
                            Button(NSLocalizedString("删除", comment: ""), role: .destructive) { confirm(row.node) }.disabled(model.isWorking)
                        }
                    }
                    if !directory.snapshot.page.isComplete {
                        Button(NSLocalizedString("加载更多", comment: "")) { model.load(more: true) }.disabled(model.isWorking)
                    } else if directory.rows.isEmpty {
                        Text(NSLocalizedString("此目录为空。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(NSLocalizedString("删除当前目录…", comment: ""), role: .destructive) { confirm(directory.snapshot.node) }.disabled(model.isWorking)
                } footer: {
                    Text(NSLocalizedString("文件读写全部经过 Linux 文件系统。删除系统路径可能让环境损坏；不会硬拦截，需要时可在设置中重置。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if model.needsRepair {
                Text(NSLocalizedString("系统路径已删除，请返回本地 Linux 页面重启或重置。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .navigationTitle(NSLocalizedString("Linux 文件", comment: "")).disabled(!allowed)
        .onAppear { visible = true; if active { model.open() } }
        .onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, value in if value { model.open() } else { close(clearContent: visible) } }
        .onChange(of: runtime.epoch) { _, _ in close(); if active { model.open() } }
        .onChange(of: configuration.appLanguage) { _, _ in model.refreshPresentation() }
        .sheet(item: $model.editor) { target in MacLinuxFileEditor(target: target, isActive: active, model: model) }
        .confirmationDialog(NSLocalizedString("删除 Linux 路径？", comment: ""), isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible, presenting: deletion) { target in
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) { if active { model.remove(target) } }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) { deletion = nil }
        } message: { target in
            Text(String(format: NSLocalizedString("将删除 %@。目录会递归删除，操作无法撤销；系统文件受损后可返回设置重置。", comment: ""), target.node.path))
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-linux-files-\(model.lease)-\(model.directory?.id.uuidString ?? "empty")-\(runtime.epoch)"), title: NSLocalizedString("Linux 文件", comment: ""),
            documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            isActive: active && model.editor == nil && deletion == nil && !model.isWorking,
            settings: [
                .readOnly("directory", label: NSLocalizedString("Linux 文件", comment: ""), value: { model.directory?.guide ?? .null }),
                .readOnly("path", label: NSLocalizedString("路径", comment: ""), value: { .string(GuideSnapshotField.hiddenValue) }),
                .readOnly("read_only", label: NSLocalizedString("文件操作", comment: ""), value: { .bool(true) })
            ])
    }

    private func close(clearContent: Bool = true) { deletion = nil; model.close(clearContent: clearContent) }
    private func confirm(_ node: LocalLinuxBrowserNode) {
        guard active, !model.isWorking else { return }
        deletion = MacLinuxFileDeletion(node: node, lease: model.lease, revision: LocalLinuxActivityBarrier.shared.revision)
    }
}

private struct MacLinuxFileEditor: View {
    let target: MacLinuxFileEditorTarget
    let isActive: Bool
    @ObservedObject var model: MacLinuxFileModel
    @Environment(\.dismiss) private var dismiss
    @State private var content: String
    @State private var visible = false

    init(target: MacLinuxFileEditorTarget, isActive: Bool, model: MacLinuxFileModel) {
        self.target = target; self.isActive = isActive; self.model = model
        _content = State(initialValue: target.preview.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "linux-file-editor", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac Linux 文件浏览使用说明", comment: ""), documentID: "macos-workspace", isActive: isActive)
                    Text(target.preview.node.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    LabeledContent(NSLocalizedString("大小", comment: ""), value: target.size)
                    if let notice = target.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                }
                Section(NSLocalizedString("文件内容", comment: "")) {
                    if target.preview.isEditable {
                        TextEditor(text: $content).font(.body.monospaced()).autocorrectionDisabled().frame(minHeight: 300)
                    } else {
                        Text(content).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if model.isWorking { ProgressView(NSLocalizedString("处理中", comment: "")) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .formStyle(.grouped).navigationTitle(target.title).disabled(!isActive || model.isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("关闭", comment: "")) { dismiss() }.disabled(model.isWorking)
                }
                if target.preview.isEditable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(!isActive || model.isWorking)
                    }
                }
            }
            .onAppear { visible = true }.onDisappear { visible = false }
            .onChange(of: isActive) { _, value in if !value { content = ""; dismiss() } }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-linux-file-editor-\(target.id)-\(model.lease)"), title: NSLocalizedString("文件内容", comment: ""),
                documents: [GuideDocumentReference(id: "local-linux", title: "Local Linux"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                isActive: visible && isActive && !model.isWorking,
                settings: [
                    .readOnly("editable", label: NSLocalizedString("编辑", comment: ""), value: { .bool(target.preview.isEditable) }),
                    .readOnly("content", label: NSLocalizedString("文件内容", comment: ""), value: { .string(GuideSnapshotField.hiddenValue) }),
                    .readOnly("path", label: NSLocalizedString("路径", comment: ""), value: { .string(GuideSnapshotField.hiddenValue) }),
                    .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
                ])
        }.frame(minWidth: 640, minHeight: 560).interactiveDismissDisabled(model.isWorking)
    }

    private func save() {
        let content = content
        Task {
            guard visible, isActive else { return }
            do { try await model.save(target, content: content) } catch { }
        }
    }
}

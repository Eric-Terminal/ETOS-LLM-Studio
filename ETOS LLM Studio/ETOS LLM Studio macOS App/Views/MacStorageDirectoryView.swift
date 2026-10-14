import ETOSCore
import SwiftUI

@MainActor
struct MacStorageDirectoryView: View {
    let location: MacStorageLocation
    let isActive: Bool
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject private var configuration = AppConfigStore.shared
    @StateObject private var model = MacStorageReadModel<MacStorageDirectory>()
    @StateObject private var actions = MacStorageActionModel()
    @State private var selected: Set<String> = []
    @State private var preparedSelection: MacStorageConfirmation?
    @State private var selectionRevision = UUID()
    @State private var confirmation: MacStorageConfirmation?
    @State private var preview: MacStorageFile?
    @State private var visible = false
    private var active: Bool { visible && isActive && workspace.canManageLocalModels }

    var body: some View {
        List {
            Section {
                if model.isLoading { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                if let value = model.value {
                    Text(value.relativePath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    LabeledContent(NSLocalizedString("文件大小", comment: ""), value: value.size)
                    if value.rows.isEmpty { Text(NSLocalizedString("暂无文件", comment: "")).foregroundStyle(.secondary) }
                }
                Button(NSLocalizedString("刷新", comment: ""), action: reload).disabled(model.isLoading)
                Button(NSLocalizedString("删除所选项目", comment: ""), role: .destructive) {
                    guard let preparedSelection else { return }
                    actions.clear(); confirmation = preparedSelection
                }.disabled(preparedSelection == nil)
            } footer: {
                Text(NSLocalizedString("正在使用的数据库及其所在目录不能在文件浏览器中删除。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let value = model.value {
                ForEach(value.rows) { file in
                    HStack {
                        Toggle(NSLocalizedString("选择", comment: ""), isOn: Binding(
                            get: { selected.contains(file.id) }, set: { selectedFlag in
                                if selectedFlag { selected.insert(file.id) } else { selected.remove(file.id) }
                            }))
                            .toggleStyle(.checkbox).labelsHidden().disabled(!file.deletionAllowed)
                        if file.item.isDirectory {
                            NavigationLink {
                                MacStorageDirectoryView(location: MacStorageLocation(title: file.item.name, url: file.item.url), isActive: isActive)
                            } label: { MacStorageFileLabel(file: file) }
                        } else {
                            Button { preview = file } label: { MacStorageFileLabel(file: file) }.buttonStyle(.plain)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                            actions.clear(); confirmation = MacStorageConfirmation(mutation: .files([file]), detail: file.item.name)
                        }.disabled(!file.deletionAllowed)
                    }
                }
            }
            if let report = actions.report { Text(report).font(.footnote).textSelection(.enabled) }
            if let error = actions.error ?? model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(location.displayTitle).disabled(!isActive || !workspace.canManageLocalModels || actions.isWorking)
        .onAppear { visible = true }
        .onDisappear { visible = false; close(clearContent: false) }
        .onChange(of: active) { _, active in if active { reload() } else { close(clearContent: visible) } }
        .onChange(of: configuration.appLanguage) { _, _ in close(clearContent: visible); actions.clear(); reload() }
        .onChange(of: selected) { _, _ in prepareSelection() }
        .onChange(of: actions.isWorking) { _, working in if !working && active { reload() } }
        .sheet(item: $confirmation) { MacStorageConfirmationView(target: $0, actions: actions) }
        .sheet(item: $preview) { file in
            NavigationStack {
                if file.isSQLite { MacStorageSQLiteView(file: file, isActive: active) }
                else { MacStorageFilePreviewView(file: file, isActive: active) }
            }
            .modifier(MacGuideInspector()).frame(minWidth: 680, minHeight: 500)
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-storage-directory-\(location.id)-\(model.revision)"),
            title: NSLocalizedString("文件", comment: ""), documents: [GuideDocumentReference(id: "storage-management", title: "Storage Management")],
            isActive: active && preview == nil && confirmation == nil, settings: [
                .readOnly("loading", label: NSLocalizedString("正在加载…", comment: ""), value: { .bool(model.isLoading) }),
                .readOnly("file_count", label: NSLocalizedString("文件", comment: ""), value: { .int(model.value?.fileCount ?? 0) }),
                .readOnly("folder_count", label: NSLocalizedString("文件夹", comment: ""), value: { .int(model.value?.folderCount ?? 0) }),
                .readOnly("selected_count", label: NSLocalizedString("选择", comment: ""), value: { .int(selected.count) })
            ])
    }

    private func close(clearContent: Bool = true) {
        model.close(clearContent: clearContent); selected.removeAll(); preparedSelection = nil; selectionRevision = UUID(); preview = nil
        if !actions.isWorking { confirmation = nil }
    }
    private func reload() {
        guard active, !model.isLoading else { return }
        selected.removeAll(); preparedSelection = nil; selectionRevision = UUID()
        let location = location
        model.load(workspace: workspace) { try MacStorageDirectory.load(location, access: .application()) }
    }
    private func prepareSelection() {
        preparedSelection = nil; selectionRevision = UUID()
        guard active, let directory = model.value, !selected.isEmpty else { return }
        let selection = selected, expected = selectionRevision, revision = model.revision
        Task {
            let target = await Task.detached { () -> MacStorageConfirmation? in
                let files = selection.compactMap { directory.byID[$0] }.sorted { $0.id < $1.id }
                guard files.count == selection.count, files.allSatisfy(\.deletionAllowed) else { return nil }
                return .files(files)
            }.value
            guard active, model.revision == revision, selectionRevision == expected, selected == selection else { return }
            preparedSelection = target
        }
    }
}

@MainActor
private struct MacStorageFileLabel: View {
    let file: MacStorageFile
    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(file.item.name).lineLimit(2)
                Text(file.size).font(.caption).foregroundStyle(.secondary)
                Text(file.modified).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } icon: { Image(systemName: file.symbol).foregroundStyle(.tint) }
    }
}

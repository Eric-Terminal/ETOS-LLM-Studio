import ETOSCore
import SwiftUI

struct MacSessionLibrarySidebar: View {
    @ObservedObject var model: MacSessionLibraryModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var editor: MacSessionClassificationEditor?
    @State private var deletion: MacSessionClassificationEditor?

    var body: some View {
        List(selection: Binding<MacSessionScope?>(get: { model.scope }, set: { if let value = $0 { model.scope = value } })) {
            Section {
                countedLabel(NSLocalizedString("对话", comment: ""), symbol: "bubble.left.and.bubble.right", count: model.snapshot.allCount)
                    .tag(MacSessionScope.all)
                countedLabel(NSLocalizedString("未分类", comment: ""), symbol: "tray", count: model.snapshot.unfiledCount)
                    .tag(MacSessionScope.unfiled)
            }
            Section {
                ForEach(model.snapshot.folders) { row in
                    countedLabel(row.path, symbol: "folder", count: row.count)
                        .tag(MacSessionScope.folder(row.id))
                        .contextMenu {
                            Button(NSLocalizedString("编辑", comment: "")) { editor = .folder(row.folder, parentID: row.folder.parentID) }
                            Button(NSLocalizedString("新建子文件夹", comment: "")) { editor = .folder(nil, parentID: row.id) }
                            Button(NSLocalizedString("删除文件夹", comment: ""), role: .destructive) { deletion = .folder(row.folder, parentID: nil) }
                        }
                }
            } header: { Text(NSLocalizedString("文件夹", comment: "")) }
            Section {
                ForEach(model.snapshot.tags) { row in
                    countedLabel(row.name, symbol: "tag", count: row.count)
                        .foregroundStyle(row.tag.color?.macColor ?? .primary)
                        .tag(MacSessionScope.tag(row.id))
                        .contextMenu {
                            Button(NSLocalizedString("编辑标签", comment: "")) { editor = .tag(row.tag) }
                            Button(NSLocalizedString("删除标签", comment: ""), role: .destructive) { deletion = .tag(row.tag) }
                        }
                }
            } header: { Text(NSLocalizedString("标签", comment: "")) }
            Section {
                ForEach(model.snapshot.colorTags) { row in
                    countedLabel(row.name, symbol: "circle.fill", count: row.count)
                        .foregroundStyle(row.tag.color?.macColor ?? .primary)
                        .tag(MacSessionScope.tag(row.id))
                }
            } header: { Text(NSLocalizedString("颜色", comment: "")) }
        }
        .navigationTitle(NSLocalizedString("会话管理", comment: ""))
        .navigationSplitViewColumnWidth(min: 170, ideal: 210)
        .toolbar {
            Menu {
                Button(NSLocalizedString("新建文件夹", comment: "")) { editor = .folder(nil, parentID: nil) }
                Button(NSLocalizedString("新建标签", comment: "")) { editor = .tag(nil) }
            } label: { Label(NSLocalizedString("添加", comment: ""), systemImage: "plus") }
            SettingsLink { Label(NSLocalizedString("设置", comment: ""), systemImage: "gearshape") }
        }
        .disabled(model.isWorking || workspace.isRestoringData || workspace.isMutatingHistory)
        .sheet(item: $editor) { editor in
            switch editor {
            case .folder(let original, let parentID): MacSessionFolderEditor(model: model, original: original, parentID: parentID)
            case .tag(let original): MacSessionTagEditor(model: model, original: original)
            }
        }
        .confirmationDialog(NSLocalizedString("确认删除", comment: ""), isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let pending = deletion else { return }
                deletion = nil
                Task {
                    do {
                        switch pending {
                        case .folder(let folder?, _): try await model.deleteFolder(folder)
                        case .tag(let tag?): try await model.deleteTag(tag)
                        default: break
                        }
                    } catch { model.error = error.localizedDescription }
                }
            }
        } message: {
            if case .folder(let folder?, _) = deletion {
                Text(String(format: NSLocalizedString("将删除 %@。文件夹内的会话会移回未分类，操作不可恢复。", comment: ""), folder.name))
            } else { Text(NSLocalizedString("删除标签只会移除分类，会话内容保持不变。", comment: "")) }
        }
        .alert(NSLocalizedString("错误", comment: ""), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(NSLocalizedString("好", comment: ""), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .guideSettingsPageContext(
            id: deletion == nil ? "mac-session-library" : "mac-session-library-confirmation",
            title: NSLocalizedString("会话管理", comment: ""),
            documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
            settings: [
                .readOnly("scope", label: NSLocalizedString("位置", comment: ""), value: { .string(model.snapshot.title) }),
                .readOnly("folders", label: NSLocalizedString("文件夹", comment: ""), value: { model.snapshot.folderGuideValues }),
                .readOnly("tags", label: NSLocalizedString("标签", comment: ""), value: { model.snapshot.tagGuideValues }),
                .readOnly("manual_confirmation", label: NSLocalizedString("确认删除", comment: ""), value: { .bool(deletion != nil) }),
                .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(model.isWorking) }),
                .readOnly("temporary_chat", label: NSLocalizedString("临时对话", comment: ""), value: { .bool(workspace.temporaryChatMemoryMode != nil) })
            ]
        )
        .modifier(MacGuideInspector())
    }

    private func countedLabel(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol).lineLimit(1)
            Spacer()
            Text(count, format: .number).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private enum MacSessionClassificationEditor: Identifiable {
    case folder(SessionFolder?, parentID: UUID?), tag(SessionTag?)
    var id: String {
        switch self {
        case .folder(let folder, let parent): "folder-\(folder?.id.uuidString ?? "new")-\(parent?.uuidString ?? "root")"
        case .tag(let tag): "tag-\(tag?.id.uuidString ?? "new")"
        }
    }
}

extension SessionTagColor {
    var macColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

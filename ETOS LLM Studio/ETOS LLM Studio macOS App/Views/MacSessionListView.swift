import ETOSCore
import SwiftUI

struct MacSessionListView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject var model: MacSessionLibraryModel
    let edit: (ChatSession) -> Void
    let delete: (ChatSession) -> Void

    var body: some View {
        List(selection: Binding(get: { workspace.currentSession?.id }, set: { workspace.selectSession($0) })) {
            ForEach(model.snapshot.sessions) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.session.name).lineLimit(2)
                        if !row.subtitle.isEmpty { Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if !row.colors.isEmpty {
                            HStack {
                                ForEach(row.colors) { color in
                                    Image(systemName: "circle.fill").font(.caption2).foregroundStyle(color.macColor)
                                        .accessibilityLabel(color.localizedName)
                                }
                            }
                        }
                    }
                    Spacer()
                    if workspace.pendingQuestionnaireSessionIDs.contains(row.id) {
                        Image(systemName: "questionmark.bubble").help(NSLocalizedString("等待你的回答", comment: ""))
                    }
                    if workspace.runningSessionIDs.contains(row.id) { ProgressView().controlSize(.small) }
                }
                .tag(row.id)
                .contextMenu {
                    Button(NSLocalizedString("编辑", comment: "")) { edit(row.session) }
                    Menu(NSLocalizedString("移动到文件夹", comment: "")) {
                        Button(NSLocalizedString("未分类", comment: "")) { model.moveSession(row.session, to: nil) }
                        ForEach(model.snapshot.folders) { folder in
                            Button(folder.path) { model.moveSession(row.session, to: folder.id) }
                        }
                    }
                    Menu(NSLocalizedString("标签", comment: "")) {
                        ForEach(model.snapshot.tags) { tag in
                            Toggle(tag.name, isOn: Binding(get: { row.tagIDs.contains(tag.id) }, set: { _ in model.toggleTag(tag.tag, for: row.session) }))
                        }
                        Divider()
                        ForEach(model.snapshot.colorTags) { tag in
                            Toggle(tag.name, isOn: Binding(get: { row.tagIDs.contains(tag.id) }, set: { _ in model.toggleTag(tag.tag, for: row.session) }))
                        }
                    }
                    Divider()
                    Button(NSLocalizedString("删除", comment: ""), role: .destructive) { delete(row.session) }
                }
            }
        }
        .overlay {
            if model.snapshot.sessions.isEmpty { ContentUnavailableView(NSLocalizedString("暂无会话", comment: ""), systemImage: "bubble.left.and.bubble.right") }
        }
        .navigationTitle(model.snapshot.title)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        .searchable(text: $model.query, prompt: NSLocalizedString("搜索会话标题或消息", comment: ""))
        .toolbar {
            Button { workspace.newSession() } label: { Label(NSLocalizedString("新建对话", comment: ""), systemImage: "square.and.pencil") }
        }
        .disabled(model.isWorking)
    }
}

import ETOSCore
import SwiftUI

struct MacSessionListView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject var model: MacSessionLibraryModel
    let edit: (ChatSession) -> Void
    let delete: (ChatSession) -> Void
    let analyze: (ChatSession) -> Void
    @State private var showsOrganization = false

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            sessions
            sidebarFooter
        }
        .navigationTitle(NSLocalizedString("对话", comment: ""))
        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        .sheet(isPresented: $showsOrganization) {
            NavigationStack {
                MacSessionLibrarySidebar(model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("完成", comment: "")) { showsOrganization = false }
                        }
                    }
            }.frame(minWidth: 360, minHeight: 480)
        }
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading) {
            Button {
                model.scope = .all; model.query = ""
                workspace.newSession()
            } label: {
                Label(NSLocalizedString("新建对话", comment: ""), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(workspace.isRestoringData || workspace.isMutatingHistory)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("搜索会话标题或消息", comment: ""), text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help(NSLocalizedString("清除", comment: ""))
                }
            }
            .padding(.vertical, 6)
            Menu {
                Picker(NSLocalizedString("会话管理", comment: ""), selection: $model.scope) {
                    Text(NSLocalizedString("对话", comment: "")).tag(MacSessionScope.all)
                    Text(NSLocalizedString("未分类", comment: "")).tag(MacSessionScope.unfiled)
                    ForEach(model.snapshot.folders) { row in
                        Label(row.path, systemImage: "folder").tag(MacSessionScope.folder(row.id))
                    }
                    ForEach(model.snapshot.tags) { row in
                        Label(row.name, systemImage: "tag").tag(MacSessionScope.tag(row.id))
                    }
                    ForEach(model.snapshot.colorTags) { row in
                        Label(row.name, systemImage: "circle.fill").tag(MacSessionScope.tag(row.id))
                    }
                }
                Divider()
                Button(NSLocalizedString("会话管理", comment: "")) { showsOrganization = true }
            } label: {
                HStack {
                    Text(model.snapshot.title).lineLimit(1)
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding([.horizontal, .top])
    }

    private var sidebarFooter: some View {
        SettingsLink {
            Label(NSLocalizedString("设置", comment: ""), systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(workspace.isRestoringData)
    }

    private var sessions: some View {
        List(selection: Binding(get: { workspace.currentSession?.id }, set: { workspace.selectSession($0) })) {
            ForEach(model.snapshot.sessions) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(row.session.name).lineLimit(1)
                        if !row.subtitle.isEmpty { Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
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
                .padding(.vertical, 4)
                .tag(row.id)
                .contextMenu {
                    Button(NSLocalizedString("编辑", comment: "")) { edit(row.session) }
                    Button { analyze(row.session) } label: {
                        Label(NSLocalizedString("session_usage.title", value: "Conversation Analytics", comment: "会话分析统计入口"), systemImage: "chart.bar.xaxis")
                    }.disabled(!workspace.canManageLocalModels)
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
        .listStyle(.sidebar)
        .disabled(model.isWorking)
    }
}

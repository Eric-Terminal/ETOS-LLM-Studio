import SwiftUI
import Shared

struct WorldbookSettingsView: View {
    @ObservedObject var viewModel: ChatViewModel

    @State private var worldbooks: [Worldbook] = []
    @State private var selected = Set<UUID>()
    @State private var worldbookToDelete: Worldbook?

    var body: some View {
        List {
            if let session = viewModel.currentSession {
                Section(NSLocalizedString("当前会话", comment: "Current session section")) {
                    NavigationLink {
                        WatchWorldbookSessionBindingView(
                            session: Binding(
                                get: { viewModel.currentSession },
                                set: { viewModel.currentSession = $0 }
                            )
                        )
                    } label: {
                        HStack {
                            Text(NSLocalizedString("绑定世界书", comment: "Bind worldbooks"))
                            Spacer()
                            Text(bindingSummary(for: session))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section(NSLocalizedString("世界书列表", comment: "Worldbook list section")) {
                if worldbooks.isEmpty {
                    Text(NSLocalizedString("暂无世界书，请在 iPhone 端导入后同步。", comment: "No worldbooks on watch"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(worldbooks) { book in
                        NavigationLink {
                            WatchWorldbookDetailView(worldbookID: book.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(book.name)
                                    Spacer()
                                    Text(book.isEnabled
                                         ? NSLocalizedString("已启用", comment: "Worldbook enabled status")
                                         : NSLocalizedString("已停用", comment: "Worldbook disabled status"))
                                        .font(.caption2)
                                        .foregroundStyle(book.isEnabled ? .green : .secondary)
                                }
                                Text(String(format: NSLocalizedString("%d 条", comment: "Entry count short"), book.entries.count))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                if selected.contains(book.id) {
                                    Text(NSLocalizedString("已绑定当前会话", comment: "Bound current session"))
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                worldbookToDelete = book
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("世界书", comment: "Worldbook nav title"))
        .onAppear(perform: load)
        .confirmationDialog(
            NSLocalizedString("确认删除世界书", comment: "Confirm deleting worldbook title"),
            isPresented: Binding(
                get: { worldbookToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        worldbookToDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                confirmDeleteWorldbook()
            }
            Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                worldbookToDelete = nil
            }
        } message: {
            if let worldbookToDelete {
                Text(
                    String(
                        format: NSLocalizedString("将删除“%@”，此操作不可恢复。", comment: "Delete worldbook confirmation message"),
                        worldbookToDelete.name
                    )
                )
            }
        }
    }

    private func load() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
        selected = Set(viewModel.currentSession?.worldbookIDs ?? [])
    }

    private func bindingSummary(for session: ChatSession) -> String {
        let boundSet = Set(session.worldbookIDs)
        let boundBooks = worldbooks.filter { boundSet.contains($0.id) }
        let boundBookCount = boundBooks.count
        let totalBookCount = worldbooks.count
        let boundEntryCount = boundBooks.reduce(0) { $0 + $1.entries.count }
        return String(
            format: NSLocalizedString("%d/%d 本 · %d 条", comment: "Bound worldbook summary"),
            boundBookCount,
            totalBookCount,
            boundEntryCount
        )
    }

    private func confirmDeleteWorldbook() {
        guard let target = worldbookToDelete else { return }
        ChatService.shared.deleteWorldbook(id: target.id)
        if var session = viewModel.currentSession {
            session.worldbookIDs.removeAll { $0 == target.id }
            viewModel.currentSession = session
        }
        worldbookToDelete = nil
        load()
    }

}

private struct WatchWorldbookDetailView: View {
    let worldbookID: UUID

    @State private var worldbook: Worldbook?

    var body: some View {
        List {
            if let worldbook {
                Section(NSLocalizedString("基本信息", comment: "Basic info")) {
                    Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: enabledBinding)
                    Text(String(format: NSLocalizedString("条目数量：%d", comment: "Entry count"), worldbook.entries.count))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(NSLocalizedString("条目", comment: "Entries section")) {
                    if worldbook.entries.isEmpty {
                        Text(NSLocalizedString("暂无条目", comment: "No entries"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(worldbook.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.comment.isEmpty ? NSLocalizedString("(无注释)", comment: "No comment") : entry.comment)
                                    .font(.footnote)
                                Text(entry.content)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Section {
                    Text(NSLocalizedString("世界书不存在或已被删除。", comment: "Worldbook missing"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("世界书详情", comment: "Worldbook detail title"))
        .onAppear(perform: load)
    }

    private func load() {
        worldbook = ChatService.shared.loadWorldbooks().first(where: { $0.id == worldbookID })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { worldbook?.isEnabled ?? false },
            set: { setEnabled($0) }
        )
    }

    private func setEnabled(_ enabled: Bool) {
        guard var worldbook else { return }
        worldbook.isEnabled = enabled
        worldbook.updatedAt = Date()
        ChatService.shared.saveWorldbook(worldbook)
        self.worldbook = worldbook
    }
}

private struct WatchWorldbookSessionBindingView: View {
    @Binding var session: ChatSession?
    @State private var worldbooks: [Worldbook] = []
    @State private var selected = Set<UUID>()

    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("打开开关即可绑定到当前会话。", comment: "Binding hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if worldbooks.isEmpty {
                Text(NSLocalizedString("暂无可绑定世界书", comment: "No bindable worldbook on watch"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(worldbooks) { book in
                    Toggle(isOn: bindingForSelection(book.id)) {
                        HStack {
                            Text(book.name)
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("会话绑定", comment: "Session binding title"))
        .onAppear(perform: load)
    }

    private func load() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
        selected = Set(session?.worldbookIDs ?? [])
    }

    private func toggle(_ id: UUID) {
        guard var current = session else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        current.worldbookIDs = selected.sorted(by: { $0.uuidString < $1.uuidString })
        session = current
        ChatService.shared.assignWorldbooks(to: current.id, worldbookIDs: current.worldbookIDs)
    }

    private func bindingForSelection(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isBound in
                let currentlyBound = selected.contains(id)
                guard isBound != currentlyBound else { return }
                toggle(id)
            }
        )
    }
}

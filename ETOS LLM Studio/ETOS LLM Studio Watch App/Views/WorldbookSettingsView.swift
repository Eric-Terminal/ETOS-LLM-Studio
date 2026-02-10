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
                            Text("\(session.worldbookIDs.count)")
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
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(book.name)
                                Spacer()
                                Toggle("启用", isOn: bindingForEnable(book.id))
                                    .labelsHidden()
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

    private func bindingForEnable(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: {
                worldbooks.first(where: { $0.id == id })?.isEnabled ?? false
            },
            set: { enabled in
                guard var target = worldbooks.first(where: { $0.id == id }) else { return }
                target.isEnabled = enabled
                target.updatedAt = Date()
                ChatService.shared.saveWorldbook(target)
                load()
            }
        )
    }
}

private struct WatchWorldbookSessionBindingView: View {
    @Binding var session: ChatSession?
    @State private var worldbooks: [Worldbook] = []
    @State private var selected = Set<UUID>()

    var body: some View {
        List {
            if worldbooks.isEmpty {
                Text(NSLocalizedString("暂无可绑定世界书", comment: "No bindable worldbook on watch"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(worldbooks) { book in
                    Button {
                        toggle(book.id)
                    } label: {
                        HStack {
                            Text(book.name)
                            Spacer()
                            if selected.contains(book.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
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
}

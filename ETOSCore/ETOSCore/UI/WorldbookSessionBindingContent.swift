import SwiftUI
import Combine

/// 双端共享选择与向导逻辑，详情和管理页保留各自的平台导航。
@MainActor
public struct WorldbookSessionBindingContent<Detail: View, Management: View>: View {
    @Binding private var session: ChatSession?
    private let detail: (UUID) -> Detail
    private let management: () -> Management

    @State private var library: WorldbookBindingSnapshot?
    @State private var loadedSessionID: UUID?
    @State private var selected = Set<UUID>()
    @State private var refreshID = UUID()
    @State private var isSaving = false
    @State private var editingBook: WorldbookBindingTarget?

    public init(
        session: Binding<ChatSession?>,
        @ViewBuilder detail: @escaping (UUID) -> Detail,
        @ViewBuilder management: @escaping () -> Management
    ) {
        _session = session
        self.detail = detail
        self.management = management
    }

    public var body: some View {
        List {
            Section {
                NavigationLink {
                    management()
                } label: {
                    Label(NSLocalizedString("worldbook.binding.manage", value: "Manage Worldbooks", comment: "世界书管理入口"), systemImage: "books.vertical")
                }
            } footer: {
                Text(NSLocalizedString("worldbook.binding.manage_hint", value: "Add, import, or delete worldbooks. Edits apply to every conversation using the same book.", comment: "世界书管理作用范围"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if library == nil {
                    ProgressView()
                } else if let library, library.rows.isEmpty {
                    Text(NSLocalizedString("worldbook.binding.empty", value: "No worldbooks yet. Open Manage Worldbooks to add or import one.", comment: "世界书绑定空状态"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let library {
                    ForEach(library.rows) { book in
                        Button {
                            guard canSelect else { return }
                            if selected.contains(book.id) {
                                selected.remove(book.id)
                            } else {
                                selected.insert(book.id)
                            }
                            Task { await persistSelection() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(book.name)
                                    Text(String(format: NSLocalizedString("worldbook.binding.entries", value: "%d of %d entries enabled", comment: "世界书启用条目计数"), book.enabledEntryCount, book.entryCount))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if !book.isEnabled {
                                        Text(NSLocalizedString("worldbook.binding.disabled", value: "Book disabled; it will not be injected", comment: "停用世界书绑定提示"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let source = book.roleplaySource {
                                        Text(String(format: NSLocalizedString("worldbook.binding.role_source", value: "Also provided by: %@", comment: "角色附带世界书来源"), source))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(book.id) ? Color.accentColor : Color.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSelect)
                        .accessibilityValue(selected.contains(book.id)
                            ? NSLocalizedString("已绑定当前会话", value: "Bound to this conversation", comment: "世界书绑定状态")
                            : NSLocalizedString("worldbook.binding.unbound", value: "Not manually bound", comment: "世界书未手动绑定状态"))
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingBook = WorldbookBindingTarget(id: book.id)
                            } label: {
                                Label(NSLocalizedString("编辑", value: "Edit", comment: "编辑世界书"), systemImage: "square.and.pencil")
                            }
                            .tint(.blue)
                        }
                        #if os(iOS)
                        .contextMenu {
                            Button {
                                editingBook = WorldbookBindingTarget(id: book.id)
                            } label: {
                                Label(NSLocalizedString("编辑", value: "Edit", comment: "编辑世界书"), systemImage: "square.and.pencil")
                            }
                        }
                        #endif
                    }
                }
            } header: {
                Text(NSLocalizedString("当前会话", value: "Current Conversation", comment: "当前会话世界书绑定"))
            } footer: {
                VStack(alignment: .leading) {
                    Text(session == nil
                        ? NSLocalizedString("worldbook.binding.no_session", value: "Open a conversation to choose its worldbooks.", comment: "无会话时的世界书绑定提示")
                        : NSLocalizedString("worldbook.binding.select_hint", value: "Tap to bind or unbind for this conversation. Swipe a book to edit it. Changes are saved immediately.", comment: "世界书快捷绑定操作说明"))
                    if library?.roleplayIDs.isEmpty == false {
                        Text(NSLocalizedString("worldbook.binding.role_hint", value: "Unchecking a book removes only its manual binding. Books provided by a role remain available through Roleplay settings.", comment: "角色世界书与手动绑定的区别"))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .disabled(isSaving)
        .navigationTitle(NSLocalizedString("会话绑定世界书", value: "Conversation Worldbooks", comment: "世界书绑定页标题"))
        .navigationDestination(item: $editingBook) { target in
            detail(target.id)
        }
        .task(id: WorldbookBindingReloadKey(sessionID: session?.id, refreshID: refreshID)) {
            let sessionID = session?.id
            if loadedSessionID != sessionID {
                library = nil
                selected = Set(session?.lorebookIDs ?? [])
            }
            let snapshot = await Task.detached(priority: .userInitiated) {
                WorldbookBindingSnapshot.load(sessionID: sessionID)
            }.value
            guard !Task.isCancelled, session?.id == sessionID else { return }
            library = snapshot
            loadedSessionID = sessionID
            if !isSaving { selected = Set(session?.lorebookIDs ?? []) }
        }
        .onChange(of: session?.lorebookIDs) { _, ids in
            if !isSaving { selected = Set(ids ?? []) }
        }
        .onReceive(NotificationCenter.default.publisher(for: WorldbookStore.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            refreshID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification).receive(on: DispatchQueue.main)) { notification in
            if notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String == RoleplayStore.libraryChangeKind {
                refreshID = UUID()
            }
        }
        .guidePageContext(
            descriptor: GuidePageDescriptor(
                id: guidePageID,
                title: guideTitle,
                documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks")],
                tools: canSelect ? [GuidePageTool(
                    definition: GuideDeclarativeSettingsSupport.toolDefinition(pageTitle: guideTitle, settings: guideSettings),
                    access: .proposeChange
                )] : []
            ),
            snapshot: { GuideDeclarativeSettingsSupport.snapshot(settings: guideSettings) },
            buildProposal: { call, snapshot in
                try GuideDeclarativeSettingsSupport.buildProposal(call: call, pageID: guidePageID, pageTitle: guideTitle, settings: guideSettings, snapshot: snapshot)
            },
            execute: { proposal in
                guard canSelect else { throw GuideError.invalidToolArguments }
                let result = try GuideDeclarativeSettingsSupport.execute(proposal: proposal, pageID: guidePageID, pageTitle: guideTitle, settings: guideSettings)
                await persistSelection()
                return result
            }
        )
    }

    private var canSelect: Bool {
        session != nil && loadedSessionID == session?.id && library != nil && !isSaving
    }

    private var guidePageID: GuidePageID {
        GuidePageID(rawValue: "worldbook-bindings-\(session?.id.uuidString ?? "none")")
    }

    private var guideTitle: String {
        NSLocalizedString("会话绑定世界书", value: "Conversation Worldbooks", comment: "世界书绑定向导标题")
    }

    private var guideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .readOnly("session_id", label: NSLocalizedString("当前会话", value: "Current Conversation", comment: "世界书向导会话"), value: { .string(session?.id.uuidString ?? "") }),
            .readOnly("worldbooks", label: NSLocalizedString("世界书列表", value: "Worldbooks", comment: "世界书向导列表"), value: { library?.guideValue ?? .array([]) }),
            .readOnly("save_required", label: NSLocalizedString("修改后需要保存", value: "Save required after changes", comment: "世界书向导保存说明"), value: { .bool(false) })
        ]
        if canSelect, let library {
            settings.append(.json(
                "current_session_worldbook_ids",
                label: NSLocalizedString("当前会话绑定的世界书", value: "Worldbooks bound to this conversation", comment: "世界书向导绑定字段"),
                schema: library.selectionSchema,
                get: { .array(selected.map(\.uuidString).sorted().map(JSONValue.string)) },
                normalize: { value in
                    .array(try library.selection(from: value).map(\.uuidString).sorted().map(JSONValue.string))
                },
                set: { value in selected = try library.selection(from: value) }
            ))
        }
        return settings
    }

    private func persistSelection() async {
        guard canSelect, let sessionID = session?.id else { return }
        isSaving = true
        let ids = selected.sorted { $0.uuidString < $1.uuidString }
        // 按会话 ID 保存；等待磁盘时切换对话，不会把旧选择写回新对话。
        await Task.detached(priority: .userInitiated) {
            ChatService.shared.assignWorldbooks(to: sessionID, worldbookIDs: ids)
        }.value
        if var current = session, current.id == sessionID {
            current.lorebookIDs = ids
            session = current
        }
        selected = Set(session?.lorebookIDs ?? [])
        isSaving = false
    }
}

private struct WorldbookBindingTarget: Hashable, Identifiable {
    let id: UUID
}

private struct WorldbookBindingReloadKey: Equatable {
    let sessionID: UUID?
    let refreshID: UUID
}

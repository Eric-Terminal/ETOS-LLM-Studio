// ============================================================================
// WorldbookSettingsView.swift
// ============================================================================
// WorldbookSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import Shared

struct WorldbookSessionBindingView: View {
    enum InjectionBindingTab: String, CaseIterable, Identifiable {
        case mode
        case lorebooks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mode:
                return NSLocalizedString("Mode Injections", comment: "Mode injection tab")
            case .lorebooks:
                return NSLocalizedString("Lorebooks", comment: "Lorebooks tab")
            }
        }
    }

    @Binding var currentSession: ChatSession?

    @State var worldbooks: [Worldbook] = []
    @State var selected = Set<UUID>()
    @State var selectedTab: InjectionBindingTab = .lorebooks

    var body: some View {
        List {
            Section {
                Picker(NSLocalizedString("注入类型", comment: "Injection type"), selection: $selectedTab) {
                    ForEach(InjectionBindingTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .tint(.blue)
            }

            Section {
                Toggle(
                    NSLocalizedString("绑定世界书时屏蔽记忆与工具", comment: "Worldbook isolation toggle"),
                    isOn: Binding(
                        get: { currentSession?.worldbookContextIsolationEnabled ?? false },
                        set: { updateIsolationMode($0) }
                    )
                )

                Text(NSLocalizedString("开启后，在当前会话已绑定世界书时，只发送全局提示词、话题提示词、增强提示词和世界书，不发送记忆系统、MCP 与快捷指令工具调用。", comment: "Worldbook isolation description"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(NSLocalizedString("点击条目即可绑定或取消绑定。", comment: "Binding hint tap row"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if selectedTab == .mode {
                Text(NSLocalizedString("Mode Injection 绑定功能将与助手注入页对齐，当前版本先保留 Lorebook 绑定。", comment: "Mode injection placeholder"))
                    .foregroundStyle(.secondary)
            } else {
                if worldbooks.isEmpty {
                    Text(NSLocalizedString("暂无可绑定的世界书。", comment: "No bindable worldbook"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(worldbooks) { book in
                        Button {
                            toggle(book.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.name)
                                    Text(String(format: NSLocalizedString("%d 条", comment: "Entry count short"), book.entries.count))
                                        .etFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        selected.contains(book.id)
                                        ? AnyShapeStyle(.tint)
                                        : AnyShapeStyle(.tertiary)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("会话绑定世界书", comment: "Session binding title"))
        .onAppear(perform: load)
    }

    func load() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
        selected = Set(currentSession?.lorebookIDs ?? [])
    }

    func toggle(_ id: UUID) {
        guard var session = currentSession else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        session.lorebookIDs = selected.sorted(by: { $0.uuidString < $1.uuidString })
        persistSessionSettings(session)
    }

    func updateIsolationMode(_ isEnabled: Bool) {
        guard var session = currentSession else { return }
        session.worldbookContextIsolationEnabled = isEnabled
        persistSessionSettings(session)
    }

    func persistSessionSettings(_ session: ChatSession) {
        currentSession = session
        ChatService.shared.updateWorldbookSessionSettings(
            sessionID: session.id,
            worldbookIDs: session.lorebookIDs,
            worldbookContextIsolationEnabled: session.worldbookContextIsolationEnabled
        )
    }
}

// ============================================================================
// WorldbookSettingsView+EntryEditorAndSessionBinding.swift
// ============================================================================
// watchOS 世界书条目编辑、会话绑定与关键词解析辅助视图。
// ============================================================================

import SwiftUI
import Shared

struct WatchWorldbookEntryEditView: View {
    @Environment(\.dismiss) var dismiss

    @State var draft: WatchWorldbookEntryDraft

    let onSave: (WorldbookEntry) -> Void

    let onDelete: (() -> Void)?

    init(draft: WatchWorldbookEntryDraft, onSave: @escaping (WorldbookEntry) -> Void, onDelete: (() -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var canSave: Bool {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return false }
        if !draft.constant && parseKeywordList(draft.keysText).isEmpty { return false }
        return true
    }

    var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    var orderBinding: Binding<Int> {
        Binding(
            get: { draft.order },
            set: { newValue in
                draft.order = min(1000, max(0, newValue))
            }
        )
    }

    var depthBinding: Binding<Int> {
        Binding(
            get: { draft.depth },
            set: { newValue in
                draft.depth = max(0, newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("基础", comment: "Entry base section")) {
                TextField(
                    NSLocalizedString("注释", comment: "Comment field"),
                    text: $draft.comment.watchKeyboardNewlineBinding(normalizeSmartQuotes: true),
                    axis: .vertical
                )
                .lineLimit(1...4)
                TextField(
                    NSLocalizedString("内容", comment: "Content field"),
                    text: $draft.content.watchKeyboardNewlineBinding(normalizeSmartQuotes: true),
                    axis: .vertical
                )
                .lineLimit(4...12)
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: $draft.isEnabled)
            }

            Section(NSLocalizedString("触发", comment: "Entry trigger section")) {
                TextField(
                    NSLocalizedString("关键词（逗号分隔）", comment: "Keywords field"),
                    text: $draft.keysText.watchKeyboardNewlineBinding(normalizeSmartQuotes: true),
                    axis: .vertical
                )
                .lineLimit(2...6)
                Toggle(NSLocalizedString("常驻激活", comment: "Constant active"), isOn: $draft.constant)
                Toggle(NSLocalizedString("正则匹配", comment: "Regex match"), isOn: $draft.useRegex)
                Toggle(NSLocalizedString("区分大小写", comment: "Case sensitive"), isOn: $draft.caseSensitive)
            }

            Section(NSLocalizedString("插入", comment: "Entry position section")) {
                Picker(NSLocalizedString("位置", comment: "Position"), selection: $draft.position) {
                    ForEach(WorldbookPosition.allCases, id: \.self) { position in
                        Text(worldbookPositionLabel(position)).tag(position)
                    }
                }
                Picker(NSLocalizedString("角色", comment: "Role"), selection: $draft.role) {
                    ForEach(WorldbookEntryRole.allCases, id: \.self) { role in
                        Text(worldbookEntryRoleLabel(role)).tag(role)
                    }
                }
                HStack {
                    Text(String(format: NSLocalizedString("优先级：%d", comment: "Order value"), draft.order))
                    Spacer()
                    TextField(NSLocalizedString("数量", comment: ""), value: orderBinding, formatter: numberFormatter)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                }
                if draft.position == .atDepth {
                    HStack {
                        Text(String(format: NSLocalizedString("深度：%d", comment: "Depth value"), draft.depth))
                        Spacer()
                        TextField(NSLocalizedString("数量", comment: ""), value: depthBinding, formatter: numberFormatter)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                    }
                }
            }

            if let onDelete {
                Section {
                    Button(NSLocalizedString("删除条目", comment: "Delete entry"), role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("编辑条目", comment: "Edit entry"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(NSLocalizedString("取消", comment: "Cancel")) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("保存", comment: "Save")) {
                    onSave(draft.toEntry())
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}


struct WatchWorldbookSessionBindingView: View {
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

    @Binding var session: ChatSession?
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
            }

            Section {
                Toggle(
                    NSLocalizedString("绑定世界书时屏蔽记忆与工具", comment: "Worldbook isolation toggle"),
                    isOn: Binding(
                        get: { session?.worldbookContextIsolationEnabled ?? false },
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
            } else if worldbooks.isEmpty {
                Text(NSLocalizedString("暂无可绑定世界书", comment: "No bindable worldbook on watch"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(worldbooks) { book in
                    Button {
                        toggle(book.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.name)
                                    .etFont(.footnote)
                                Text(String(format: NSLocalizedString("%d 条", comment: "Entry count short"), book.entries.count))
                                    .etFont(.caption2)
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
        .navigationTitle(NSLocalizedString("会话绑定", comment: "Session binding title"))
        .onAppear(perform: load)
    }

    func load() {
        worldbooks = ChatService.shared.loadWorldbooks().sorted { $0.updatedAt > $1.updatedAt }
        selected = Set(session?.lorebookIDs ?? [])
    }

    func toggle(_ id: UUID) {
        guard var current = session else { return }
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        current.lorebookIDs = selected.sorted(by: { $0.uuidString < $1.uuidString })
        persistSessionSettings(current)
    }

    func updateIsolationMode(_ isEnabled: Bool) {
        guard var current = session else { return }
        current.worldbookContextIsolationEnabled = isEnabled
        persistSessionSettings(current)
    }

    func persistSessionSettings(_ current: ChatSession) {
        session = current
        ChatService.shared.updateWorldbookSessionSettings(
            sessionID: current.id,
            worldbookIDs: current.lorebookIDs,
            worldbookContextIsolationEnabled: current.worldbookContextIsolationEnabled
        )
    }
}


func worldbookPositionLabel(_ position: WorldbookPosition) -> String {
    switch position {
    case .before:
        return NSLocalizedString("系统前置", comment: "Worldbook position before")
    case .after:
        return NSLocalizedString("系统后置", comment: "Worldbook position after")
    case .anTop:
        return NSLocalizedString("AN 顶部", comment: "Worldbook position anTop")
    case .anBottom:
        return NSLocalizedString("AN 底部", comment: "Worldbook position anBottom")
    case .atDepth:
        return NSLocalizedString("按深度插入", comment: "Worldbook position atDepth")
    case .emTop:
        return NSLocalizedString("消息顶部", comment: "Worldbook position emTop")
    case .emBottom:
        return NSLocalizedString("消息底部", comment: "Worldbook position emBottom")
    case .outlet:
        return NSLocalizedString("Outlet", comment: "Worldbook position outlet")
    @unknown default:
        return NSLocalizedString("系统后置", comment: "Worldbook position fallback")
    }
}


func parseKeywordList(_ raw: String) -> [String] {
    let normalized = raw
        .normalizedPlainQuotes()
        .replacingOccurrences(of: "，", with: ",")
    let components = normalized.components(separatedBy: CharacterSet(charactersIn: ",\n"))
    var seen = Set<String>()
    var result: [String] = []

    for component in components {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        if seen.contains(key) { continue }
        seen.insert(key)
        result.append(trimmed)
    }

    return result
}

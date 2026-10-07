import ETOSCore
import SwiftUI

struct MacWorldbookEntryEditor: View {
    @ObservedObject var model: MacWorldbookModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let book: Worldbook
    @State private var draft: MacWorldbookEntryDraft
    @State private var isSaving = false
    @State private var error: String?

    init(model: MacWorldbookModel, book: Worldbook, draft: MacWorldbookEntryDraft) {
        self.model = model
        self.book = book
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("基础", comment: "")) {
                    TextField(NSLocalizedString("注释", comment: ""), text: $draft.entry.comment)
                    TextEditor(text: $draft.entry.content).frame(minHeight: 140).accessibilityLabel(NSLocalizedString("内容", comment: ""))
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $draft.entry.isEnabled)
                }
                Section(NSLocalizedString("关键词", comment: "")) {
                    TextField(NSLocalizedString("主关键词", comment: ""), text: $draft.keysText, axis: .vertical).lineLimit(2...6)
                    TextField(NSLocalizedString("次级关键词", comment: ""), text: $draft.secondaryKeysText, axis: .vertical).lineLimit(2...6)
                    Toggle(NSLocalizedString("启用次级关键词", comment: ""), isOn: $draft.secondaryKeysEnabled)
                    if draft.secondaryKeysEnabled {
                        Picker(NSLocalizedString("次级逻辑", comment: ""), selection: $draft.entry.selectiveLogic) {
                            ForEach(WorldbookSelectiveLogic.allCases, id: \.self) { Text($0.macLabel).tag($0) }
                        }
                    }
                }
                Section(NSLocalizedString("匹配与触发", comment: "")) {
                    Toggle(NSLocalizedString("常驻激活", comment: ""), isOn: $draft.entry.constant)
                    Toggle(NSLocalizedString("正则匹配", comment: ""), isOn: $draft.entry.useRegex)
                    Toggle(NSLocalizedString("区分大小写", comment: ""), isOn: $draft.entry.caseSensitive)
                    Toggle(NSLocalizedString("整词匹配", comment: ""), isOn: $draft.entry.matchWholeWords)
                    Toggle(NSLocalizedString("启用概率", comment: ""), isOn: $draft.entry.useProbability)
                    if draft.entry.useProbability {
                        TextField(NSLocalizedString("触发概率", comment: ""), value: $draft.entry.probability, format: .number)
                    }
                    TextField(NSLocalizedString("优先级", comment: ""), value: $draft.entry.order, format: .number)
                }
                Section(NSLocalizedString("插入方式", comment: "")) {
                    Picker(NSLocalizedString("位置", comment: ""), selection: $draft.entry.position) {
                        ForEach(WorldbookPosition.allCases, id: \.self) { Text($0.macLabel).tag($0) }
                    }
                    Picker(NSLocalizedString("注入角色", comment: ""), selection: $draft.entry.role) {
                        ForEach(WorldbookEntryRole.allCases, id: \.self) { Text($0.macLabel).tag($0) }
                    }
                    if draft.entry.position == .atDepth {
                        TextField(NSLocalizedString("注入深度", comment: ""), value: number(\.depth, default: 0), format: .number)
                    }
                    if draft.entry.position == .outlet { TextField(NSLocalizedString("Outlet 名称", comment: ""), text: text(\.outletName)) }
                }
                Section(NSLocalizedString("扫描与分组", comment: "")) {
                    Toggle(NSLocalizedString("覆盖扫描深度", comment: ""), isOn: enabled(\.scanDepth, default: 4))
                    if draft.entry.scanDepth != nil { TextField(NSLocalizedString("扫描深度", comment: ""), value: number(\.scanDepth, default: 4), format: .number) }
                    TextField(NSLocalizedString("分组名", comment: ""), text: text(\.group))
                    Toggle(NSLocalizedString("组覆盖", comment: ""), isOn: $draft.entry.groupOverride)
                    Toggle(NSLocalizedString("组评分", comment: ""), isOn: $draft.entry.useGroupScoring)
                    TextField(NSLocalizedString("组权重", comment: ""), value: $draft.entry.groupWeight, format: .number)
                }
                Section(NSLocalizedString("定时效果", comment: "")) {
                    Toggle(NSLocalizedString("Sticky", comment: ""), isOn: enabled(\.sticky, default: 1))
                    if draft.entry.sticky != nil { TextField(NSLocalizedString("Sticky 回合", comment: ""), value: number(\.sticky, default: 1), format: .number) }
                    Toggle(NSLocalizedString("Cooldown", comment: ""), isOn: enabled(\.cooldown, default: 1))
                    if draft.entry.cooldown != nil { TextField(NSLocalizedString("Cooldown 回合", comment: ""), value: number(\.cooldown, default: 1), format: .number) }
                    Toggle(NSLocalizedString("Delay", comment: ""), isOn: enabled(\.delay, default: 1))
                    if draft.entry.delay != nil { TextField(NSLocalizedString("Delay 回合", comment: ""), value: number(\.delay, default: 1), format: .number) }
                }
                Section(NSLocalizedString("递归控制", comment: "")) {
                    Toggle(NSLocalizedString("排除递归缓冲", comment: ""), isOn: $draft.entry.excludeRecursion)
                    Toggle(NSLocalizedString("阻止递归触发", comment: ""), isOn: $draft.entry.preventRecursion)
                    Toggle(NSLocalizedString("仅递归后触发", comment: ""), isOn: $draft.entry.delayUntilRecursion)
                }
                Section {
                    MacSettingsIntroCard(id: "worldbook-entry", title: NSLocalizedString("世界书", comment: ""),
                                         details: NSLocalizedString("Mac 世界书使用说明", comment: ""), documentID: "worldbooks")
                } footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSaving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("编辑条目", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(draft.entry.content.isEmpty || isSaving || model.isWorking || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-worldbook-entry-\(book.id)-\(draft.id)-\(draft.entry.position.rawValue)"),
                title: NSLocalizedString("编辑条目", comment: ""), documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                settings: isSaving || workspace.isRestoringData ? [
                    .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })
                ] : guideSettings
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving)
        .frame(minWidth: 560, minHeight: 580)
    }

    private var guideSettings: [GuidePageSetting] {
        var settings: [GuidePageSetting] = [
            .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) }),
            .string("comment", label: NSLocalizedString("注释", comment: ""), get: { draft.entry.comment }, set: { draft.entry.comment = $0 }),
            .string("content", label: NSLocalizedString("内容", comment: ""), allowsEmpty: false, get: { draft.entry.content }, set: { draft.entry.content = $0 }),
            .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { draft.entry.isEnabled }, set: { draft.entry.isEnabled = $0 }),
            .string("keys", label: NSLocalizedString("主关键词", comment: ""), get: { draft.keysText }, set: { draft.keysText = $0 }),
            .string("secondary_keys", label: NSLocalizedString("次级关键词", comment: ""), get: { draft.secondaryKeysText }, set: { draft.secondaryKeysText = $0 }),
            .bool("secondary_enabled", label: NSLocalizedString("启用次级关键词", comment: ""), get: { draft.secondaryKeysEnabled }, set: { draft.secondaryKeysEnabled = $0 }),
            .bool("constant", label: NSLocalizedString("常驻激活", comment: ""), get: { draft.entry.constant }, set: { draft.entry.constant = $0 }),
            .bool("regex", label: NSLocalizedString("正则匹配", comment: ""), get: { draft.entry.useRegex }, set: { draft.entry.useRegex = $0 }),
            .bool("case_sensitive", label: NSLocalizedString("区分大小写", comment: ""), get: { draft.entry.caseSensitive }, set: { draft.entry.caseSensitive = $0 }),
            .bool("whole_words", label: NSLocalizedString("整词匹配", comment: ""), get: { draft.entry.matchWholeWords }, set: { draft.entry.matchWholeWords = $0 }),
            .bool("use_probability", label: NSLocalizedString("启用概率", comment: ""), get: { draft.entry.useProbability }, set: { draft.entry.useProbability = $0 }),
            .integer("order", label: NSLocalizedString("优先级", comment: ""), range: 0...Int.max, get: { draft.entry.order }, set: { draft.entry.order = $0 }),
            .string("position", label: NSLocalizedString("位置", comment: ""), allowedValues: WorldbookPosition.macGuideValues,
                    get: { draft.entry.position.rawValue }, set: { draft.entry.position = WorldbookPosition(rawValue: $0) ?? .after }),
            .string("role", label: NSLocalizedString("注入角色", comment: ""), allowedValues: WorldbookEntryRole.macGuideValues,
                    get: { draft.entry.role.rawValue }, set: { draft.entry.role = WorldbookEntryRole(rawValue: $0) ?? .user }),
            .bool("scan_override", label: NSLocalizedString("覆盖扫描深度", comment: ""), get: { enabled(\.scanDepth, default: 4).wrappedValue }, set: { enabled(\.scanDepth, default: 4).wrappedValue = $0 }),
            .string("group", label: NSLocalizedString("分组名", comment: ""), get: { text(\.group).wrappedValue }, set: { text(\.group).wrappedValue = $0 }),
            .bool("group_override", label: NSLocalizedString("组覆盖", comment: ""), get: { draft.entry.groupOverride }, set: { draft.entry.groupOverride = $0 }),
            .bool("group_scoring", label: NSLocalizedString("组评分", comment: ""), get: { draft.entry.useGroupScoring }, set: { draft.entry.useGroupScoring = $0 }),
            .double("group_weight", label: NSLocalizedString("组权重", comment: ""), range: 0...10, get: { draft.entry.groupWeight }, set: { draft.entry.groupWeight = $0 }),
            .bool("sticky_enabled", label: NSLocalizedString("Sticky", comment: ""), get: { enabled(\.sticky, default: 1).wrappedValue }, set: { enabled(\.sticky, default: 1).wrappedValue = $0 }),
            .bool("cooldown_enabled", label: NSLocalizedString("Cooldown", comment: ""), get: { enabled(\.cooldown, default: 1).wrappedValue }, set: { enabled(\.cooldown, default: 1).wrappedValue = $0 }),
            .bool("delay_enabled", label: NSLocalizedString("Delay", comment: ""), get: { enabled(\.delay, default: 1).wrappedValue }, set: { enabled(\.delay, default: 1).wrappedValue = $0 }),
            .bool("exclude_recursion", label: NSLocalizedString("排除递归缓冲", comment: ""), get: { draft.entry.excludeRecursion }, set: { draft.entry.excludeRecursion = $0 }),
            .bool("prevent_recursion", label: NSLocalizedString("阻止递归触发", comment: ""), get: { draft.entry.preventRecursion }, set: { draft.entry.preventRecursion = $0 }),
            .bool("delay_recursion", label: NSLocalizedString("仅递归后触发", comment: ""), get: { draft.entry.delayUntilRecursion }, set: { draft.entry.delayUntilRecursion = $0 })
        ]
        if draft.secondaryKeysEnabled {
            settings.append(.string("logic", label: NSLocalizedString("次级逻辑", comment: ""), allowedValues: WorldbookSelectiveLogic.macGuideValues,
                                    get: { draft.entry.selectiveLogic.rawValue }, set: { draft.entry.selectiveLogic = WorldbookSelectiveLogic(rawValue: $0) ?? .andAny }))
        }
        if draft.entry.useProbability {
            settings.append(.double("probability", label: NSLocalizedString("触发概率", comment: ""), range: 1...100,
                                    get: { draft.entry.probability }, set: { draft.entry.probability = $0 }))
        }
        if draft.entry.position == .atDepth {
            settings.append(.integer("depth", label: NSLocalizedString("注入深度", comment: ""), range: 0...Int.max,
                                     get: { number(\.depth, default: 0).wrappedValue }, set: { number(\.depth, default: 0).wrappedValue = $0 }))
        }
        if draft.entry.position == .outlet {
            settings.append(.string("outlet", label: NSLocalizedString("Outlet 名称", comment: ""), get: { text(\.outletName).wrappedValue }, set: { text(\.outletName).wrappedValue = $0 }))
        }
        if draft.entry.scanDepth != nil {
            settings.append(.integer("scan_depth", label: NSLocalizedString("扫描深度", comment: ""), range: 1...Int.max,
                                     get: { number(\.scanDepth, default: 4).wrappedValue }, set: { number(\.scanDepth, default: 4).wrappedValue = $0 }))
        }
        if draft.entry.sticky != nil {
            settings.append(.integer("sticky", label: NSLocalizedString("Sticky 回合", comment: ""), range: 1...Int.max,
                                     get: { number(\.sticky, default: 1).wrappedValue }, set: { number(\.sticky, default: 1).wrappedValue = $0 }))
        }
        if draft.entry.cooldown != nil {
            settings.append(.integer("cooldown", label: NSLocalizedString("Cooldown 回合", comment: ""), range: 1...Int.max,
                                     get: { number(\.cooldown, default: 1).wrappedValue }, set: { number(\.cooldown, default: 1).wrappedValue = $0 }))
        }
        if draft.entry.delay != nil {
            settings.append(.integer("delay", label: NSLocalizedString("Delay 回合", comment: ""), range: 1...Int.max,
                                     get: { number(\.delay, default: 1).wrappedValue }, set: { number(\.delay, default: 1).wrappedValue = $0 }))
        }
        return settings
    }

    private func text(_ keyPath: WritableKeyPath<WorldbookEntry, String?>) -> Binding<String> {
        Binding(get: { draft.entry[keyPath: keyPath] ?? "" }, set: { draft.entry[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func number(_ keyPath: WritableKeyPath<WorldbookEntry, Int?>, default value: Int) -> Binding<Int> {
        Binding(get: { draft.entry[keyPath: keyPath] ?? value }, set: { draft.entry[keyPath: keyPath] = $0 })
    }

    private func enabled(_ keyPath: WritableKeyPath<WorldbookEntry, Int?>, default value: Int) -> Binding<Bool> {
        Binding(get: { draft.entry[keyPath: keyPath] != nil }, set: { draft.entry[keyPath: keyPath] = $0 ? (draft.entry[keyPath: keyPath] ?? value) : nil })
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await model.saveEntry(draft, in: book); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

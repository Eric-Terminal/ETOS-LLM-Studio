// ============================================================================
// WorldbookSettingsView+BookAndEntryEditor.swift
// ============================================================================
// iOS 世界书详情页、条目编辑器与条目草稿转换逻辑。
// ============================================================================

import SwiftUI
import UniformTypeIdentifiers
import Shared

struct WorldbookDetailView: View {
    let worldbookID: UUID

    @State var worldbook: Worldbook?
    @State var nameDraft: String = ""
    @State var descriptionDraft: String = ""
    @State var editingEntryDraft: WorldbookEntryDraft?
    @State var entryToDelete: WorldbookEntry?

    var orderedEntries: [WorldbookEntry] {
        worldbook?.entries ?? []
    }

    var body: some View {
        List {
            if let worldbook {
                Section(NSLocalizedString("基本信息", comment: "Basic info")) {
                    TextField(NSLocalizedString("世界书名称", comment: "Worldbook name field"), text: $nameDraft)
                        .onSubmit {
                            saveName()
                        }
                    TextField(NSLocalizedString("世界书描述", comment: "Worldbook description field"), text: $descriptionDraft, axis: .vertical)
                        .lineLimit(2...6)
                        .onSubmit {
                            saveDescription()
                        }
                    Text(String(format: NSLocalizedString("条目数量：%d", comment: "Entry count"), worldbook.entries.count))
                        .foregroundStyle(.secondary)
                }

                Section(NSLocalizedString("默认设置", comment: "Default settings")) {
                    Stepper(
                        String(format: NSLocalizedString("扫描深度：%d", comment: "Scan depth value"), worldbook.settings.scanDepth),
                        value: settingsScanDepthBinding,
                        in: 1...64
                    )
                    Stepper(
                        String(format: NSLocalizedString("最大递归层级：%d", comment: "Max recursion depth value"), worldbook.settings.maxRecursionDepth),
                        value: settingsMaxRecursionDepthBinding,
                        in: 0...16
                    )
                    Stepper(
                        String(format: NSLocalizedString("最大注入条目：%d", comment: "Max injected entries value"), worldbook.settings.maxInjectedEntries),
                        value: settingsMaxInjectedEntriesBinding,
                        in: 1...256
                    )
                    Stepper(
                        String(format: NSLocalizedString("最大注入字符：%d", comment: "Max injected chars value"), worldbook.settings.maxInjectedCharacters),
                        value: settingsMaxInjectedCharsBinding,
                        in: 256...20000,
                        step: 128
                    )
                    Picker(NSLocalizedString("备用插入位置", comment: "Fallback position"), selection: settingsFallbackPositionBinding) {
                        ForEach(WorldbookPosition.allCases, id: \.self) { position in
                            Text(worldbookPositionLabel(position))
                                .tag(position)
                        }
                    }
                }

                Section(NSLocalizedString("条目", comment: "Entries section")) {
                    Button {
                        editingEntryDraft = .new()
                    } label: {
                        Label(NSLocalizedString("新增条目", comment: "Add entry"), systemImage: "plus")
                    }

                    if orderedEntries.isEmpty {
                        Text(NSLocalizedString("暂无条目", comment: "No entries"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(orderedEntries) { entry in
                            NavigationLink {
                                WorldbookEntryDetailView(
                                    entry: entry,
                                    onSave: { updatedEntry in
                                        upsertEntry(updatedEntry)
                                    }
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.comment.isEmpty ? NSLocalizedString("(无注释)", comment: "No comment") : entry.comment)
                                        .etFont(.subheadline)
                                        .lineLimit(1)

                                    Text(
                                        entry.isEnabled
                                        ? NSLocalizedString("已启用", comment: "Worldbook enabled status")
                                        : NSLocalizedString("已停用", comment: "Worldbook disabled status")
                                    )
                                    .etFont(.caption)
                                    .foregroundStyle(entry.isEnabled ? .green : .secondary)

                                    if let preview = entryPreview(entry) {
                                        Text(preview)
                                            .etFont(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                                    entryToDelete = entry
                                }
                            }
                        }
                        .onMove(perform: moveEntries)
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
        .onAppear(perform: reload)
        .onDisappear(perform: persistPendingBasicInfo)
        .sheet(item: $editingEntryDraft) { draft in
            NavigationStack {
                WorldbookEntryEditView(
                    draft: draft,
                    isNew: true,
                    onSave: { updatedEntry in
                        upsertEntry(updatedEntry)
                    },
                    onDelete: nil
                )
            }
        }
        .alert(
            NSLocalizedString("确认删除条目", comment: "Confirm deleting entry"),
            isPresented: Binding(
                get: { entryToDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        entryToDelete = nil
                    }
                }
            ),
            actions: {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    guard let entryToDelete else { return }
                    deleteEntry(id: entryToDelete.id)
                    self.entryToDelete = nil
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {
                    entryToDelete = nil
                }
            },
            message: {
                Text(NSLocalizedString("删除后不可恢复。", comment: "Delete entry irreversible"))
            }
        )
    }

    func reload() {
        guard var book = ChatService.shared.loadWorldbooks().first(where: { $0.id == worldbookID }) else {
            worldbook = nil
            nameDraft = ""
            descriptionDraft = ""
            return
        }
        book.entries = normalizedEntryOrder(book.entries)
        worldbook = book
        nameDraft = book.name
        descriptionDraft = book.description
    }

    func updateWorldbook(_ mutate: (inout Worldbook) -> Void) {
        guard var worldbook else { return }
        mutate(&worldbook)
        worldbook.updatedAt = Date()
        ChatService.shared.saveWorldbook(worldbook)
        self.worldbook = worldbook
    }

    func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        guard !trimmed.isEmpty else {
            nameDraft = worldbook?.name ?? ""
            return
        }
        updateWorldbook { $0.name = trimmed }
    }

    func saveDescription() {
        let trimmed = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        updateWorldbook { $0.description = trimmed }
    }

    func persistPendingBasicInfo() {
        guard worldbook != nil else { return }
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let trimmedDescription = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        updateWorldbook { book in
            if !trimmedName.isEmpty {
                book.name = trimmedName
            }
            book.description = trimmedDescription
        }
    }

    var settingsScanDepthBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.scanDepth ?? 4 },
            set: { value in
                updateWorldbook { $0.settings.scanDepth = max(1, value) }
            }
        )
    }

    var settingsMaxRecursionDepthBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.maxRecursionDepth ?? 2 },
            set: { value in
                updateWorldbook { $0.settings.maxRecursionDepth = max(0, value) }
            }
        )
    }

    var settingsMaxInjectedEntriesBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.maxInjectedEntries ?? 64 },
            set: { value in
                updateWorldbook { $0.settings.maxInjectedEntries = max(1, value) }
            }
        )
    }

    var settingsMaxInjectedCharsBinding: Binding<Int> {
        Binding(
            get: { worldbook?.settings.maxInjectedCharacters ?? 6000 },
            set: { value in
                updateWorldbook { $0.settings.maxInjectedCharacters = max(256, value) }
            }
        )
    }

    var settingsFallbackPositionBinding: Binding<WorldbookPosition> {
        Binding(
            get: { worldbook?.settings.fallbackPosition ?? .after },
            set: { value in
                updateWorldbook { $0.settings.fallbackPosition = value }
            }
        )
    }

    func upsertEntry(_ entry: WorldbookEntry) {
        updateWorldbook { worldbook in
            if let index = worldbook.entries.firstIndex(where: { $0.id == entry.id }) {
                worldbook.entries[index] = entry
            } else {
                worldbook.entries.append(entry)
            }
            worldbook.entries = normalizedEntryOrder(worldbook.entries)
        }
        reload()
    }

    func deleteEntry(id: UUID) {
        updateWorldbook { worldbook in
            worldbook.entries.removeAll { $0.id == id }
            worldbook.entries = normalizedEntryOrder(worldbook.entries)
        }
        reload()
    }

    func moveEntries(from source: IndexSet, to destination: Int) {
        guard var book = worldbook else { return }
        book.entries.move(fromOffsets: source, toOffset: destination)
        book.entries = normalizedEntryOrder(book.entries)
        book.updatedAt = Date()
        ChatService.shared.saveWorldbook(book)
        worldbook = book
    }

    func normalizedEntryOrder(_ entries: [WorldbookEntry]) -> [WorldbookEntry] {
        var normalized: [WorldbookEntry] = entries
        normalized.sort {
            if $0.order == $1.order {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.order > $1.order
        }
        let total = normalized.count
        for index in normalized.indices {
            normalized[index].order = total - index
        }
        return normalized
    }

    func entryPreview(_ entry: WorldbookEntry) -> String? {
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}


struct WorldbookEntryEditView: View {
    @Environment(\.dismiss) var dismiss

    @State var draft: WorldbookEntryDraft
    @State var showDeleteConfirmation = false

    let isNew: Bool
    let onSave: (WorldbookEntry) -> Void
    let onDelete: (() -> Void)?

    init(
        draft: WorldbookEntryDraft,
        isNew: Bool,
        onSave: @escaping (WorldbookEntry) -> Void,
        onDelete: (() -> Void)?
    ) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var canSave: Bool {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return false }
        if !draft.constant && draft.primaryKeys.isEmpty { return false }
        return true
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("基础", comment: "Base section")) {
                TextField(NSLocalizedString("注释", comment: "Comment field"), text: $draft.comment)
                TextField(NSLocalizedString("内容", comment: "Content field"), text: $draft.content, axis: .vertical)
                    .lineLimit(6...16)
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: $draft.isEnabled)
            }

            Section(NSLocalizedString("关键词", comment: "Keyword section")) {
                TextField(NSLocalizedString("主关键词（逗号/换行分隔）", comment: "Primary keywords field"), text: $draft.keysText, axis: .vertical)
                    .lineLimit(2...6)
                TextField(NSLocalizedString("次级关键词（逗号/换行分隔）", comment: "Secondary keywords field"), text: $draft.secondaryKeysText, axis: .vertical)
                    .lineLimit(2...6)
                Picker(NSLocalizedString("次级逻辑", comment: "Secondary selective logic"), selection: $draft.selectiveLogic) {
                    ForEach(WorldbookSelectiveLogic.allCases, id: \.self) { logic in
                        Text(worldbookSelectiveLogicLabel(logic)).tag(logic)
                    }
                }
            }

            Section(NSLocalizedString("匹配与触发", comment: "Match and trigger section")) {
                Toggle(NSLocalizedString("常驻激活", comment: "Constant active"), isOn: $draft.constant)
                Toggle(NSLocalizedString("正则匹配", comment: "Regex match"), isOn: $draft.useRegex)
                Toggle(NSLocalizedString("区分大小写", comment: "Case sensitive"), isOn: $draft.caseSensitive)
                Toggle(NSLocalizedString("整词匹配", comment: "Whole word match"), isOn: $draft.matchWholeWords)
                Toggle(NSLocalizedString("启用概率", comment: "Enable probability"), isOn: $draft.useProbability)
                if draft.useProbability {
                    HStack {
                        Text(NSLocalizedString("概率", comment: "Probability"))
                        Spacer()
                        Text("\(Int(draft.probability.rounded()))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $draft.probability, in: 1...100, step: 1)
                }
                Stepper(
                    String(format: NSLocalizedString("优先级：%d", comment: "Order value"), draft.order),
                    value: $draft.order,
                    in: 0...1000
                )
            }

            Section(NSLocalizedString("插入方式", comment: "Injection mode section")) {
                Picker(NSLocalizedString("位置", comment: "Position"), selection: $draft.position) {
                    ForEach(WorldbookPosition.allCases, id: \.self) { position in
                        Text(worldbookPositionLabel(position)).tag(position)
                    }
                }

                Picker(NSLocalizedString("注入角色", comment: "Injection role"), selection: $draft.role) {
                    ForEach(WorldbookEntryRole.allCases, id: \.self) { role in
                        Text(worldbookEntryRoleLabel(role)).tag(role)
                    }
                }

                if draft.position == .atDepth {
                    Stepper {
                        Text(String(format: NSLocalizedString("深度：%d", comment: "Depth value"), draft.depth))
                    } onIncrement: {
                        draft.depth += 1
                    } onDecrement: {
                        draft.depth = max(0, draft.depth - 1)
                    }
                }

                if draft.position == .outlet {
                    TextField(NSLocalizedString("Outlet 名称", comment: "Outlet name"), text: $draft.outletName)
                }
            }

            Section(NSLocalizedString("扫描与分组", comment: "Scan and group section")) {
                Toggle(NSLocalizedString("覆盖扫描深度", comment: "Override scan depth"), isOn: $draft.enableEntryScanDepth)
                if draft.enableEntryScanDepth {
                    Stepper(
                        String(format: NSLocalizedString("扫描深度：%d", comment: "Scan depth value"), draft.scanDepth),
                        value: $draft.scanDepth,
                        in: 1...64
                    )
                }

                TextField(NSLocalizedString("分组名", comment: "Group name"), text: $draft.groupName)
                Toggle(NSLocalizedString("组覆盖", comment: "Group override"), isOn: $draft.groupOverride)
                Toggle(NSLocalizedString("组评分", comment: "Use group scoring"), isOn: $draft.useGroupScoring)
                HStack {
                    Text(NSLocalizedString("组权重", comment: "Group weight"))
                    Spacer()
                    Text(String(format: "%.1f", draft.groupWeight))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $draft.groupWeight, in: 0...10, step: 0.5)
            }

            Section(NSLocalizedString("定时效果", comment: "Timed effects section")) {
                Toggle(NSLocalizedString("Sticky", comment: "Sticky toggle"), isOn: $draft.enableSticky)
                if draft.enableSticky {
                    Stepper(
                        String(format: NSLocalizedString("Sticky 回合：%d", comment: "Sticky turns"), draft.sticky),
                        value: $draft.sticky,
                        in: 1...20
                    )
                }

                Toggle(NSLocalizedString("Cooldown", comment: "Cooldown toggle"), isOn: $draft.enableCooldown)
                if draft.enableCooldown {
                    Stepper(
                        String(format: NSLocalizedString("Cooldown 回合：%d", comment: "Cooldown turns"), draft.cooldown),
                        value: $draft.cooldown,
                        in: 1...20
                    )
                }

                Toggle(NSLocalizedString("Delay", comment: "Delay toggle"), isOn: $draft.enableDelay)
                if draft.enableDelay {
                    Stepper(
                        String(format: NSLocalizedString("Delay 回合：%d", comment: "Delay turns"), draft.delay),
                        value: $draft.delay,
                        in: 1...20
                    )
                }
            }

            Section(NSLocalizedString("递归控制", comment: "Recursion section")) {
                Toggle(NSLocalizedString("排除递归缓冲", comment: "Exclude recursion buffer"), isOn: $draft.excludeRecursion)
                Toggle(NSLocalizedString("阻止递归触发", comment: "Prevent recursion"), isOn: $draft.preventRecursion)
                Toggle(NSLocalizedString("仅递归后触发", comment: "Delay until recursion"), isOn: $draft.delayUntilRecursion)
            }

            if onDelete != nil {
                Section {
                    Button(NSLocalizedString("删除条目", comment: "Delete entry"), role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
        .navigationTitle(isNew
                         ? NSLocalizedString("新增条目", comment: "Add entry")
                         : NSLocalizedString("编辑条目", comment: "Edit entry"))
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
        .alert(
            NSLocalizedString("确认删除条目", comment: "Confirm deleting entry"),
            isPresented: $showDeleteConfirmation,
            actions: {
                Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button(NSLocalizedString("取消", comment: "Cancel"), role: .cancel) {}
            },
            message: {
                Text(NSLocalizedString("删除后不可恢复。", comment: "Delete entry irreversible"))
            }
        )
    }
}


struct WorldbookEntryDraft: Identifiable {
    let id: UUID
    let entryID: UUID

    var comment: String
    var content: String
    var keysText: String
    var secondaryKeysText: String

    var selectiveLogic: WorldbookSelectiveLogic
    var isEnabled: Bool
    var constant: Bool

    var position: WorldbookPosition
    var role: WorldbookEntryRole
    var outletName: String
    var order: Int
    var depth: Int

    var enableEntryScanDepth: Bool
    var scanDepth: Int

    var caseSensitive: Bool
    var matchWholeWords: Bool
    var useRegex: Bool

    var useProbability: Bool
    var probability: Double

    var groupName: String
    var groupOverride: Bool
    var groupWeight: Double
    var useGroupScoring: Bool

    var enableSticky: Bool
    var sticky: Int

    var enableCooldown: Bool
    var cooldown: Int

    var enableDelay: Bool
    var delay: Int

    var excludeRecursion: Bool
    var preventRecursion: Bool
    var delayUntilRecursion: Bool

    var primaryKeys: [String] {
        parseKeywordList(keysText)
    }

    var secondaryKeys: [String] {
        parseKeywordList(secondaryKeysText)
    }

    init(entry: WorldbookEntry) {
        self.id = UUID()
        self.entryID = entry.id
        self.comment = entry.comment
        self.content = entry.content
        self.keysText = entry.keys.joined(separator: ", ")
        self.secondaryKeysText = entry.secondaryKeys.joined(separator: ", ")
        self.selectiveLogic = entry.selectiveLogic
        self.isEnabled = entry.isEnabled
        self.constant = entry.constant
        self.position = entry.position
        self.role = entry.role
        self.outletName = entry.outletName ?? ""
        self.order = entry.order
        self.depth = max(0, entry.depth ?? 0)
        self.enableEntryScanDepth = entry.scanDepth != nil
        self.scanDepth = max(1, entry.scanDepth ?? 4)
        self.caseSensitive = entry.caseSensitive
        self.matchWholeWords = entry.matchWholeWords
        self.useRegex = entry.useRegex
        self.useProbability = entry.useProbability
        self.probability = max(1, min(100, entry.probability))
        self.groupName = entry.group ?? ""
        self.groupOverride = entry.groupOverride
        self.groupWeight = entry.groupWeight
        self.useGroupScoring = entry.useGroupScoring
        self.enableSticky = entry.sticky != nil
        self.sticky = max(1, entry.sticky ?? 1)
        self.enableCooldown = entry.cooldown != nil
        self.cooldown = max(1, entry.cooldown ?? 1)
        self.enableDelay = entry.delay != nil
        self.delay = max(1, entry.delay ?? 1)
        self.excludeRecursion = entry.excludeRecursion
        self.preventRecursion = entry.preventRecursion
        self.delayUntilRecursion = entry.delayUntilRecursion
    }

    static func new() -> WorldbookEntryDraft {
        WorldbookEntryDraft(
            id: UUID(),
            entryID: UUID(),
            comment: "",
            content: "",
            keysText: "",
            secondaryKeysText: "",
            selectiveLogic: .andAny,
            isEnabled: true,
            constant: false,
            position: .after,
            role: .user,
            outletName: "",
            order: 100,
            depth: 0,
            enableEntryScanDepth: false,
            scanDepth: 4,
            caseSensitive: false,
            matchWholeWords: false,
            useRegex: false,
            useProbability: false,
            probability: 100,
            groupName: "",
            groupOverride: false,
            groupWeight: 1,
            useGroupScoring: false,
            enableSticky: false,
            sticky: 1,
            enableCooldown: false,
            cooldown: 1,
            enableDelay: false,
            delay: 1,
            excludeRecursion: false,
            preventRecursion: false,
            delayUntilRecursion: false
        )
    }

    func toEntry() -> WorldbookEntry {
        let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedOutletName = outletName.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedGroupName = groupName.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        return WorldbookEntry(
            id: entryID,
            comment: normalizedComment,
            content: normalizedContent,
            keys: primaryKeys,
            secondaryKeys: secondaryKeys,
            selectiveLogic: selectiveLogic,
            isEnabled: isEnabled,
            constant: constant,
            position: position,
            outletName: normalizedOutletName.isEmpty ? nil : normalizedOutletName,
            order: order,
            depth: position == .atDepth ? depth : nil,
            scanDepth: enableEntryScanDepth ? scanDepth : nil,
            caseSensitive: caseSensitive,
            matchWholeWords: matchWholeWords,
            useRegex: useRegex,
            useProbability: useProbability,
            probability: max(1, min(100, probability)),
            group: normalizedGroupName.isEmpty ? nil : normalizedGroupName,
            groupOverride: groupOverride,
            groupWeight: groupWeight,
            useGroupScoring: useGroupScoring,
            role: role,
            sticky: enableSticky ? sticky : nil,
            cooldown: enableCooldown ? cooldown : nil,
            delay: enableDelay ? delay : nil,
            excludeRecursion: excludeRecursion,
            preventRecursion: preventRecursion,
            delayUntilRecursion: delayUntilRecursion
        )
    }

    init(
        id: UUID,
        entryID: UUID,
        comment: String,
        content: String,
        keysText: String,
        secondaryKeysText: String,
        selectiveLogic: WorldbookSelectiveLogic,
        isEnabled: Bool,
        constant: Bool,
        position: WorldbookPosition,
        role: WorldbookEntryRole,
        outletName: String,
        order: Int,
        depth: Int,
        enableEntryScanDepth: Bool,
        scanDepth: Int,
        caseSensitive: Bool,
        matchWholeWords: Bool,
        useRegex: Bool,
        useProbability: Bool,
        probability: Double,
        groupName: String,
        groupOverride: Bool,
        groupWeight: Double,
        useGroupScoring: Bool,
        enableSticky: Bool,
        sticky: Int,
        enableCooldown: Bool,
        cooldown: Int,
        enableDelay: Bool,
        delay: Int,
        excludeRecursion: Bool,
        preventRecursion: Bool,
        delayUntilRecursion: Bool
    ) {
        self.id = id
        self.entryID = entryID
        self.comment = comment
        self.content = content
        self.keysText = keysText
        self.secondaryKeysText = secondaryKeysText
        self.selectiveLogic = selectiveLogic
        self.isEnabled = isEnabled
        self.constant = constant
        self.position = position
        self.role = role
        self.outletName = outletName
        self.order = order
        self.depth = depth
        self.enableEntryScanDepth = enableEntryScanDepth
        self.scanDepth = scanDepth
        self.caseSensitive = caseSensitive
        self.matchWholeWords = matchWholeWords
        self.useRegex = useRegex
        self.useProbability = useProbability
        self.probability = probability
        self.groupName = groupName
        self.groupOverride = groupOverride
        self.groupWeight = groupWeight
        self.useGroupScoring = useGroupScoring
        self.enableSticky = enableSticky
        self.sticky = sticky
        self.enableCooldown = enableCooldown
        self.cooldown = cooldown
        self.enableDelay = enableDelay
        self.delay = delay
        self.excludeRecursion = excludeRecursion
        self.preventRecursion = preventRecursion
        self.delayUntilRecursion = delayUntilRecursion
    }
}

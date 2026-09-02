// ============================================================================
// WorldbookEntryViews.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 iOS 世界书条目的查看与编辑表单。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct WorldbookEntryDetailView: View {
    @State private var entry: WorldbookEntry

    let onSave: (WorldbookEntry) -> Void

    init(entry: WorldbookEntry, onSave: @escaping (WorldbookEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.onSave = onSave
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { entry.isEnabled },
            set: { enabled in
                entry.isEnabled = enabled
                onSave(entry)
            }
        )
    }

    var body: some View {
        List {
            Section(NSLocalizedString("启用状态", comment: "Enable status")) {
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: enabledBinding)
            }

            Section(NSLocalizedString("编辑", comment: "Edit")) {
                NavigationLink {
                    WorldbookEntryEditView(
                        draft: WorldbookEntryDraft(entry: entry),
                        isNew: false,
                        onSave: { updatedEntry in
                            entry = updatedEntry
                            onSave(updatedEntry)
                        },
                        onDelete: nil
                    )
                } label: {
                    Label(NSLocalizedString("编辑条目", comment: "Edit entry"), systemImage: "square.and.pencil")
                }
            }

            Section(NSLocalizedString("内容", comment: "Content field")) {
                if !entry.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.comment)
                        .etFont(.headline)
                }

                if !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.content)
                        .etFont(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !entry.keys.isEmpty {
                    Text(entry.keys.joined(separator: "，"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(worldbookPositionLabel(entry.position))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)

                Text(
                    String(
                        format: NSLocalizedString("角色：%@", comment: "Entry role label"),
                        worldbookEntryRoleLabel(entry.role)
                    )
                )
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("条目", comment: "Entries section"))
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "worldbook-entry-\(entry.id.uuidString.lowercased())"),
            title: String(format: NSLocalizedString("世界书条目：%@", comment: "世界书条目向导标题"), entry.comment.isEmpty ? NSLocalizedString("无注释", comment: "无注释世界书条目") : entry.comment),
            documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks")],
            settings: [
                .readOnly("id", label: NSLocalizedString("条目 ID", comment: "世界书条目向导字段"), value: { .string(entry.id.uuidString) }),
                .readOnly("comment", label: NSLocalizedString("注释", comment: "世界书条目向导字段"), value: { .string(entry.comment) }),
                .readOnly("content_preview", label: NSLocalizedString("内容预览", comment: "世界书条目向导字段"), value: { .string(String(entry.content.prefix(2_000))) }),
                .readOnly("content_character_count", label: NSLocalizedString("内容字符数", comment: "世界书条目向导字段"), value: { .int(entry.content.count) }),
                .readOnly("keys", label: NSLocalizedString("关键词", comment: "世界书条目向导字段"), value: { .array(entry.keys.map(JSONValue.string)) }),
                .readOnly("position", label: NSLocalizedString("插入位置", comment: "世界书条目向导字段"), value: { .string(entry.position.rawValue) }),
                .readOnly("role", label: NSLocalizedString("注入角色", comment: "世界书条目向导字段"), value: { .string(entry.role.rawValue) }),
                .bool("enabled", label: NSLocalizedString("启用", comment: "世界书条目向导字段"), get: { entry.isEnabled }, set: { enabledBinding.wrappedValue = $0 })
            ]
        )
    }
}

struct WorldbookEntryEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: WorldbookEntryDraft
    @State private var showDeleteConfirmation = false
    @State private var showUnsavedChangesAlert = false

    let isNew: Bool
    let onSave: (WorldbookEntry) -> Void
    let onDelete: (() -> Void)?
    private let savedEntry: WorldbookEntry

    init(
        draft: WorldbookEntryDraft,
        isNew: Bool,
        onSave: @escaping (WorldbookEntry) -> Void,
        onDelete: (() -> Void)?
    ) {
        _draft = State(initialValue: draft)
        savedEntry = draft.toEntry()
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var canSave: Bool {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return false }
        if !draft.constant && draft.primaryKeys.isEmpty { return false }
        return true
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var decimalFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var orderBinding: Binding<Int> {
        Binding(
            get: { draft.order },
            set: { draft.order = min(1000, max(0, $0)) }
        )
    }

    private var depthBinding: Binding<Int> {
        Binding(
            get: { draft.depth },
            set: { draft.depth = max(0, $0) }
        )
    }

    private var scanDepthBinding: Binding<Int> {
        Binding(
            get: { draft.scanDepth },
            set: { draft.scanDepth = max(1, $0) }
        )
    }

    private var stickyBinding: Binding<Int> {
        Binding(
            get: { draft.sticky },
            set: { draft.sticky = max(1, $0) }
        )
    }

    private var cooldownBinding: Binding<Int> {
        Binding(
            get: { draft.cooldown },
            set: { draft.cooldown = max(1, $0) }
        )
    }

    private var delayBinding: Binding<Int> {
        Binding(
            get: { draft.delay },
            set: { draft.delay = max(1, $0) }
        )
    }

    private var probabilityBinding: Binding<Double> {
        Binding(
            get: { draft.probability },
            set: { draft.probability = max(1, min(100, $0)) }
        )
    }

    private var groupWeightBinding: Binding<Double> {
        Binding(
            get: { draft.groupWeight },
            set: { draft.groupWeight = max(0, min(10, $0)) }
        )
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("基础", comment: "Base section")) {
                TextField(NSLocalizedString("注释", comment: "Comment field"), text: $draft.comment)
                FullscreenMultilineTextInput(
                    identity: "worldbook-entry-content-\(draft.entryID.uuidString)",
                    placeholder: NSLocalizedString("内容", comment: "Content field"),
                    fullScreenTitle: NSLocalizedString("内容", comment: "Content field"),
                    text: $draft.content,
                    lineLimit: 6...16,
                    isEnabled: true,
                    onDebouncedSave: { _ in
                        saveDraftIfEditingExistingEntry()
                    }
                )
                Toggle(NSLocalizedString("启用", comment: "Enable"), isOn: $draft.isEnabled)
            }

            Section(NSLocalizedString("关键词", comment: "Keyword section")) {
                FullscreenMultilineTextInput(
                    identity: "worldbook-entry-primary-keys-\(draft.entryID.uuidString)",
                    placeholder: NSLocalizedString("主关键词（逗号/换行分隔）", comment: "Primary keywords field"),
                    fullScreenTitle: NSLocalizedString("主关键词（逗号/换行分隔）", comment: "Primary keywords field"),
                    text: $draft.keysText,
                    lineLimit: 2...6,
                    isEnabled: true,
                    onDebouncedSave: { _ in
                        saveDraftIfEditingExistingEntry()
                    }
                )
                FullscreenMultilineTextInput(
                    identity: "worldbook-entry-secondary-keys-\(draft.entryID.uuidString)",
                    placeholder: NSLocalizedString("次级关键词（逗号/换行分隔）", comment: "Secondary keywords field"),
                    fullScreenTitle: NSLocalizedString("次级关键词（逗号/换行分隔）", comment: "Secondary keywords field"),
                    text: $draft.secondaryKeysText,
                    lineLimit: 2...6,
                    isEnabled: true,
                    onDebouncedSave: { _ in
                        saveDraftIfEditingExistingEntry()
                    }
                )
                Toggle(NSLocalizedString("启用次级关键词", comment: "Enable secondary keywords"), isOn: $draft.secondaryKeysEnabled)
                if draft.secondaryKeysEnabled {
                    Picker(NSLocalizedString("次级逻辑", comment: "Secondary selective logic"), selection: $draft.selectiveLogic) {
                        ForEach(WorldbookSelectiveLogic.allCases, id: \.self) { logic in
                            Text(worldbookSelectiveLogicLabel(logic)).tag(logic)
                        }
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
                    LabeledContent(NSLocalizedString("概率", comment: "Probability")) {
                        TextField(NSLocalizedString("百分比", comment: "Percent placeholder"), value: probabilityBinding, formatter: decimalFormatter)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                    }
                }
                LabeledContent(NSLocalizedString("优先级", comment: "Order label")) {
                    TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: orderBinding, formatter: numberFormatter)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 88)
                }
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
                    LabeledContent(NSLocalizedString("深度", comment: "Depth label")) {
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: depthBinding, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                    }
                }

                if draft.position == .outlet {
                    TextField(NSLocalizedString("Outlet 名称", comment: "Outlet name"), text: $draft.outletName)
                }
            }

            Section(NSLocalizedString("扫描与分组", comment: "Scan and group section")) {
                Toggle(NSLocalizedString("覆盖扫描深度", comment: "Override scan depth"), isOn: $draft.enableEntryScanDepth)
                if draft.enableEntryScanDepth {
                    LabeledContent(NSLocalizedString("扫描深度", comment: "Scan depth label")) {
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: scanDepthBinding, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                    }
                }

                TextField(NSLocalizedString("分组名", comment: "Group name"), text: $draft.groupName)
                Toggle(NSLocalizedString("组覆盖", comment: "Group override"), isOn: $draft.groupOverride)
                Toggle(NSLocalizedString("组评分", comment: "Use group scoring"), isOn: $draft.useGroupScoring)
                LabeledContent(NSLocalizedString("组权重", comment: "Group weight")) {
                    TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: groupWeightBinding, formatter: decimalFormatter)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 88)
                }
            }

            Section(NSLocalizedString("定时效果", comment: "Timed effects section")) {
                Toggle(NSLocalizedString("Sticky", comment: "Sticky toggle"), isOn: $draft.enableSticky)
                if draft.enableSticky {
                    LabeledContent(NSLocalizedString("Sticky 回合", comment: "Sticky turns label")) {
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: stickyBinding, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                    }
                }

                Toggle(NSLocalizedString("Cooldown", comment: "Cooldown toggle"), isOn: $draft.enableCooldown)
                if draft.enableCooldown {
                    LabeledContent(NSLocalizedString("Cooldown 回合", comment: "Cooldown turns label")) {
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: cooldownBinding, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                    }
                }

                Toggle(NSLocalizedString("Delay", comment: "Delay toggle"), isOn: $draft.enableDelay)
                if draft.enableDelay {
                    LabeledContent(NSLocalizedString("Delay 回合", comment: "Delay turns label")) {
                        TextField(NSLocalizedString("数量", comment: "Number placeholder"), value: delayBinding, formatter: numberFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                    }
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
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(NSLocalizedString("取消", comment: "Cancel")) {
                    requestDismiss()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(NSLocalizedString("保存", comment: "Save")) {
                    saveAndDismiss()
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
        .alert(NSLocalizedString("未保存更改", comment: "Unsaved changes alert title"), isPresented: $showUnsavedChangesAlert) {
            if canSave {
                Button(NSLocalizedString("保存并离开", comment: "Save changes and leave")) {
                    saveAndDismiss()
                }
            }
            Button(NSLocalizedString("放弃更改", comment: "Discard changes"), role: .destructive) {
                dismiss()
            }
            Button(NSLocalizedString("继续编辑", comment: "Continue editing"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("要保存当前编辑内容，还是放弃更改并离开？", comment: "Unsaved generic editor alert message"))
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "worldbook-entry-editor-\(draft.entryID.uuidString.lowercased())"),
            title: isNew
                ? NSLocalizedString("新增世界书条目", comment: "世界书条目编辑器向导标题")
                : NSLocalizedString("编辑世界书条目", comment: "世界书条目编辑器向导标题"),
            documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks")],
            settings: editorGuideSettings
        )
    }

    private var editorGuideSettings: [GuidePageSetting] {
        [
            .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: "世界书条目编辑器向导字段"), value: { .bool(true) }),
            .string("comment", label: NSLocalizedString("注释", comment: "世界书条目编辑器向导字段"), get: { draft.comment }, set: { draft.comment = $0 }),
            .string("content", label: NSLocalizedString("内容", comment: "世界书条目编辑器向导字段"), allowsEmpty: false, get: { draft.content }, set: { draft.content = $0 }),
            .string("primary_keys", label: NSLocalizedString("主关键词（逗号或换行分隔）", comment: "世界书条目编辑器向导字段"), get: { draft.keysText }, set: { draft.keysText = $0 }),
            .string("secondary_keys", label: NSLocalizedString("次级关键词（逗号或换行分隔）", comment: "世界书条目编辑器向导字段"), get: { draft.secondaryKeysText }, set: { draft.secondaryKeysText = $0 }),
            .bool("secondary_keys_enabled", label: NSLocalizedString("启用次级关键词", comment: "世界书条目编辑器向导字段"), get: { draft.secondaryKeysEnabled }, set: { draft.secondaryKeysEnabled = $0 }),
            .string("selective_logic", label: NSLocalizedString("次级关键词逻辑", comment: "世界书条目编辑器向导字段"), allowedValues: WorldbookSelectiveLogic.allCases.map(\.rawValue), allowsEmpty: false, get: { draft.selectiveLogic.rawValue }, set: { rawValue in
                if let logic = WorldbookSelectiveLogic(rawValue: rawValue) { draft.selectiveLogic = logic }
            }),
            .bool("enabled", label: NSLocalizedString("启用", comment: "世界书条目编辑器向导字段"), get: { draft.isEnabled }, set: { draft.isEnabled = $0 }),
            .bool("constant", label: NSLocalizedString("常驻激活", comment: "世界书条目编辑器向导字段"), get: { draft.constant }, set: { draft.constant = $0 }),
            .bool("use_regex", label: NSLocalizedString("正则匹配", comment: "世界书条目编辑器向导字段"), get: { draft.useRegex }, set: { draft.useRegex = $0 }),
            .bool("case_sensitive", label: NSLocalizedString("区分大小写", comment: "世界书条目编辑器向导字段"), get: { draft.caseSensitive }, set: { draft.caseSensitive = $0 }),
            .bool("match_whole_words", label: NSLocalizedString("整词匹配", comment: "世界书条目编辑器向导字段"), get: { draft.matchWholeWords }, set: { draft.matchWholeWords = $0 }),
            .bool("use_probability", label: NSLocalizedString("启用概率", comment: "世界书条目编辑器向导字段"), get: { draft.useProbability }, set: { draft.useProbability = $0 }),
            .double("probability", label: NSLocalizedString("触发概率", comment: "世界书条目编辑器向导字段"), range: 1...100, get: { draft.probability }, set: { probabilityBinding.wrappedValue = $0 }),
            .integer("order", label: NSLocalizedString("优先级", comment: "世界书条目编辑器向导字段"), range: 0...1_000, get: { draft.order }, set: { orderBinding.wrappedValue = $0 }),
            .string("position", label: NSLocalizedString("插入位置", comment: "世界书条目编辑器向导字段"), allowedValues: WorldbookPosition.allCases.map(\.rawValue), allowsEmpty: false, get: { draft.position.rawValue }, set: { rawValue in
                if let position = WorldbookPosition(rawValue: rawValue) { draft.position = position }
            }),
            .string("role", label: NSLocalizedString("注入角色", comment: "世界书条目编辑器向导字段"), allowedValues: WorldbookEntryRole.allCases.map(\.rawValue), allowsEmpty: false, get: { draft.role.rawValue }, set: { rawValue in
                if let role = WorldbookEntryRole(rawValue: rawValue) { draft.role = role }
            }),
            .integer("depth", label: NSLocalizedString("注入深度", comment: "世界书条目编辑器向导字段"), range: 0...Int.max, get: { draft.depth }, set: { depthBinding.wrappedValue = $0 }),
            .string("outlet_name", label: NSLocalizedString("Outlet 名称", comment: "世界书条目编辑器向导字段"), get: { draft.outletName }, set: { draft.outletName = $0 }),
            .bool("override_scan_depth", label: NSLocalizedString("覆盖扫描深度", comment: "世界书条目编辑器向导字段"), get: { draft.enableEntryScanDepth }, set: { draft.enableEntryScanDepth = $0 }),
            .integer("scan_depth", label: NSLocalizedString("扫描深度", comment: "世界书条目编辑器向导字段"), range: 1...Int.max, get: { draft.scanDepth }, set: { scanDepthBinding.wrappedValue = $0 }),
            .string("group_name", label: NSLocalizedString("分组名", comment: "世界书条目编辑器向导字段"), get: { draft.groupName }, set: { draft.groupName = $0 }),
            .bool("group_override", label: NSLocalizedString("组覆盖", comment: "世界书条目编辑器向导字段"), get: { draft.groupOverride }, set: { draft.groupOverride = $0 }),
            .bool("use_group_scoring", label: NSLocalizedString("组评分", comment: "世界书条目编辑器向导字段"), get: { draft.useGroupScoring }, set: { draft.useGroupScoring = $0 }),
            .double("group_weight", label: NSLocalizedString("组权重", comment: "世界书条目编辑器向导字段"), range: 0...10, get: { draft.groupWeight }, set: { groupWeightBinding.wrappedValue = $0 }),
            .bool("enable_sticky", label: NSLocalizedString("启用 Sticky", comment: "世界书条目编辑器向导字段"), get: { draft.enableSticky }, set: { draft.enableSticky = $0 }),
            .integer("sticky_turns", label: NSLocalizedString("Sticky 回合", comment: "世界书条目编辑器向导字段"), range: 1...Int.max, get: { draft.sticky }, set: { stickyBinding.wrappedValue = $0 }),
            .bool("enable_cooldown", label: NSLocalizedString("启用 Cooldown", comment: "世界书条目编辑器向导字段"), get: { draft.enableCooldown }, set: { draft.enableCooldown = $0 }),
            .integer("cooldown_turns", label: NSLocalizedString("Cooldown 回合", comment: "世界书条目编辑器向导字段"), range: 1...Int.max, get: { draft.cooldown }, set: { cooldownBinding.wrappedValue = $0 }),
            .bool("enable_delay", label: NSLocalizedString("启用 Delay", comment: "世界书条目编辑器向导字段"), get: { draft.enableDelay }, set: { draft.enableDelay = $0 }),
            .integer("delay_turns", label: NSLocalizedString("Delay 回合", comment: "世界书条目编辑器向导字段"), range: 1...Int.max, get: { draft.delay }, set: { delayBinding.wrappedValue = $0 }),
            .bool("exclude_recursion", label: NSLocalizedString("排除递归缓冲", comment: "世界书条目编辑器向导字段"), get: { draft.excludeRecursion }, set: { draft.excludeRecursion = $0 }),
            .bool("prevent_recursion", label: NSLocalizedString("阻止递归触发", comment: "世界书条目编辑器向导字段"), get: { draft.preventRecursion }, set: { draft.preventRecursion = $0 }),
            .bool("delay_until_recursion", label: NSLocalizedString("仅递归后触发", comment: "世界书条目编辑器向导字段"), get: { draft.delayUntilRecursion }, set: { draft.delayUntilRecursion = $0 })
        ]
    }

    private var hasUnsavedChanges: Bool {
        draft.toEntry() != savedEntry
    }

    private func requestDismiss() {
        if hasUnsavedChanges {
            showUnsavedChangesAlert = true
        } else {
            dismiss()
        }
    }

    private func saveAndDismiss() {
        guard canSave else { return }
        onSave(draft.toEntry())
        dismiss()
    }

    private func saveDraftIfEditingExistingEntry() {
        guard !isNew, canSave else { return }
        onSave(draft.toEntry())
    }
}

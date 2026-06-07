// ============================================================================
// WorldbookEntryViews.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 世界书条目详情、编辑表单与草稿转换辅助。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct WatchWorldbookEntryDetailView: View {
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
                    WatchWorldbookEntryEditView(
                        draft: WatchWorldbookEntryDraft(entry: entry),
                        onSave: { updatedEntry in
                            entry = updatedEntry
                            onSave(updatedEntry)
                        }
                    )
                } label: {
                    Label(NSLocalizedString("编辑条目", comment: "Edit entry"), systemImage: "square.and.pencil")
                }
            }

            Section(NSLocalizedString("内容", comment: "Content field")) {
                if !entry.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.comment)
                        .etFont(.footnote)
                }

                if !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(entry.content)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !entry.keys.isEmpty {
                    Text(entry.keys.joined(separator: "，"))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(worldbookPositionLabel(entry.position))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)

                Text(
                    String(
                        format: NSLocalizedString("角色：%@", comment: "Entry role label"),
                        worldbookEntryRoleLabel(entry.role)
                    )
                )
                .etFont(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("条目", comment: "Entries section"))
    }
}

struct WatchWorldbookEntryEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: WatchWorldbookEntryDraft

    let onSave: (WorldbookEntry) -> Void
    let onDelete: (() -> Void)?

    init(draft: WatchWorldbookEntryDraft, onSave: @escaping (WorldbookEntry) -> Void, onDelete: (() -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var canSave: Bool {
        let content = draft.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty { return false }
        if !draft.constant && parseKeywordList(draft.keysText).isEmpty { return false }
        return true
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var orderBinding: Binding<Int> {
        Binding(
            get: { draft.order },
            set: { newValue in
                draft.order = min(1000, max(0, newValue))
            }
        )
    }

    private var depthBinding: Binding<Int> {
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

struct WatchWorldbookEntryDraft: Identifiable {
    let id: UUID
    let entryID: UUID

    var comment: String
    var content: String
    var keysText: String
    var secondaryKeys: [String]
    var selectiveLogic: WorldbookSelectiveLogic
    var isEnabled: Bool
    var constant: Bool
    var useRegex: Bool
    var caseSensitive: Bool
    var matchWholeWords: Bool
    var position: WorldbookPosition
    var role: WorldbookEntryRole
    var outletName: String?
    var depth: Int
    var order: Int
    var scanDepth: Int?
    var useProbability: Bool
    var probability: Double
    var group: String?
    var groupOverride: Bool
    var groupWeight: Double
    var useGroupScoring: Bool
    var sticky: Int?
    var cooldown: Int?
    var delay: Int?
    var excludeRecursion: Bool
    var preventRecursion: Bool
    var delayUntilRecursion: Bool
    private var metadata: [String: JSONValue]

    init(entry: WorldbookEntry) {
        self.id = UUID()
        self.entryID = entry.id
        self.comment = entry.comment
        self.content = entry.content
        self.keysText = entry.keys.joined(separator: ", ")
        self.secondaryKeys = entry.secondaryKeys
        self.selectiveLogic = entry.selectiveLogic
        self.isEnabled = entry.isEnabled
        self.constant = entry.constant
        self.useRegex = entry.useRegex
        self.caseSensitive = entry.caseSensitive
        self.matchWholeWords = entry.matchWholeWords
        self.position = entry.position
        self.role = entry.role
        self.outletName = entry.outletName
        self.depth = max(0, entry.depth ?? 0)
        self.order = entry.order
        self.scanDepth = entry.scanDepth
        self.useProbability = entry.useProbability
        self.probability = entry.probability
        self.group = entry.group
        self.groupOverride = entry.groupOverride
        self.groupWeight = entry.groupWeight
        self.useGroupScoring = entry.useGroupScoring
        self.sticky = entry.sticky
        self.cooldown = entry.cooldown
        self.delay = entry.delay
        self.excludeRecursion = entry.excludeRecursion
        self.preventRecursion = entry.preventRecursion
        self.delayUntilRecursion = entry.delayUntilRecursion
        self.metadata = entry.metadata
    }

    static func new() -> WatchWorldbookEntryDraft {
        WatchWorldbookEntryDraft(
            id: UUID(),
            entryID: UUID(),
            comment: "",
            content: "",
            keysText: "",
            secondaryKeys: [],
            selectiveLogic: .andAny,
            isEnabled: true,
            constant: false,
            useRegex: false,
            caseSensitive: false,
            matchWholeWords: false,
            position: .after,
            role: .user,
            outletName: nil,
            depth: 0,
            order: 100,
            scanDepth: nil,
            useProbability: false,
            probability: 100,
            group: nil,
            groupOverride: false,
            groupWeight: 1,
            useGroupScoring: false,
            sticky: nil,
            cooldown: nil,
            delay: nil,
            excludeRecursion: false,
            preventRecursion: false,
            delayUntilRecursion: false,
            metadata: [:]
        )
    }

    private init(
        id: UUID,
        entryID: UUID,
        comment: String,
        content: String,
        keysText: String,
        secondaryKeys: [String],
        selectiveLogic: WorldbookSelectiveLogic,
        isEnabled: Bool,
        constant: Bool,
        useRegex: Bool,
        caseSensitive: Bool,
        matchWholeWords: Bool,
        position: WorldbookPosition,
        role: WorldbookEntryRole,
        outletName: String?,
        depth: Int,
        order: Int,
        scanDepth: Int?,
        useProbability: Bool,
        probability: Double,
        group: String?,
        groupOverride: Bool,
        groupWeight: Double,
        useGroupScoring: Bool,
        sticky: Int?,
        cooldown: Int?,
        delay: Int?,
        excludeRecursion: Bool,
        preventRecursion: Bool,
        delayUntilRecursion: Bool,
        metadata: [String: JSONValue]
    ) {
        self.id = id
        self.entryID = entryID
        self.comment = comment
        self.content = content
        self.keysText = keysText
        self.secondaryKeys = secondaryKeys
        self.selectiveLogic = selectiveLogic
        self.isEnabled = isEnabled
        self.constant = constant
        self.useRegex = useRegex
        self.caseSensitive = caseSensitive
        self.matchWholeWords = matchWholeWords
        self.position = position
        self.role = role
        self.outletName = outletName
        self.depth = depth
        self.order = order
        self.scanDepth = scanDepth
        self.useProbability = useProbability
        self.probability = probability
        self.group = group
        self.groupOverride = groupOverride
        self.groupWeight = groupWeight
        self.useGroupScoring = useGroupScoring
        self.sticky = sticky
        self.cooldown = cooldown
        self.delay = delay
        self.excludeRecursion = excludeRecursion
        self.preventRecursion = preventRecursion
        self.delayUntilRecursion = delayUntilRecursion
        self.metadata = metadata
    }

    func toEntry() -> WorldbookEntry {
        let normalizedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines).normalizedPlainQuotes()
        let normalizedKeys = parseKeywordList(keysText.normalizedPlainQuotes())
        return WorldbookEntry(
            id: entryID,
            comment: normalizedComment,
            content: normalizedContent,
            keys: normalizedKeys,
            secondaryKeys: secondaryKeys,
            selectiveLogic: selectiveLogic,
            isEnabled: isEnabled,
            constant: constant,
            position: position,
            outletName: outletName,
            order: order,
            depth: position == .atDepth ? depth : nil,
            scanDepth: scanDepth,
            caseSensitive: caseSensitive,
            matchWholeWords: matchWholeWords,
            useRegex: useRegex,
            useProbability: useProbability,
            probability: probability,
            group: group,
            groupOverride: groupOverride,
            groupWeight: groupWeight,
            useGroupScoring: useGroupScoring,
            role: role,
            sticky: sticky,
            cooldown: cooldown,
            delay: delay,
            excludeRecursion: excludeRecursion,
            preventRecursion: preventRecursion,
            delayUntilRecursion: delayUntilRecursion,
            metadata: metadata
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

func worldbookEntryRoleLabel(_ role: WorldbookEntryRole) -> String {
    switch role {
    case .system:
        return NSLocalizedString("系统", comment: "Worldbook role system")
    case .user:
        return NSLocalizedString("用户", comment: "Worldbook role user")
    case .assistant:
        return NSLocalizedString("助手", comment: "Worldbook role assistant")
    @unknown default:
        return NSLocalizedString("用户", comment: "Worldbook role default")
    }
}

private func parseKeywordList(_ raw: String) -> [String] {
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

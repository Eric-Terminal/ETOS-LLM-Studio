// ============================================================================
// DisplaySettingsTextFontRuleSupport.swift
// ============================================================================
// watchOS 聊天文字局部字体规则管理。
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchChatTextFontRuleRow: View {
    let rule: ChatAppearanceTextFontRule
    let assets: [FontAssetRecord]

    var body: some View {
        VStack(alignment: .leading) {
            Text(ruleSummary)
                .lineLimit(1)
            Text(fontSummary)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(rule.isEnabled ? 1 : 0.4)
        }
    }

    private var ruleSummary: String {
        switch rule.kind {
        case .exactText:
            return rule.exactText.isEmpty
                ? NSLocalizedString("未设置文字", comment: "")
                : rule.exactText
        case .delimitedText:
            guard rule.hasConfiguredMatch else {
                return NSLocalizedString("未设置起止标记", comment: "")
            }
            return "\(rule.startDelimiter)…\(rule.endDelimiter)"
        case .regularExpression:
            return rule.exactText.isEmpty
                ? NSLocalizedString("未设置正则表达式", comment: "")
                : rule.exactText
        }
    }

    private var fontSummary: String {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let selectedAssets = rule.fontAssetIDs.compactMap { assetsByID[$0] }
        guard let first = selectedAssets.first else {
            return NSLocalizedString("未选择字体", comment: "")
        }
        let summary = String(
            format: NSLocalizedString("%@，共 %d 种字体", comment: ""),
            first.displayName,
            selectedAssets.count
        )
        return rule.isEnabled
            ? summary
            : String(format: NSLocalizedString("%@（已停用）", comment: ""), summary)
    }
}

struct WatchChatTextFontRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: ChatAppearanceTextFontRule
    @State private var isRegularExpressionValid = true
    @State private var showAddFontDialog = false

    let assets: [FontAssetRecord]
    let onSave: (ChatAppearanceTextFontRule) -> Void

    init(
        initialRule: ChatAppearanceTextFontRule,
        assets: [FontAssetRecord],
        onSave: @escaping (ChatAppearanceTextFontRule) -> Void
    ) {
        _rule = State(initialValue: initialRule)
        self.assets = assets
        self.onSave = onSave
    }

    var body: some View {
        List {
            Section {
                Toggle(NSLocalizedString("启用规则", comment: ""), isOn: $rule.isEnabled)
            }

            matchSection
            fontPrioritySection
        }
        .navigationTitle(NSLocalizedString("字体规则", comment: ""))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("保存", comment: "")) {
                    onSave(rule)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .task(id: regularExpressionValidationPattern) {
            guard let pattern = regularExpressionValidationPattern else {
                isRegularExpressionValid = true
                return
            }
            let isValid = await ChatAppearanceTextColorMatcher.isValidRegularExpression(pattern)
            guard regularExpressionValidationPattern == pattern else { return }
            isRegularExpressionValid = isValid
        }
        .confirmationDialog(
            NSLocalizedString("添加字体到规则", comment: ""),
            isPresented: $showAddFontDialog,
            titleVisibility: .visible
        ) {
            ForEach(availableAssets) { asset in
                Button(asset.displayName) {
                    rule.fontAssetIDs.append(asset.id)
                }
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        }
    }

    private var matchSection: some View {
        Section {
            Picker(NSLocalizedString("匹配方式", comment: ""), selection: $rule.kind) {
                Text(NSLocalizedString("指定文字", comment: ""))
                    .tag(ChatAppearanceTextRuleKind.exactText)
                Text(NSLocalizedString("起止标记之间", comment: ""))
                    .tag(ChatAppearanceTextRuleKind.delimitedText)
                Text(NSLocalizedString("正则表达式", comment: ""))
                    .tag(ChatAppearanceTextRuleKind.regularExpression)
            }

            switch rule.kind {
            case .exactText:
                TextField(NSLocalizedString("要匹配的文字", comment: ""), text: $rule.exactText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .delimitedText:
                TextField(NSLocalizedString("起始标记", comment: ""), text: $rule.startDelimiter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(NSLocalizedString("结束标记", comment: ""), text: $rule.endDelimiter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle(NSLocalizedString("包含起止标记", comment: ""), isOn: $rule.includesDelimiters)
            case .regularExpression:
                TextField(NSLocalizedString("要匹配的正则表达式", comment: ""), text: $rule.exactText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if rule.kind == .regularExpression, !isRegularExpressionValid {
                Text(NSLocalizedString("正则表达式无效，请检查语法。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(NSLocalizedString("匹配内容", comment: ""))
        } footer: {
            Text(matchDescription)
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var fontPrioritySection: some View {
        Section {
            if selectedAssets.isEmpty {
                Text(NSLocalizedString("当前规则没有字体，不会改变匹配内容。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selectedAssetsBinding, id: \.id, editActions: .move) { $asset in
                    Text(asset.displayName)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                rule.fontAssetIDs.removeAll { $0 == asset.id }
                            } label: {
                                Label(NSLocalizedString("移除", comment: ""), systemImage: "trash")
                            }
                        }
                }
            }

            if availableAssets.isEmpty {
                Text(NSLocalizedString("没有可添加的字体。", comment: ""))
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showAddFontDialog = true
                } label: {
                    Label(NSLocalizedString("添加字体到规则", comment: ""), systemImage: "plus.circle")
                }
            }
        } header: {
            Text(NSLocalizedString("字体优先级", comment: ""))
        } footer: {
            Text(NSLocalizedString("规则内字体从上到下尝试；匹配内容优先使用这里的字体，未命中内容继续使用外层全局字体。", comment: ""))
                .etFont(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedAssets: [FontAssetRecord] {
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return rule.fontAssetIDs.compactMap { assetsByID[$0] }
    }

    private var selectedAssetsBinding: Binding<[FontAssetRecord]> {
        Binding(
            get: { selectedAssets },
            set: { rule.fontAssetIDs = $0.map(\.id) }
        )
    }

    private var availableAssets: [FontAssetRecord] {
        let selectedIDs = Set(rule.fontAssetIDs)
        return assets.filter { !selectedIDs.contains($0.id) }
    }

    private var canSave: Bool {
        rule.hasConfiguredMatch
            && !rule.fontAssetIDs.isEmpty
            && (rule.kind != .regularExpression || isRegularExpressionValid)
    }

    private var matchDescription: String {
        switch rule.kind {
        case .exactText:
            return NSLocalizedString("只修改完全相同的文字片段，不使用正则表达式。", comment: "")
        case .delimitedText:
            return NSLocalizedString("从起始标记匹配到下一处结束标记；没有结束标记时不会应用字体。", comment: "")
        case .regularExpression:
            return NSLocalizedString("正则表达式的完整匹配范围会使用规则字体。", comment: "")
        }
    }

    private var regularExpressionValidationPattern: String? {
        rule.kind == .regularExpression ? rule.exactText : nil
    }
}

import ETOSCore
import SwiftUI

struct MacFontRuleEditor: View {
    @StateObject private var draft: MacFontRuleDraft
    let isActive: Bool
    let apply: (ChatAppearanceTextFontRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    @State private var valid = true
    private var pattern: String? { draft.rule.kind == .regularExpression ? draft.rule.exactText : nil }
    init(rule: ChatAppearanceTextFontRule, chain: MacFontDraftCatalog.Chain, assets: [FontAssetRecord], isActive: Bool,
         apply: @escaping (ChatAppearanceTextFontRule) -> Void) {
        self.isActive = isActive; self.apply = apply
        _draft = StateObject(wrappedValue: MacFontRuleDraft(rule: rule, chain: chain, assets: assets))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "font-rule-\(draft.rule.id)", title: NSLocalizedString("使用说明", comment: ""),
                        details: NSLocalizedString("Mac 字体优先级使用说明", comment: ""), documentID: "settings-display", isActive: isActive)
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $draft.rule.isEnabled)
                    Picker(NSLocalizedString("匹配方式", comment: ""), selection: $draft.rule.kind) {
                        Text(NSLocalizedString("指定文字", comment: "")).tag(ChatAppearanceTextRuleKind.exactText)
                        Text(NSLocalizedString("起止标记之间", comment: "")).tag(ChatAppearanceTextRuleKind.delimitedText)
                        Text(NSLocalizedString("正则表达式", comment: "")).tag(ChatAppearanceTextRuleKind.regularExpression)
                    }
                    if draft.rule.kind == .delimitedText {
                        TextField(NSLocalizedString("起始标记", comment: ""), text: $draft.rule.startDelimiter)
                        TextField(NSLocalizedString("结束标记", comment: ""), text: $draft.rule.endDelimiter)
                        Toggle(NSLocalizedString("包含起止标记", comment: ""), isOn: $draft.rule.includesDelimiters)
                    } else {
                        TextField(NSLocalizedString("指定文字或正则表达式", comment: ""), text: $draft.rule.exactText, axis: .vertical)
                    }
                    if !valid { Text(NSLocalizedString("正则表达式无效，请检查语法。", comment: "")).font(.footnote).foregroundStyle(.red) }
                    NavigationLink(NSLocalizedString("字体优先级", comment: "")) {
                        MacFontChainEditor(id: "rule-\(draft.rule.id)", title: NSLocalizedString("字体优先级", comment: ""), chain: draft.chain,
                            revision: draft.revision, isActive: isActive, isWorking: draft.isWorking,
                            isCurrent: { draft.revision == $0 && !draft.isWorking && AppLockManager.shared.state != .locked }) { await draft.replaceChain($0) }
                    }
                }
            }
            .formStyle(.grouped).navigationTitle(NSLocalizedString("字体规则", comment: ""))
            .onAppear { visible = true }.onDisappear { visible = false }
            .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-font-rule-\(draft.rule.id)-\(draft.rule.kind.rawValue)"),
                title: NSLocalizedString("字体规则", comment: ""), documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
                isActive: isActive && visible && !draft.isWorking, settings: fields)
        }
        .disabled(!isActive || draft.isWorking)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: "")) { apply(draft.rule); dismiss() }.disabled(!isActive || draft.isWorking)
            }
        }
        .task(id: pattern) {
            guard let pattern else { valid = true; return }
            let result = await ChatAppearanceTextColorMatcher.isValidRegularExpression(pattern)
            guard !Task.isCancelled else { return }; valid = result
        }
        .modifier(MacGuideInspector()).frame(minWidth: 520, minHeight: 500)
    }
    private var fields: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { draft.rule.isEnabled }, set: { draft.rule.isEnabled = $0 }),
            .string("match_kind", label: NSLocalizedString("匹配方式", comment: ""), allowedValues: ["exactText", "delimitedText", "regularExpression"],
                    get: { draft.rule.kind.rawValue }, set: { if let kind = ChatAppearanceTextRuleKind(rawValue: $0) { draft.rule.kind = kind } }),
            .readOnly("font_priority", label: NSLocalizedString("字体优先级", comment: ""), value: { draft.chain.guideValue }),
            .readOnly("priority_requires_navigation", label: NSLocalizedString("字体优先级", comment: ""), value: { .bool(true) }),
            .readOnly("regex_valid", label: NSLocalizedString("正则表达式有效", comment: ""), value: { .bool(valid) }),
            .readOnly("requires_parent_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) })
        ]
        if draft.rule.kind == .delimitedText {
            fields += [
                .string("start_delimiter", label: NSLocalizedString("起始标记", comment: ""), get: { draft.rule.startDelimiter }, set: { draft.rule.startDelimiter = $0 }),
                .string("end_delimiter", label: NSLocalizedString("结束标记", comment: ""), get: { draft.rule.endDelimiter }, set: { draft.rule.endDelimiter = $0 }),
                .bool("includes_delimiters", label: NSLocalizedString("包含起止标记", comment: ""), get: { draft.rule.includesDelimiters }, set: { draft.rule.includesDelimiters = $0 })
            ]
        } else {
            fields.append(.string("exact_text", label: NSLocalizedString("指定文字或正则表达式", comment: ""), get: { draft.rule.exactText }, set: { draft.rule.exactText = $0 }))
        }
        return fields
    }
}

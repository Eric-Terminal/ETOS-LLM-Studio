import ETOSCore
import SwiftUI

struct MacAppearanceTextStyleEditor: View {
    @ObservedObject var draft: MacAppearanceProfileDraft
    let group: MacAppearanceTextGroup
    let isActive: Bool
    @State private var visible = false
    private var bodySlot: Binding<ChatAppearanceColorSlot> {
        Binding(get: { draft.profile[keyPath: group.bodyPath] }, set: { draft.profile[keyPath: group.bodyPath] = $0 })
    }
    private var styles: Binding<ChatAppearanceTextStyleColors> {
        Binding(get: { draft.profile[keyPath: group.stylesPath] }, set: { draft.profile[keyPath: group.stylesPath] = $0 })
    }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "appearance-text-\(group.id)", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 文字着色使用说明", comment: ""), documentID: "settings-display", isActive: isActive)
            }
            Section { MacAppearanceColorField(slot: bodySlot) } header: { Text(NSLocalizedString("正文", comment: "")) }
            Section { MacAppearanceColorField(slot: styles.emphasis) } header: { Text(NSLocalizedString("斜体", comment: "")) }
            Section { MacAppearanceColorField(slot: styles.strong) } header: { Text(NSLocalizedString("粗体", comment: "")) }
            Section { MacAppearanceColorField(slot: styles.code) } header: { Text(NSLocalizedString("代码", comment: "")) }
            Section {
                ForEach(styles.customRules) { rule in
                    NavigationLink {
                        MacAppearanceRuleEditor(rule: rule, profileID: draft.profile.id, group: group, isActive: isActive)
                    } label: {
                        Label(rule.wrappedValue.exactText.isEmpty ? NSLocalizedString("着色规则", comment: "") : rule.wrappedValue.exactText,
                              systemImage: rule.wrappedValue.isEnabled ? "paintbrush" : "paintbrush.pointed")
                            .lineLimit(1)
                    }
                    .contextMenu {
                        Button(NSLocalizedString("上移", comment: "")) {
                            let id = rule.wrappedValue.id
                            draft.changeRules(group) { rules in
                                if let index = rules.firstIndex(where: { $0.id == id }), index > 0 { rules.swapAt(index, index - 1) }
                            }
                        }
                        Button(NSLocalizedString("下移", comment: "")) {
                            let id = rule.wrappedValue.id
                            draft.changeRules(group) { rules in
                                if let index = rules.firstIndex(where: { $0.id == id }), index + 1 < rules.count { rules.swapAt(index, index + 1) }
                            }
                        }
                        Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                            let id = rule.wrappedValue.id
                            draft.changeRules(group) { $0.removeAll { $0.id == id } }
                        }
                    }
                }
                .onDelete { indices in draft.changeRules(group) { $0.remove(atOffsets: indices) } }
                .onMove { indices, destination in draft.changeRules(group) { $0.move(fromOffsets: indices, toOffset: destination) } }
                Button(NSLocalizedString("添加着色规则", comment: "")) {
                    let color = bodySlot.wrappedValue.hex
                    draft.changeRules(group) { $0.append(.init(colorHex: color)) }
                }
            } header: { Text(NSLocalizedString("指定内容", comment: "")) } footer: {
                Text(NSLocalizedString("规则按从上到下的顺序匹配；靠前规则优先。代码与公式会保留各自的专用颜色。", comment: ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).navigationTitle(group.title)
        .onAppear { visible = true }.onDisappear { visible = false }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-appearance-text-\(draft.profile.id)-\(group.id)"), title: group.title,
            documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")], isActive: isActive && visible,
            settings: fields("body", NSLocalizedString("正文", comment: ""), bodySlot)
                + fields("emphasis", NSLocalizedString("斜体", comment: ""), styles.emphasis)
                + fields("strong", NSLocalizedString("粗体", comment: ""), styles.strong)
                + fields("code", NSLocalizedString("代码", comment: ""), styles.code) + [
                .readOnly("rule_count", label: NSLocalizedString("指定内容", comment: ""), value: { .int(styles.wrappedValue.customRules.count) }),
                .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
            ])
    }

    private func fields(_ key: String, _ title: String, _ slot: Binding<ChatAppearanceColorSlot>) -> [GuidePageSetting] {
        [
            .bool(key + "_enabled", label: String(format: NSLocalizedString("%@：%@", comment: ""), title, NSLocalizedString("自定义颜色", comment: "")),
                  get: { slot.wrappedValue.isEnabled }, set: { slot.wrappedValue.isEnabled = $0 }),
            .string(key + "_hex", label: String(format: NSLocalizedString("%@：%@", comment: ""), title, NSLocalizedString("十六进制颜色", comment: "")),
                    get: { slot.wrappedValue.hex }, set: { slot.wrappedValue.hex = $0 })
        ]
    }
}

private struct MacAppearanceRuleEditor: View {
    @Binding var rule: ChatAppearanceTextColorRule
    let profileID: String
    let group: MacAppearanceTextGroup
    let isActive: Bool
    @State private var visible = false
    @StateObject private var color = MacAppearanceColorDraft()
    @State private var isPatternValid = true
    private var pattern: String? { rule.kind == .regularExpression ? rule.exactText : nil }

    var body: some View {
        Form {
            Section {
                MacSettingsIntroCard(id: "appearance-rule", title: NSLocalizedString("使用说明", comment: ""),
                    details: NSLocalizedString("Mac 文字着色使用说明", comment: ""), documentID: "settings-display", isActive: isActive)
                Toggle(NSLocalizedString("启用", comment: ""), isOn: $rule.isEnabled)
                Picker(NSLocalizedString("匹配方式", comment: ""), selection: $rule.kind) {
                    Text(NSLocalizedString("指定文字", comment: "")).tag(ChatAppearanceTextColorRuleKind.exactText)
                    Text(NSLocalizedString("起止标记之间", comment: "")).tag(ChatAppearanceTextColorRuleKind.delimitedText)
                    Text(NSLocalizedString("正则表达式", comment: "")).tag(ChatAppearanceTextColorRuleKind.regularExpression)
                }
                if rule.kind == .delimitedText {
                    TextField(NSLocalizedString("起始标记", comment: ""), text: $rule.startDelimiter)
                    TextField(NSLocalizedString("结束标记", comment: ""), text: $rule.endDelimiter)
                    Toggle(NSLocalizedString("包含起止标记", comment: ""), isOn: $rule.includesDelimiters)
                } else {
                    TextField(rule.kind == .regularExpression ? NSLocalizedString("正则表达式", comment: "") : NSLocalizedString("指定文字", comment: ""), text: $rule.exactText, axis: .vertical)
                }
                if !isPatternValid { Text(NSLocalizedString("正则表达式无效，请检查语法。", comment: "")).font(.footnote).foregroundStyle(.red) }
                ColorPicker(NSLocalizedString("颜色", comment: ""), selection: Binding(get: { color.color }, set: {
                    if let hex = ChatAppearanceColorCodec.hexRGBA(from: $0) { rule.colorHex = hex }
                }), supportsOpacity: true)
                TextField(NSLocalizedString("十六进制颜色", comment: ""), text: $rule.colorHex)
            }
        }
        .formStyle(.grouped).navigationTitle(NSLocalizedString("着色规则", comment: ""))
        .onAppear { visible = true; color.update(rule.colorHex) }.onDisappear { visible = false; color.cancel() }
        .onChange(of: rule.colorHex) { _, value in color.update(value) }
        .task(id: pattern) {
            guard let pattern else { isPatternValid = true; return }
            let valid = await ChatAppearanceTextColorMatcher.isValidRegularExpression(pattern)
            guard !Task.isCancelled else { return }; isPatternValid = valid
        }
        .guideSettingsPageContext(id: GuidePageID(rawValue: "mac-appearance-rule-\(profileID)-\(group.id)-\(rule.id)-\(rule.kind.rawValue)"),
            title: NSLocalizedString("着色规则", comment: ""), documents: [GuideDocumentReference(id: "settings-display", title: "Display Settings")],
            isActive: isActive && visible, settings: guideSettings)
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { rule.isEnabled }, set: { rule.isEnabled = $0 }),
            .string("kind", label: NSLocalizedString("匹配方式", comment: ""), allowedValues: ["exactText", "delimitedText", "regularExpression"],
                    get: { rule.kind.rawValue }, set: { if let kind = ChatAppearanceTextColorRuleKind(rawValue: $0) { rule.kind = kind } }),
            .string("hex_rgba", label: NSLocalizedString("十六进制颜色", comment: ""), get: { rule.colorHex }, set: { rule.colorHex = $0 }),
            .readOnly("regular_expression_valid", label: NSLocalizedString("正则表达式是否有效", comment: ""), value: { .bool(isPatternValid) }),
            .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
        ]
        if rule.kind == .delimitedText {
            fields += [
                .string("start_delimiter", label: NSLocalizedString("起始标记", comment: ""), get: { rule.startDelimiter }, set: { rule.startDelimiter = $0 }),
                .string("end_delimiter", label: NSLocalizedString("结束标记", comment: ""), get: { rule.endDelimiter }, set: { rule.endDelimiter = $0 }),
                .bool("includes_delimiters", label: NSLocalizedString("包含起止标记", comment: ""), get: { rule.includesDelimiters }, set: { rule.includesDelimiters = $0 })
            ]
        } else {
            fields.append(.string("exact_text", label: NSLocalizedString("指定文字", comment: ""), get: { rule.exactText }, set: { rule.exactText = $0 }))
        }
        return fields
    }
}

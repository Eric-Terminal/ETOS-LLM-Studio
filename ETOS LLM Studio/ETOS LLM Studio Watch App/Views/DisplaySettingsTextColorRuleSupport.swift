// ============================================================================
// DisplaySettingsTextColorRuleSupport.swift
// ============================================================================
// watchOS 聊天文字指定内容着色规则管理
// ============================================================================

import SwiftUI
import ETOSCore

struct WatchTextColorRuleRow: View {
    let rule: ChatAppearanceTextColorRule
    let fallback: Color

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(ruleSummary)
                    .lineLimit(1)
                Text(ruleKindTitle)
                    .etFont(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Circle()
                .fill(ChatAppearanceColorCodec.color(from: rule.colorHex, fallback: fallback))
                .overlay {
                    Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                }
                .frame(width: 14, height: 14)
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
            guard rule.isConfigured else {
                return NSLocalizedString("未设置起止标记", comment: "")
            }
            return "\(rule.startDelimiter)…\(rule.endDelimiter)"
        case .regularExpression:
            return rule.exactText.isEmpty
                ? NSLocalizedString("未设置正则表达式", comment: "")
                : rule.exactText
        }
    }

    private var ruleKindTitle: String {
        let title: String
        switch rule.kind {
        case .exactText:
            title = NSLocalizedString("指定文字", comment: "")
        case .delimitedText:
            title = NSLocalizedString("起止标记之间", comment: "")
        case .regularExpression:
            title = NSLocalizedString("正则表达式", comment: "")
        }
        return rule.isEnabled
            ? title
            : String(format: NSLocalizedString("%@（已停用）", comment: ""), title)
    }
}

struct WatchTextColorRuleEditorView: View {
    @Binding var rule: ChatAppearanceTextColorRule
    let fallback: Color
    @State private var isRegularExpressionValid = true

    var body: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("启用规则", comment: ""), isOn: $rule.isEnabled)
            }

            Section {
                Picker(NSLocalizedString("匹配方式", comment: ""), selection: $rule.kind) {
                    Text(NSLocalizedString("指定文字", comment: ""))
                        .tag(ChatAppearanceTextColorRuleKind.exactText)
                    Text(NSLocalizedString("起止标记之间", comment: ""))
                        .tag(ChatAppearanceTextColorRuleKind.delimitedText)
                    Text(NSLocalizedString("正则表达式", comment: ""))
                        .tag(ChatAppearanceTextColorRuleKind.regularExpression)
                }

                switch rule.kind {
                case .exactText:
                    TextField(NSLocalizedString("要匹配的文字", comment: ""), text: $rule.exactText)
                case .delimitedText:
                    TextField(NSLocalizedString("起始标记", comment: ""), text: $rule.startDelimiter)
                    TextField(NSLocalizedString("结束标记", comment: ""), text: $rule.endDelimiter)
                    Toggle(NSLocalizedString("包含起止标记", comment: ""), isOn: $rule.includesDelimiters)
                case .regularExpression:
                    TextField(NSLocalizedString("要匹配的正则表达式", comment: ""), text: $rule.exactText)
                }
            } header: {
                Text(NSLocalizedString("匹配内容", comment: ""))
            } footer: {
                VStack(alignment: .leading) {
                    Text(matchDescription)
                    if rule.kind == .regularExpression, !isRegularExpressionValid {
                        Text(NSLocalizedString("正则表达式无效，请检查语法。", comment: ""))
                            .foregroundStyle(.red)
                    }
                }
                .etFont(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    WatchColorEditorView(
                        title: NSLocalizedString("规则颜色", comment: ""),
                        hexValue: $rule.colorHex,
                        fallback: fallback,
                        description: NSLocalizedString("设置匹配文字在聊天内容中的颜色。", comment: ""),
                        supportsOpacity: false
                    )
                } label: {
                    HStack {
                        Text(NSLocalizedString("颜色", comment: ""))
                        Spacer(minLength: 4)
                        Circle()
                            .fill(ChatAppearanceColorCodec.color(from: rule.colorHex, fallback: fallback))
                            .overlay {
                                Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                            }
                            .frame(width: 14, height: 14)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("着色规则", comment: ""))
        .task(id: regularExpressionValidationPattern) {
            guard let pattern = regularExpressionValidationPattern else {
                isRegularExpressionValid = true
                return
            }
            let isValid = await ChatAppearanceTextColorMatcher.isValidRegularExpression(pattern)
            guard regularExpressionValidationPattern == pattern else { return }
            isRegularExpressionValid = isValid
        }
    }

    private var matchDescription: String {
        switch rule.kind {
        case .exactText:
            return NSLocalizedString("只修改完全相同文字片段的颜色，不使用正则表达式。", comment: "")
        case .delimitedText:
            return NSLocalizedString("从起始标记匹配到下一处结束标记；没有结束标记时不会着色。", comment: "")
        case .regularExpression:
            return NSLocalizedString("正则表达式的完整匹配范围会使用所选颜色。", comment: "")
        }
    }

    private var regularExpressionValidationPattern: String? {
        rule.kind == .regularExpression ? rule.exactText : nil
    }
}

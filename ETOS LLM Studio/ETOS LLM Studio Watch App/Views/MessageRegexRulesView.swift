// ============================================================================
// MessageRegexRulesView.swift
// ============================================================================
// ETOS LLM Studio Watch App
//
// 管理聊天消息正则替换规则。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct MessageRegexRulesView: View {
    @ObservedObject private var store = MessageRegexRuleStore.shared

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("正则替换", comment: "")),
                footer: Text(NSLocalizedString("规则会按列表顺序应用。保存替换会写入消息；仅发送只影响模型请求；仅显示只影响聊天气泡展示。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                NavigationLink {
                    MessageRegexRuleEditorView(initialRule: MessageRegexRule()) { rule in
                        store.update(rule)
                    }
                } label: {
                    Label(NSLocalizedString("新增规则", comment: ""), systemImage: "plus")
                }

                if store.rules.isEmpty {
                    Text(NSLocalizedString("暂无正则规则", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.rules) { rule in
                        NavigationLink {
                            MessageRegexRuleEditorView(initialRule: rule) { savedRule in
                                store.update(savedRule)
                            }
                        } label: {
                            MessageRegexRuleRow(rule: rule)
                        }
                    }
                    .onDelete(perform: deleteRules)
                    .onMove(perform: moveRules)
                }
            }
        }
        .navigationTitle(NSLocalizedString("消息规则", comment: ""))
    }

    private func deleteRules(at offsets: IndexSet) {
        var updated = store.rules
        updated.remove(atOffsets: offsets)
        store.save(updated)
    }

    private func moveRules(from source: IndexSet, to destination: Int) {
        var updated = store.rules
        updated.move(fromOffsets: source, toOffset: destination)
        store.save(updated)
    }
}

private struct MessageRegexRuleRow: View {
    let rule: MessageRegexRule

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(displayName)
                    .lineLimit(1)
                Spacer()
                Image(systemName: rule.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(rule.isEnabled ? .green : .secondary)
            }

            Text(rule.pattern)
                .etFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("\(MessageRegexRuleLabels.title(for: rule.mode)) · \(MessageRegexRuleLabels.scopeSummary(for: rule.scopes))")
                .etFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var displayName: String {
        let trimmed = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSLocalizedString("未命名规则", comment: "") : trimmed
    }
}

private struct MessageRegexRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: MessageRegexRule
    @State private var validationMessage: String?

    let onSave: (MessageRegexRule) -> Void

    init(initialRule: MessageRegexRule, onSave: @escaping (MessageRegexRule) -> Void) {
        _rule = State(initialValue: initialRule)
        self.onSave = onSave
    }

    var body: some View {
        List {
            Section(NSLocalizedString("规则", comment: "")) {
                TextField(NSLocalizedString("规则名称", comment: ""), text: $rule.name.watchKeyboardNewlineBinding())
                TextField(NSLocalizedString("正则表达式", comment: ""), text: $rule.pattern.watchKeyboardNewlineBinding())
                TextField(NSLocalizedString("替换字符串", comment: ""), text: $rule.replacement.watchKeyboardNewlineBinding(), axis: .vertical)
                    .lineLimit(2...5)
                Toggle(NSLocalizedString("启用规则", comment: ""), isOn: $rule.isEnabled)
            }

            Section(NSLocalizedString("作用范围", comment: "")) {
                Toggle(NSLocalizedString("用户消息", comment: ""), isOn: scopeBinding(for: .user))
                Toggle(NSLocalizedString("助手消息", comment: ""), isOn: scopeBinding(for: .assistant))
            }

            Section(
                header: Text(NSLocalizedString("应用方式", comment: "")),
                footer: Text(MessageRegexRuleLabels.detail(for: rule.mode))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            ) {
                Picker(NSLocalizedString("应用方式", comment: ""), selection: $rule.mode) {
                    ForEach(MessageRegexMode.allCases) { mode in
                        Text(MessageRegexRuleLabels.title(for: mode)).tag(mode)
                    }
                }
            }

            Section {
                Button(NSLocalizedString("保存", comment: "")) {
                    save()
                }
            } footer: {
                Text(NSLocalizedString("替换字符串支持 $0、$1、$2 这类捕获组引用。", comment: ""))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("正则替换", comment: ""))
        .alert(NSLocalizedString("正则规则无法保存", comment: ""), isPresented: validationAlertBinding) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) { }
        } message: {
            Text(validationMessage ?? "")
        }
    }

    private var validationAlertBinding: Binding<Bool> {
        Binding(
            get: { validationMessage != nil },
            set: { isPresented in
                if !isPresented {
                    validationMessage = nil
                }
            }
        )
    }

    private func scopeBinding(for scope: MessageRegexRoleScope) -> Binding<Bool> {
        Binding(
            get: { rule.scopes.contains(scope) },
            set: { isSelected in
                if isSelected {
                    if !rule.scopes.contains(scope) {
                        rule.scopes.append(scope)
                    }
                } else {
                    rule.scopes.removeAll { $0 == scope }
                }
            }
        )
    }

    private func save() {
        let trimmedName = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            validationMessage = NSLocalizedString("规则名称不能为空。", comment: "")
            return
        }
        guard !trimmedPattern.isEmpty else {
            validationMessage = NSLocalizedString("正则表达式不能为空。", comment: "")
            return
        }
        guard !rule.scopes.isEmpty else {
            validationMessage = NSLocalizedString("请至少选择一个作用范围。", comment: "")
            return
        }
        do {
            _ = try NSRegularExpression(pattern: trimmedPattern)
        } catch {
            validationMessage = NSLocalizedString("正则表达式无效。", comment: "")
            return
        }

        rule.name = trimmedName
        rule.pattern = trimmedPattern
        onSave(rule)
        dismiss()
    }
}

private enum MessageRegexRuleLabels {
    static func title(for mode: MessageRegexMode) -> String {
        switch mode {
        case .persist:
            return NSLocalizedString("保存替换", comment: "")
        case .sendOnly:
            return NSLocalizedString("仅发送", comment: "")
        case .visualOnly:
            return NSLocalizedString("仅显示", comment: "")
        }
    }

    static func detail(for mode: MessageRegexMode) -> String {
        switch mode {
        case .persist:
            return NSLocalizedString("会保存到消息内容", comment: "")
        case .sendOnly:
            return NSLocalizedString("只影响发送给模型的内容", comment: "")
        case .visualOnly:
            return NSLocalizedString("只影响聊天气泡显示", comment: "")
        }
    }

    static func scopeSummary(for scopes: [MessageRegexRoleScope]) -> String {
        let ordered = MessageRegexRoleScope.allCases.filter { scopes.contains($0) }
        return ordered.map(title(for:)).joined(separator: NSLocalizedString("、", comment: ""))
    }

    static func title(for scope: MessageRegexRoleScope) -> String {
        switch scope {
        case .user:
            return NSLocalizedString("用户消息", comment: "")
        case .assistant:
            return NSLocalizedString("助手消息", comment: "")
        }
    }
}

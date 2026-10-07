import ETOSCore
import SwiftUI

struct MacRoleplayRegexEditor: View {
    @ObservedObject var model: MacRoleplayModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: MacRoleplayRegexDraft
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("基本信息", comment: "")) {
                    TextField(NSLocalizedString("正则名称", comment: ""), text: $draft.rule.scriptName)
                    Toggle(NSLocalizedString("启用正则", comment: ""), isOn: enabled)
                    Picker(NSLocalizedString("作用域", comment: ""), selection: $draft.rule.scope) {
                        ForEach(RoleplayRegexScope.allCases, id: \.self) { Text($0.macLabel).tag($0) }
                    }
                }
                textSection(NSLocalizedString("查找表达式", comment: ""), text: $draft.rule.findRegex)
                textSection(NSLocalizedString("替换内容", comment: ""), text: $draft.rule.replaceString)
                Section {
                    TextEditor(text: $draft.trimStringsText).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80).accessibilityLabel(NSLocalizedString("修剪字符串", comment: ""))
                } header: { Text(NSLocalizedString("修剪字符串", comment: "")) }
                footer: { Text(NSLocalizedString("每行填写一个需要从匹配结果中移除的字符串。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                Section(NSLocalizedString("运行位置", comment: "")) {
                    ForEach(RoleplayRegexPlacement.allCases, id: \.self) { placement in
                        Toggle(placement.macLabel, isOn: placementBinding(placement))
                    }
                }
                Section(NSLocalizedString("运行选项", comment: "")) {
                    Toggle(NSLocalizedString("仅 Markdown", comment: ""), isOn: $draft.rule.markdownOnly)
                    Toggle(NSLocalizedString("仅提示词", comment: ""), isOn: $draft.rule.promptOnly)
                    Toggle(NSLocalizedString("编辑时运行", comment: ""), isOn: $draft.rule.runOnEdit)
                    Picker(NSLocalizedString("宏替换", comment: ""), selection: $draft.rule.substituteRegex) {
                        Text(NSLocalizedString("不替换宏", comment: "")).tag(0)
                        Text(NSLocalizedString("替换宏", comment: "")).tag(1)
                        Text(NSLocalizedString("转义后替换宏", comment: "")).tag(2)
                        if !(0...2).contains(draft.rule.substituteRegex) {
                            Text(NSLocalizedString("保留导入值", comment: "")).tag(draft.rule.substituteRegex)
                        }
                    }
                }
                Section {
                    MacSettingsIntroCard(id: "roleplay-regex-editor", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 角色正则与脚本使用说明", comment: ""), documentID: "roleplay")
                } footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(saving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("编辑角色正则", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(saving || model.isWorking || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-roleplay-regex-editor-\(draft.originalCharacter.id)-\(draft.id)"),
                title: NSLocalizedString("编辑角色正则", comment: ""), documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
                settings: guideSettings
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(saving)
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
        .frame(minWidth: 560, minHeight: 600)
    }

    private var enabled: Binding<Bool> { Binding(get: { !draft.rule.disabled }, set: { draft.rule.disabled = !$0 }) }

    private func placementBinding(_ placement: RoleplayRegexPlacement) -> Binding<Bool> {
        Binding(get: { draft.rule.placements.contains(placement) }, set: { selected in
            if selected {
                if !draft.rule.placements.contains(placement) { draft.rule.placements.append(placement) }
            } else { draft.rule.placements.removeAll { $0 == placement } }
        })
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("character_id", label: NSLocalizedString("角色卡", comment: ""), value: { .string(draft.originalCharacter.id.uuidString) }),
            .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) }),
            .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(saving || workspace.isRestoringData) })
        ]
        guard !saving, !workspace.isRestoringData else { return fields }
        fields += [
            .string("name", label: NSLocalizedString("正则名称", comment: ""), get: { draft.rule.scriptName }, set: { draft.rule.scriptName = $0 }),
            .bool("enabled", label: NSLocalizedString("启用正则", comment: ""), get: { enabled.wrappedValue }, set: { enabled.wrappedValue = $0 }),
            .string("scope", label: NSLocalizedString("作用域", comment: ""), allowedValues: RoleplayRegexScope.macGuideValues,
                    get: { draft.rule.scope.rawValue }, set: { if let value = RoleplayRegexScope(rawValue: $0) { draft.rule.scope = value } }),
            .string("find_regex", label: NSLocalizedString("查找表达式", comment: ""), get: { draft.rule.findRegex }, set: { draft.rule.findRegex = $0 }),
            .string("replacement", label: NSLocalizedString("替换内容", comment: ""), get: { draft.rule.replaceString }, set: { draft.rule.replaceString = $0 }),
            .string("trim_strings", label: NSLocalizedString("修剪字符串", comment: ""), get: { draft.trimStringsText }, set: { draft.trimStringsText = $0 }),
            .bool("markdown_only", label: NSLocalizedString("仅 Markdown", comment: ""), get: { draft.rule.markdownOnly }, set: { draft.rule.markdownOnly = $0 }),
            .bool("prompt_only", label: NSLocalizedString("仅提示词", comment: ""), get: { draft.rule.promptOnly }, set: { draft.rule.promptOnly = $0 }),
            .bool("run_on_edit", label: NSLocalizedString("编辑时运行", comment: ""), get: { draft.rule.runOnEdit }, set: { draft.rule.runOnEdit = $0 }),
            .integer("substitute_regex", label: NSLocalizedString("宏替换", comment: ""), range: 0...2,
                     get: { draft.rule.substituteRegex }, set: { draft.rule.substituteRegex = $0 })
        ]
        for placement in RoleplayRegexPlacement.allCases {
            fields.append(.bool("placement_\(placement.rawValue)", label: placement.macLabel,
                                get: { placementBinding(placement).wrappedValue }, set: { placementBinding(placement).wrappedValue = $0 }))
        }
        return fields
    }

    private func textSection(_ title: String, text: Binding<String>) -> some View {
        Section(title) { TextEditor(text: text).font(.system(.body, design: .monospaced)).frame(minHeight: 100).accessibilityLabel(title) }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await model.save(draft); dismiss() } catch { self.error = error.localizedDescription }
        }
    }
}

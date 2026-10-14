import ETOSCore
import SwiftUI

struct MacSessionEditor: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChatSession
    @State private var isSaving = false
    @State private var error: String?
    private let original: ChatSession

    init(session: ChatSession) {
        original = session
        _draft = State(initialValue: session)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField(NSLocalizedString("名称", comment: ""), text: $draft.name) }
                Section {
                    TextField(NSLocalizedString("会话系统提示词", comment: ""), text: optionalText(\.systemPrompt), axis: .vertical).lineLimit(3...10)
                    TextField(NSLocalizedString("主题提示", comment: ""), text: optionalText(\.topicPrompt), axis: .vertical).lineLimit(3...10)
                    TextField(NSLocalizedString("增强提示词", comment: ""), text: optionalText(\.enhancedPrompt), axis: .vertical).lineLimit(3...10)
                } header: { Text(NSLocalizedString("会话提示词", comment: "")) }
                footer: {
                    Text(NSLocalizedString("这些提示词只对当前会话生效，App 的工具协议与运行约束不会被替换。", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Picker(NSLocalizedString("首选模型", comment: ""), selection: optionalText(\.preferredModelIdentifier)) {
                        Text(NSLocalizedString("跟随全局模型", comment: "")).tag("")
                        ForEach(workspace.sessionModelCatalog.rows) { row in Text(row.title).tag(row.id) }
                        if let id = draft.preferredModelIdentifier, !workspace.sessionModelCatalog.availableIDs.contains(id) {
                            Text(NSLocalizedString("已选模型不可用", comment: "")).tag(id)
                        }
                    }
                }
                Section {
                    Toggle(NSLocalizedString("隔离记忆上下文", comment: ""), isOn: $draft.memoryContextIsolationEnabled)
                    Toggle(NSLocalizedString("隔离工具上下文", comment: ""), isOn: $draft.toolContextIsolationEnabled)
                    Toggle(NSLocalizedString("隔离全局系统提示词", comment: ""), isOn: $draft.globalSystemPromptIsolationEnabled)
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    MacSettingsIntroCard(id: "session-settings", title: NSLocalizedString("会话设置", comment: ""),
                                         details: NSLocalizedString("会话系统提示词、主题提示和增强提示词分别保存在当前会话中，不会修改全局提示词。首选模型优先于工具栏的全局选择；选择“跟随全局模型”可取消绑定。模型暂时不可用时保留绑定，本轮按核心规则回退到全局模型。三个隔离开关独立控制记忆、工具和全局提示词，角色卡与世界书不受影响。向导只修改草稿，点击保存后生效；会话在其他位置变化后需要重新打开编辑器。", comment: ""),
                                         documentID: "macos-workspace")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSaving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("会话设置", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }
                        .disabled(isSaving || draft.name.isEmpty || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-session-\(draft.id)"),
                title: NSLocalizedString("会话设置", comment: ""),
                documents: [GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                settings: isSaving || workspace.isRestoringData ? [
                    .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })
                ] : [
                    .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) }),
                    .string("name", label: NSLocalizedString("名称", comment: ""), allowsEmpty: false, get: { draft.name }, set: { draft.name = $0 }),
                    .string("system_prompt", label: NSLocalizedString("会话系统提示词", comment: ""), get: { draft.systemPrompt ?? "" }, set: { optionalText(\.systemPrompt).wrappedValue = $0 }),
                    .string("topic_prompt", label: NSLocalizedString("主题提示", comment: ""), get: { draft.topicPrompt ?? "" }, set: { optionalText(\.topicPrompt).wrappedValue = $0 }),
                    .string("enhanced_prompt", label: NSLocalizedString("增强提示词", comment: ""), get: { draft.enhancedPrompt ?? "" }, set: { optionalText(\.enhancedPrompt).wrappedValue = $0 }),
                    .string("preferred_model", label: NSLocalizedString("首选模型", comment: ""), allowedValues: workspace.sessionModelCatalog.guideIDs,
                            get: { draft.preferredModelIdentifier ?? "" }, set: { optionalText(\.preferredModelIdentifier).wrappedValue = $0 }),
                    .readOnly("available_models", label: NSLocalizedString("模型", comment: ""), value: { workspace.sessionModelCatalog.guideValue }),
                    .bool("memory_isolation", label: NSLocalizedString("隔离记忆上下文", comment: ""), get: { draft.memoryContextIsolationEnabled }, set: { draft.memoryContextIsolationEnabled = $0 }),
                    .bool("tool_isolation", label: NSLocalizedString("隔离工具上下文", comment: ""), get: { draft.toolContextIsolationEnabled }, set: { draft.toolContextIsolationEnabled = $0 }),
                    .bool("prompt_isolation", label: NSLocalizedString("隔离全局系统提示词", comment: ""), get: { draft.globalSystemPromptIsolationEnabled }, set: { draft.globalSystemPromptIsolationEnabled = $0 })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving)
        .frame(minWidth: 540, minHeight: 520)
    }

    private func optionalText(_ keyPath: WritableKeyPath<ChatSession, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" }, set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await workspace.saveSession(draft, replacing: original); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

import SwiftUI

/// 由宿主注入编辑器包装，手表可为每一级页面保留原生向导入口。
public struct BuiltInToolDescriptionListView<Editor: View>: View {
    private let isActive: Bool
    private let editor: (ToolDescriptionTarget) -> Editor
    @ObservedObject private var manager = MCPManager.shared
    @State private var groups: [ToolDescriptionGroup] = []

    public init(isActive: Bool = true, @ViewBuilder editor: @escaping (ToolDescriptionTarget) -> Editor) {
        self.isActive = isActive
        self.editor = editor
    }

    public var body: some View {
        List {
            Section {
                ToolDescriptionIntroCard()
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        NavigationLink {
                            editor(row.target)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(row.title)
                                Text(row.isCustomized ? NSLocalizedString("自定义", comment: "") : NSLocalizedString("默认", comment: ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
        }
        .navigationTitle(NSLocalizedString("工具描述", comment: ""))
        .guideSettingsPageContext(
            id: "settings-tool-descriptions",
            title: NSLocalizedString("工具描述", comment: ""),
            documents: [GuideDocumentReference(id: "built-in-prompts", title: "Built-in Prompts")],
            isActive: isActive,
            settings: [.readOnly("tools", label: NSLocalizedString("内置工具", comment: ""), value: {
                .array(groups.flatMap { group in
                    group.rows.map { row in
                        .dictionary([
                            "id": .string(row.id), "title": .string(row.title),
                            "server": .string(group.title), "is_customized": .bool(row.isCustomized)
                        ])
                    }
                })
            })]
        )
        .task(id: manager.servers) {
            await manager.waitForInitialLoadIfNeeded()
            let prompts = await Task.detached(priority: .utility) {
                BuiltInPromptStore.snapshots(in: .toolDescriptions)
            }.value
            guard !Task.isCancelled else { return }
            groups = [ToolDescriptionGroup(
                id: "built-in", title: NSLocalizedString("内置工具", comment: ""),
                rows: prompts.map { ToolDescriptionRow(target: .builtIn($0.id), title: $0.title, isCustomized: $0.isCustomized) }
            )] + manager.builtInToolDescriptionGroups()
        }
    }
}

public struct ToolDescriptionEditorView: View {
    private let isActive: Bool
    @StateObject private var model: ToolDescriptionEditorModel

    public init(target: ToolDescriptionTarget, isActive: Bool = true) {
        self.isActive = isActive
        _model = StateObject(wrappedValue: ToolDescriptionEditorModel(target: target))
    }

    public var body: some View {
        Form {
            Section { ToolDescriptionIntroCard() }
            if model.isLoaded {
                Section {
                    Toggle(NSLocalizedString("使用默认描述", value: "Use Default Description", comment: ""), isOn: $model.usesDefault)
                    #if os(watchOS)
                    TextField(NSLocalizedString("工具描述", comment: ""), text: $model.draft, axis: .vertical)
                        .disabled(model.usesDefault)
                    #else
                    TextEditor(text: $model.draft)
                        .frame(minHeight: 200)
                        .disabled(model.usesDefault)
                        .accessibilityLabel(NSLocalizedString("工具描述", comment: ""))
                    #endif
                } header: {
                    Text(NSLocalizedString("工具描述", comment: ""))
                } footer: {
                    Text(NSLocalizedString("保存后用于后续请求；自定义描述可以留空。", value: "Applies to future requests after saving. A custom description may be empty.", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text(model.defaultDescription)
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text(NSLocalizedString("默认描述", value: "Default Description", comment: ""))
                }
                Section {
                    Button(NSLocalizedString("保存", comment: "")) { Task { await model.save() } }
                    Button(NSLocalizedString("恢复默认", comment: "")) {
                        model.usesDefault = true
                        model.draft = model.defaultDescription
                    }
                } footer: {
                    Text(NSLocalizedString("修改后需要保存", comment: ""))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(model.isSaving)
            }
            if let status = model.statusText {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(model.title)
        .disabled(model.isSaving || !isActive)
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "tool-description-\(model.target.id)"),
            title: model.title,
            documents: [
                GuideDocumentReference(id: "built-in-prompts", title: "Built-in Prompts"),
                GuideDocumentReference(id: "mcp-tools", title: "MCP Tools")
            ],
            isActive: isActive && model.isLoaded && !model.isSaving,
            settings: [
                .string("description", label: NSLocalizedString("工具描述", comment: ""), get: { model.draft }, set: { model.draft = $0 }),
                .bool("use_default", label: NSLocalizedString("使用默认描述", value: "Use Default Description", comment: ""), get: { model.usesDefault }, set: { model.usesDefault = $0 }),
                .readOnly("default_description", label: NSLocalizedString("默认描述", value: "Default Description", comment: ""), value: { .string(model.defaultDescription) }),
                .readOnly("input_schema", label: NSLocalizedString("输入 Schema", comment: ""), value: { model.inputSchema }),
                .readOnly("requires_save", label: NSLocalizedString("应用方式", comment: ""), value: { .string(NSLocalizedString("修改后需要保存", comment: "")) })
            ]
        )
        .task { await model.load() }
    }
}

private struct ToolDescriptionIntroCard: View {
    @State private var isExpanded = false

    var body: some View {
        #if os(watchOS)
        VStack(alignment: .leading) {
            Button {
                isExpanded.toggle()
            } label: {
                Label(NSLocalizedString("使用说明", comment: ""), systemImage: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            if isExpanded { helpText }
        }
        #else
        DisclosureGroup(NSLocalizedString("使用说明", comment: "")) {
            helpText
        }
        #endif
    }

    private var helpText: some View {
            Text(NSLocalizedString("工具描述会随工具定义发送给模型并占用输入 token。可缩短描述，但应保留用途、限制和必要的调用说明。这里只修改描述，不修改工具名称、参数 Schema 或审批策略。MCP 自定义描述与服务器配置一起保存，断连、重连、开关切换及工具列表刷新都会保留，删除服务器时移除。向导只修改编辑草稿；请关闭“使用默认描述”并保存以应用自定义内容。", value: "Tool descriptions are sent to the model and consume input tokens. You can shorten them, keeping their purpose, limits and essential calling instructions. Editing changes only the description, not the tool name, parameter schema or approval policy. MCP descriptions are saved with the server and survive disconnects, reconnects, toggles and tool-list refreshes. Deleting the server removes them. The guide edits only your draft. Turn off Use Default Description and save to apply custom text.", comment: "工具描述设置介绍卡"))
                .font(.footnote).foregroundStyle(.secondary)
    }
}

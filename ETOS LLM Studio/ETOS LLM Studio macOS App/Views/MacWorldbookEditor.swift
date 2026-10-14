import ETOSCore
import SwiftUI

struct MacWorldbookEditor: View {
    @ObservedObject var model: MacWorldbookModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Worldbook
    @State private var isSaving = false
    @State private var error: String?
    private let original: Worldbook?

    init(model: MacWorldbookModel, book: Worldbook, isNew: Bool = false) {
        self.model = model
        original = isNew ? nil : book
        _draft = State(initialValue: book)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("基本信息", comment: "")) {
                    TextField(NSLocalizedString("世界书名称", comment: ""), text: $draft.name)
                    TextField(NSLocalizedString("世界书描述", comment: ""), text: $draft.description, axis: .vertical).lineLimit(3...8)
                    Toggle(NSLocalizedString("启用", comment: ""), isOn: $draft.isEnabled)
                }
                Section {
                    Stepper(NSLocalizedString("扫描深度", comment: ""), value: $draft.settings.scanDepth, in: 1...Int.max)
                    Text(draft.settings.scanDepth.formatted()).font(.caption).foregroundStyle(.secondary)
                    Stepper(NSLocalizedString("最大递归层级", comment: ""), value: $draft.settings.maxRecursionDepth, in: 0...Int.max)
                    Text(draft.settings.maxRecursionDepth.formatted()).font(.caption).foregroundStyle(.secondary)
                    TextField(NSLocalizedString("最大注入条目", comment: ""), value: $draft.settings.maxInjectedEntries, format: .number)
                    TextField(NSLocalizedString("最大注入字符", comment: ""), value: $draft.settings.maxInjectedCharacters, format: .number)
                    Picker(NSLocalizedString("备用插入位置", comment: ""), selection: $draft.settings.fallbackPosition) {
                        ForEach(WorldbookPosition.allCases, id: \.self) { Text($0.macLabel).tag($0) }
                    }
                } header: { Text(NSLocalizedString("默认设置", comment: "")) }
                footer: { Text(NSLocalizedString("-1 表示不限制", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                Section {
                    MacSettingsIntroCard(id: "worldbook-editor", title: NSLocalizedString("世界书", comment: ""),
                                         details: NSLocalizedString("Mac 世界书使用说明", comment: ""), documentID: "worldbooks")
                } footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSaving || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("世界书详情", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(draft.name.isEmpty || isSaving || model.isWorking || workspace.isRestoringData)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-worldbook-editor-\(draft.id)"), title: NSLocalizedString("世界书详情", comment: ""),
                documents: [GuideDocumentReference(id: "worldbooks", title: "Worldbooks"), GuideDocumentReference(id: "macos-workspace", title: "macOS Workspace")],
                settings: isSaving || workspace.isRestoringData ? [
                    .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(true) })
                ] : [
                    .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) }),
                    .string("name", label: NSLocalizedString("世界书名称", comment: ""), allowsEmpty: false, get: { draft.name }, set: { draft.name = $0 }),
                    .string("description", label: NSLocalizedString("世界书描述", comment: ""), get: { draft.description }, set: { draft.description = $0 }),
                    .bool("enabled", label: NSLocalizedString("启用", comment: ""), get: { draft.isEnabled }, set: { draft.isEnabled = $0 }),
                    .integer("scan_depth", label: NSLocalizedString("扫描深度", comment: ""), range: 1...Int.max, get: { draft.settings.scanDepth }, set: { draft.settings.scanDepth = $0 }),
                    .integer("recursion", label: NSLocalizedString("最大递归层级", comment: ""), range: 0...Int.max, get: { draft.settings.maxRecursionDepth }, set: { draft.settings.maxRecursionDepth = $0 }),
                    .integer("entry_limit", label: NSLocalizedString("最大注入条目", comment: ""), range: -1...Int.max, get: { draft.settings.maxInjectedEntries }, set: { draft.settings.maxInjectedEntries = $0 }),
                    .integer("character_limit", label: NSLocalizedString("最大注入字符", comment: ""), range: -1...Int.max, get: { draft.settings.maxInjectedCharacters }, set: { draft.settings.maxInjectedCharacters = $0 }),
                    .string("position", label: NSLocalizedString("备用插入位置", comment: ""), allowedValues: WorldbookPosition.macGuideValues,
                            get: { draft.settings.fallbackPosition.rawValue }, set: { draft.settings.fallbackPosition = WorldbookPosition(rawValue: $0) ?? .after })
                ]
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving)
        .frame(minWidth: 540, minHeight: 520)
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do { try await model.save(draft, replacing: original); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

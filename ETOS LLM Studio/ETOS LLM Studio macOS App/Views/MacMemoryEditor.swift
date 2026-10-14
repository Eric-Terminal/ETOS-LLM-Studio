import ETOSCore
import SwiftUI

struct MacMemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MacMemoryModel
    @State private var draft: MemoryItem
    @State private var entities: String
    @State private var error: String?
    @State private var isSaving = false
    private let original: MemoryItem?

    init(model: MacMemoryModel, row: MacMemoryRow?) {
        self.model = model
        original = row?.item
        _draft = State(initialValue: row?.item ?? MemoryItem(content: "", embedding: []))
        _entities = State(initialValue: row?.entitiesText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("记忆内容", comment: "")) {
                    TextEditor(text: $draft.content).frame(minHeight: 160)
                }
                Section(NSLocalizedString("记忆属性", comment: "")) {
                    Picker(NSLocalizedString("类型", comment: ""), selection: $draft.kind) {
                        ForEach(MemoryKind.allCases, id: \.self) { kind in Text(kind.localizedTitle).tag(kind) }
                    }
                    Slider(value: $draft.importance, in: 0...1, step: 0.1) {
                        Text(NSLocalizedString("重要度", comment: ""))
                    }
                    Slider(value: $draft.confidence, in: 0...1, step: 0.1) {
                        Text(NSLocalizedString("置信度", comment: ""))
                    }
                    TextField(NSLocalizedString("相关实体（用逗号分隔）", comment: ""), text: $entities)
                    if original != nil {
                        Toggle(NSLocalizedString("已归档", comment: ""), isOn: $draft.isArchived)
                        LabeledContent(NSLocalizedString("来源", comment: ""), value: draft.source.localizedTitle)
                    }
                }
                if original != nil {
                    Section {
                        Button(NSLocalizedString("重新嵌入", comment: "")) { save(reembed: true) }
                    } footer: {
                        Text(NSLocalizedString("如果当前页面有未保存更改，会先保存再重新嵌入。", comment: ""))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if model.isWorking { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(isSaving || model.isWorking)
            .navigationTitle(original == nil ? NSLocalizedString("添加记忆", comment: "") : NSLocalizedString("编辑记忆", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(isSaving || model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }
                        .disabled(isSaving || model.isWorking || draft.content.isEmpty)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-memory-editor-\(draft.id)"), title: NSLocalizedString("编辑记忆", comment: ""),
                documents: [GuideDocumentReference(id: "settings-memory", title: "Memory System")],
                settings: guideSettings
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(isSaving || model.isWorking)
        .frame(minWidth: 540, minHeight: 520)
    }

    private var guideSettings: [GuidePageSetting] {
        if isSaving || model.isWorking {
            return [.readOnly("working", label: NSLocalizedString("保存中", comment: ""), value: { .bool(true) })]
        }
        var settings: [GuidePageSetting] = [
            .readOnly("editing_mode", label: NSLocalizedString("编辑方式", comment: ""), value: { .string("draft_until_save") }),
            .string("content", label: NSLocalizedString("记忆内容", comment: ""), allowsEmpty: false, get: { draft.content }, set: { draft.content = $0 }),
            .string("kind", label: NSLocalizedString("类型", comment: ""), allowedValues: MemoryKind.allCases.map(\.rawValue), get: { draft.kind.rawValue }, set: { if let value = MemoryKind(rawValue: $0) { draft.kind = value } }),
            .double("importance", label: NSLocalizedString("重要度", comment: ""), range: 0...1, get: { draft.importance }, set: { draft.importance = $0 }),
            .double("confidence", label: NSLocalizedString("置信度", comment: ""), range: 0...1, get: { draft.confidence }, set: { draft.confidence = $0 }),
            .string("entities", label: NSLocalizedString("相关实体（用逗号分隔）", comment: ""), get: { entities }, set: { entities = $0 }),
            .readOnly("source", label: NSLocalizedString("来源", comment: ""), value: { .string(draft.source.rawValue) })
        ]
        if original != nil {
            settings.append(.bool("archived", label: NSLocalizedString("已归档", comment: ""), get: { draft.isArchived }, set: { draft.isArchived = $0 }))
        }
        return settings
    }

    private func save(reembed: Bool = false) {
        guard !isSaving, !model.isWorking else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await model.save(draft, entitiesText: entities, replacing: original)
                if reembed { await model.reembed(draft) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

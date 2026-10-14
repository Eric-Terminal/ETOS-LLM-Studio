import ETOSCore
import SwiftUI

struct MacSkillEditorTarget: Identifiable {
    let id = UUID()
    let detail: SkillLibraryDetail?
    let file: SkillLibraryFile?
    let isManifest: Bool
    static func manifest(_ detail: SkillLibraryDetail?) -> Self { Self(detail: detail, file: nil, isManifest: true) }
    static func resource(_ detail: SkillLibraryDetail, file: SkillLibraryFile?) -> Self { Self(detail: detail, file: file, isManifest: false) }
}

struct MacSkillEditor: View {
    let target: MacSkillEditorTarget
    let isActive: Bool
    @ObservedObject var model: MacSkillsModel
    let saved: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var content: String
    @State private var epoch: UUID
    @State private var error: String?
    @State private var visible = false
    private var active: Bool { isActive && visible && epoch == model.epoch && model.canWrite }
    private var title: String {
        target.isManifest ? NSLocalizedString("编辑技能", comment: "") : (target.file?.id ?? NSLocalizedString("新建文件", comment: ""))
    }

    init(target: MacSkillEditorTarget, isActive: Bool, model: MacSkillsModel, saved: @escaping (String?) -> Void) {
        self.target = target; self.isActive = isActive; self.model = model; self.saved = saved
        _epoch = State(initialValue: model.epoch)
        _name = State(initialValue: target.isManifest ? target.detail?.metadata.name ?? "" : target.file?.id ?? "")
        _content = State(initialValue: target.isManifest ? target.detail?.content ?? "" : target.file?.editableContent ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MacSettingsIntroCard(id: "skill-editor-\(target.id)", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac Skills 使用说明", comment: ""), documentID: "agent-skills", isActive: isActive && epoch == model.epoch)
                    if target.isManifest {
                        TextField(NSLocalizedString("未声明 name 时使用的名称", comment: ""), text: $name)
                    } else if let file = target.file {
                        LabeledContent(NSLocalizedString("路径", comment: ""), value: file.id)
                    } else {
                        TextField(NSLocalizedString("例如 refs/checklist.md", comment: ""), text: $name)
                    }
                } footer: {
                    Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: $content).font(.system(.body, design: .monospaced)).frame(minHeight: 320)
                } header: { Text(NSLocalizedString("内容", comment: "")) }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .disabled(!active)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(model.isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }
                        .disabled(!active || (target.isManifest && content.isEmpty) || (!target.isManifest && name.isEmpty))
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-skill-editor-\(target.id)-\(epoch)"), title: title,
                documents: [GuideDocumentReference(id: "agent-skills", title: "Agent Skills")], isActive: active,
                settings: guideSettings
            )
        }
        .frame(minWidth: 600, minHeight: 520)
        .interactiveDismissDisabled(model.isWorking)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: model.epoch) { _, _ in dismiss() }
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("requires_save", label: NSLocalizedString("保存", comment: ""), value: { .bool(true) }),
            .readOnly("manifest", label: NSLocalizedString("SKILL.md 内容", comment: ""), value: { .bool(target.isManifest) }),
            .string("content", label: NSLocalizedString("内容", comment: ""), get: { content }, set: { content = $0 })
        ]
        if target.isManifest || target.file == nil {
            fields.append(.string(target.isManifest ? "fallback_name" : "path",
                                  label: target.isManifest ? NSLocalizedString("未声明 name 时使用的名称", comment: "") : NSLocalizedString("路径", comment: ""),
                                  get: { name }, set: { name = $0 }))
        } else {
            fields.append(.readOnly("path", label: NSLocalizedString("路径", comment: ""), value: { .string(name) }))
        }
        return fields
    }

    private func save() {
        guard active else { return }
        let mutation: SkillLibraryMutation
        if target.isManifest {
            mutation = .manifest(originalName: target.detail?.metadata.name, expectedVersion: target.detail?.versionDigest,
                                 content: content, fallbackName: name)
        } else if let detail = target.detail {
            mutation = .file(name: detail.metadata.name, expectedVersion: detail.versionDigest,
                             path: name, creating: target.file == nil, content: content)
        } else { return }
        Task {
            guard active else { return }
            do {
                let name = try await model.mutate(mutation, expectedEpoch: epoch)
                guard epoch == model.epoch, isActive, visible else { return }
                saved(name); dismiss()
            } catch { if epoch == model.epoch { self.error = error.localizedDescription } }
        }
    }
}

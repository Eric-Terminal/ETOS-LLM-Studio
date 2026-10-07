import ETOSCore
import SwiftUI

struct MacRoleplayContentList: View {
    @ObservedObject var model: MacRoleplayModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    let characterID: UUID
    let kind: MacRoleplayContentKind
    @State private var editingRegex: MacRoleplayRegexDraft?
    @State private var editingScript: MacRoleplayScriptDraft?
    @State private var deleting: DeletionTarget?
    @State private var preparationID = UUID()

    private struct DeletionTarget {
        let character: RoleplayCharacter
        let id: UUID
        let name: String
    }

    var body: some View {
        List {
            if let row = model.snapshot.charactersByID[characterID] {
                Section {
                    LabeledContent(NSLocalizedString("角色卡", comment: ""), value: row.character.name)
                    MacSettingsIntroCard(id: "roleplay-content-\(kind.rawValue)", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 角色正则与脚本使用说明", comment: ""), documentID: "roleplay")
                }
                if kind == .regex {
                    Section(NSLocalizedString("角色正则", comment: "")) {
                        Button(NSLocalizedString("新增正则", comment: "")) { edit(RoleplayRegexRule(), in: row.character) }
                        if row.content.regex.isEmpty {
                            Text(NSLocalizedString("暂无角色正则。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(row.content.regex) { item in
                            Button { edit(item.rule, in: row.character) } label: {
                                contentRow(item.title, preview: item.preview, enabled: !item.rule.disabled)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                                    deleting = DeletionTarget(character: row.character, id: item.id, name: item.title)
                                }
                            }
                        }
                        .onMove { move(in: row.character, from: $0, to: $1) }
                    }
                } else {
                    Section(NSLocalizedString("助手脚本", comment: "")) {
                        Button(NSLocalizedString("新增脚本", comment: "")) { edit(RoleplayHelperScript(name: "", content: ""), in: row.character) }
                        if row.content.scripts.isEmpty {
                            Text(NSLocalizedString("暂无助手脚本。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(row.content.scripts) { item in
                            Button { edit(item.script, in: row.character) } label: {
                                contentRow(item.title, preview: item.preview, enabled: item.script.enabled)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                                    deleting = DeletionTarget(character: row.character, id: item.id, name: item.title)
                                }
                            }
                        }
                        .onMove { move(in: row.character, from: $0, to: $1) }
                    }
                }
            } else {
                Text(NSLocalizedString("角色卡不存在或已被删除。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle(kind.title)
        .disabled(model.isWorking || workspace.isRestoringData)
        .sheet(item: $editingRegex) { MacRoleplayRegexEditor(model: model, draft: $0) }
        .sheet(item: $editingScript) { MacRoleplayScriptEditor(model: model, draft: $0) }
        .confirmationDialog(NSLocalizedString("删除", comment: ""), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let target = deleting else { return }
                deleting = nil
                Task {
                    do { try await model.deleteContent(target.id, kind: kind, in: target.character) }
                    catch { model.error = error.localizedDescription }
                }
            }
        } message: { Text(deleting?.name ?? "") }
        .onDisappear { preparationID = UUID() }
        .onChange(of: workspace.isRestoringData) { _, restoring in
            if restoring { preparationID = UUID(); editingRegex = nil; editingScript = nil; deleting = nil }
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-roleplay-content-\(characterID)-\(kind.rawValue)-\(deleting == nil ? "list" : "delete")"),
            title: kind.title, documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")], settings: [
                .readOnly("character_id", label: NSLocalizedString("角色卡", comment: ""), value: { .string(characterID.uuidString) }),
                .readOnly("items", label: kind.title, value: {
                    let content = model.snapshot.charactersByID[characterID]?.content
                    return (kind == .regex ? content?.regexGuideValue : content?.scriptsGuideValue) ?? .array([])
                }),
                .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(model.isWorking || workspace.isRestoringData) }),
                .readOnly("deleting_id", label: NSLocalizedString("删除", comment: ""), value: { .string(deleting?.id.uuidString ?? "") })
            ]
        )
    }

    private func contentRow(_ title: String, preview: String, enabled: Bool) -> some View {
        VStack(alignment: .leading) {
            Label(title, systemImage: enabled ? "checkmark.circle" : "pause.circle").foregroundStyle(.primary)
            if !preview.isEmpty { Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    private func edit(_ rule: RoleplayRegexRule, in character: RoleplayCharacter) {
        let id = UUID()
        preparationID = id
        Task {
            let draft = await Task.detached { MacRoleplayRegexDraft(rule: rule, in: character) }.value
            guard preparationID == id, !workspace.isRestoringData else { return }
            editingRegex = draft
        }
    }

    private func edit(_ script: RoleplayHelperScript, in character: RoleplayCharacter) {
        editingScript = MacRoleplayScriptDraft(script: script, in: character)
    }

    private func move(in character: RoleplayCharacter, from offsets: IndexSet, to destination: Int) {
        Task {
            do { try await model.moveContent(kind, in: character, from: offsets, to: destination) }
            catch { model.error = error.localizedDescription }
        }
    }
}

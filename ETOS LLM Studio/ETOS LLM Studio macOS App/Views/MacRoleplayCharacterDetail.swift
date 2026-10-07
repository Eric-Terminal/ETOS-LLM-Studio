import ETOSCore
import SwiftUI

struct MacRoleplayCharacterDetail: View {
    @ObservedObject var model: MacRoleplayModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    let characterID: UUID
    @State private var editing: MacRoleplayCharacterDraft?
    @State private var preparationID = UUID()

    var body: some View {
        Form {
            if let row = model.snapshot.charactersByID[characterID] {
                Section(NSLocalizedString("角色资料", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: ""), value: row.character.name)
                    LabeledContent(NSLocalizedString("作者", comment: ""), value: row.character.creator)
                    LabeledContent(NSLocalizedString("版本", comment: ""), value: row.character.characterVersion)
                    LabeledContent(NSLocalizedString("格式", comment: ""), value: row.format)
                    Button(NSLocalizedString("查看与编辑完整资料", comment: "")) { edit(row.character) }
                }
                Section(NSLocalizedString("角色描述", comment: "")) { Text(row.character.description).textSelection(.enabled) }
                Section(NSLocalizedString("首条消息", comment: "")) { Text(row.character.firstMessage).textSelection(.enabled) }
                Section(NSLocalizedString("兼容性报告", comment: "")) {
                    ForEach(row.character.compatibilityReport.items) { item in
                        VStack(alignment: .leading) {
                            Label(item.localizedTitle, systemImage: symbol(item.status))
                            if !item.localizedDetail.isEmpty { Text(item.localizedDetail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section(NSLocalizedString("内容", comment: "")) {
                    LabeledContent(NSLocalizedString("候选开场白", comment: ""), value: row.character.alternateGreetings.count.formatted())
                    NavigationLink(NSLocalizedString("角色正则", comment: "")) {
                        MacRoleplayContentList(model: model, characterID: characterID, kind: .regex)
                    }
                    NavigationLink(NSLocalizedString("助手脚本", comment: "")) {
                        MacRoleplayContentList(model: model, characterID: characterID, kind: .scripts)
                    }
                    LabeledContent(NSLocalizedString("资源文件", comment: ""), value: (row.character.assets?.count ?? 0).formatted())
                    if let id = row.character.embeddedWorldbookID {
                        NavigationLink(NSLocalizedString("内嵌世界书", comment: "")) { MacWorldbookDetailView(model: workspace.worldbookModel, bookID: id) }
                    }
                }
                MacSettingsIntroCard(id: "roleplay-character", title: NSLocalizedString("使用说明", comment: ""),
                                     details: NSLocalizedString("Mac 角色资料使用说明", comment: ""), documentID: "roleplay")
            } else {
                Text(NSLocalizedString("角色卡不存在或已被删除。", comment: "")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.snapshot.charactersByID[characterID]?.character.name ?? NSLocalizedString("角色卡", comment: ""))
        .disabled(model.isWorking || workspace.isRestoringData)
        .sheet(item: $editing) { MacRoleplayCharacterEditor(model: model, draft: $0) }
        .onDisappear { preparationID = UUID() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { preparationID = UUID(); editing = nil } }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-roleplay-character-\(characterID)"), title: NSLocalizedString("角色资料", comment: ""),
            documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")], settings: [
                .readOnly("character", label: NSLocalizedString("角色卡", comment: ""), value: { model.snapshot.charactersByID[characterID]?.guideValue ?? .null }),
                .readOnly("regex_requires_navigation", label: NSLocalizedString("角色正则", comment: ""), value: { .bool(true) }),
                .readOnly("scripts_require_navigation", label: NSLocalizedString("助手脚本", comment: ""), value: { .bool(true) })
            ]
        )
    }

    private func edit(_ character: RoleplayCharacter) {
        let id = UUID()
        preparationID = id
        Task {
            let draft = await Task.detached { MacRoleplayCharacterDraft(character: character) }.value
            guard preparationID == id, !workspace.isRestoringData else { return }
            editing = draft
        }
    }

    private func symbol(_ status: RoleplayCompatibilityStatus) -> String {
        switch status {
        case .supported: "checkmark.circle"
        case .partial: "exclamationmark.circle"
        case .unsupported: "xmark.circle"
        case .translated: "arrow.triangle.2.circlepath"
        }
    }
}

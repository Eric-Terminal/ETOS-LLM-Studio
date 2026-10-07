import AppKit
import ETOSCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MacRoleplayPersonaEditor: View {
    @ObservedObject var model: MacRoleplayModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var persona: PersonaProfile
    @State private var avatarData: Data?
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var preparingAvatar = false
    @State private var saving = false
    @State private var error: String?
    private let original: PersonaProfile?

    init(model: MacRoleplayModel, draft: MacRoleplayPersonaDraft) {
        self.model = model
        original = draft.original
        _persona = State(initialValue: draft.persona)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("身份", comment: "")) {
                    TextField(NSLocalizedString("名称", comment: ""), text: $persona.name)
                    TextField(NSLocalizedString("称谓或代词", comment: ""), text: $persona.pronouns)
                }
                Section(NSLocalizedString("头像", comment: "")) {
                    Button(NSLocalizedString("从文件选择", comment: "")) { importing = true }
                    PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                        Label(NSLocalizedString("从照片选择", comment: ""), systemImage: "photo.on.rectangle")
                    }
                    if avatarData != nil { Text(NSLocalizedString("已选择新头像", comment: "")).font(.caption).foregroundStyle(.secondary) }
                    else if persona.avatarFileName != nil { Text(NSLocalizedString("已设置头像", comment: "")).font(.caption).foregroundStyle(.secondary) }
                    if preparingAvatar { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                }
                Section(NSLocalizedString("角色扮演资料", comment: "")) {
                    TextEditor(text: $persona.description).frame(minHeight: 180).accessibilityLabel(NSLocalizedString("角色扮演资料", comment: ""))
                }
                Section {
                    MacSettingsIntroCard(id: "roleplay-persona", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 角色资料使用说明", comment: ""), documentID: "roleplay")
                } footer: { Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(saving || preparingAvatar || workspace.isRestoringData)
            .navigationTitle(NSLocalizedString("编辑用户身份", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(saving || preparingAvatar || persona.name.isEmpty || model.isWorking || workspace.isRestoringData)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                preparingAvatar = true
                Task {
                    defer { preparingAvatar = false }
                    do {
                        let url = try result.get()
                        let data = try await Task.detached {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            return try Data(contentsOf: url)
                        }.value
                        try await selectAvatar(data)
                    } catch { self.error = error.localizedDescription }
                }
            }
            .task(id: photo) {
                guard let photo else { return }
                preparingAvatar = true
                defer { preparingAvatar = false }
                do { if let data = try await photo.loadTransferable(type: Data.self) { try await selectAvatar(data) } }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                self.photo = nil
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-roleplay-persona-\(persona.id)"), title: NSLocalizedString("编辑用户身份", comment: ""),
                documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")], settings: [
                    .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) }),
                    .readOnly("has_avatar", label: NSLocalizedString("头像", comment: ""), value: { .bool(avatarData != nil || persona.avatarFileName != nil) })
                ] + (saving || preparingAvatar || workspace.isRestoringData ? [] : [
                    .string("name", label: NSLocalizedString("名称", comment: ""), allowsEmpty: false, get: { persona.name }, set: { persona.name = $0 }),
                    .string("pronouns", label: NSLocalizedString("称谓或代词", comment: ""), get: { persona.pronouns }, set: { persona.pronouns = $0 }),
                    .string("description", label: NSLocalizedString("角色扮演资料", comment: ""), get: { persona.description }, set: { persona.description = $0 })
                ])
            )
        }
        .modifier(MacGuideInspector())
        .interactiveDismissDisabled(saving)
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
        .frame(minWidth: 520, minHeight: 500)
    }

    private func selectAvatar(_ data: Data) async throws {
        let png = await Task.detached(priority: .userInitiated) { NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) }.value
        try Task.checkCancellation()
        guard let png else { throw MacRoleplayDraftError.invalidImage }
        avatarData = png
        error = nil
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do { try await model.save(persona, replacing: original, avatarData: avatarData); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

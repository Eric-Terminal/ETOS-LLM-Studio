import ETOSCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MacRoleplayLibraryView: View {
    private enum Library: String, CaseIterable { case characters, personas }
    @ObservedObject var model: MacRoleplayModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var library = Library.characters
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var editingCharacter: MacRoleplayCharacterDraft?
    @State private var editingPersona: MacRoleplayPersonaDraft?
    @State private var deletingCharacter: RoleplayCharacter?
    @State private var deletingPersona: PersonaProfile?
    @State private var preparationID = UUID()

    var body: some View {
        VStack {
            Picker(NSLocalizedString("角色扮演与酒馆兼容", comment: ""), selection: $library) {
                Text(NSLocalizedString("角色卡", comment: "")).tag(Library.characters)
                Text(NSLocalizedString("用户身份", comment: "")).tag(Library.personas)
            }.pickerStyle(.segmented).padding(.horizontal)
            List {
                Section {
                    MacSettingsIntroCard(id: "roleplay-library", title: NSLocalizedString("使用说明", comment: ""),
                                         details: NSLocalizedString("Mac 角色资料使用说明", comment: ""), documentID: "roleplay")
                }
                if library == .characters {
                    Section {
                        Button(NSLocalizedString("新增角色卡", comment: "")) { edit(RoleplayCharacter(name: "", sourceSpec: "chara_card_v2", sourceSpecVersion: "2.0"), isNew: true) }
                        Button(NSLocalizedString("从文件导入", comment: "")) { importing = true }
                        PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                            Label(NSLocalizedString("从照片选择", comment: ""), systemImage: "photo.on.rectangle")
                        }
                    }
                    Section(NSLocalizedString("角色卡", comment: "")) {
                        ForEach(model.snapshot.characters) { row in
                            NavigationLink {
                                MacRoleplayCharacterDetail(model: model, characterID: row.id)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(row.character.name)
                                    if !row.preview.isEmpty { Text(row.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                    if !row.format.isEmpty { Text(row.format).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .contextMenu {
                                Button(NSLocalizedString("编辑", comment: "")) { edit(row.character) }
                                Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletingCharacter = row.character }
                            }
                        }
                    }
                } else {
                    Section {
                        Button(NSLocalizedString("新增用户身份", comment: "")) { editingPersona = MacRoleplayPersonaDraft(persona: PersonaProfile(name: ""), isNew: true) }
                    }
                    Section(NSLocalizedString("用户身份", comment: "")) {
                        ForEach(model.snapshot.personas) { row in
                            Button { editingPersona = MacRoleplayPersonaDraft(persona: row.persona) } label: {
                                VStack(alignment: .leading) {
                                    Text(row.persona.name).foregroundStyle(.primary)
                                    if !row.preview.isEmpty { Text(row.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                }
                            }
                            .contextMenu { Button(NSLocalizedString("删除", comment: ""), role: .destructive) { deletingPersona = row.persona } }
                        }
                    }
                }
                if model.isLoading || model.isWorking { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .disabled(model.isWorking || workspace.isRestoringData)
        .searchable(text: $model.query, prompt: NSLocalizedString("搜索", comment: ""))
        .navigationTitle(NSLocalizedString("角色扮演与酒馆兼容", comment: ""))
        .sheet(item: $editingCharacter) { MacRoleplayCharacterEditor(model: model, draft: $0) }
        .sheet(item: $editingPersona) { MacRoleplayPersonaEditor(model: model, draft: $0) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .png, UTType(filenameExtension: "charx", conformingTo: .zip) ?? .zip]) { result in
            Task { do { try await model.importCard(result.get()) } catch { model.error = error.localizedDescription } }
        }
        .task(id: photo) {
            guard let photo else { return }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self), !Task.isCancelled else { return }
                try await model.importCard(data: data)
            } catch { if !Task.isCancelled { model.error = error.localizedDescription } }
            self.photo = nil
        }
        .confirmationDialog(NSLocalizedString("确认删除角色卡", comment: ""), isPresented: Binding(get: { deletingCharacter != nil }, set: { if !$0 { deletingCharacter = nil } })) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let original = deletingCharacter else { return }
                deletingCharacter = nil
                Task { do { try await model.delete(original) } catch { model.error = error.localizedDescription } }
            }
        }
        .confirmationDialog(NSLocalizedString("确认删除用户身份", comment: ""), isPresented: Binding(get: { deletingPersona != nil }, set: { if !$0 { deletingPersona = nil } })) {
            Button(NSLocalizedString("删除", comment: ""), role: .destructive) {
                guard let original = deletingPersona else { return }
                deletingPersona = nil
                Task { do { try await model.delete(original) } catch { model.error = error.localizedDescription } }
            }
        }
        .onDisappear { preparationID = UUID() }
        .onChange(of: workspace.isRestoringData) { _, restoring in
            if restoring { preparationID = UUID(); editingCharacter = nil; editingPersona = nil; deletingCharacter = nil; deletingPersona = nil }
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "mac-roleplay-library-\(library.rawValue)-\(deletingCharacter != nil || deletingPersona != nil ? "delete" : "list")"),
            title: NSLocalizedString("角色扮演与酒馆兼容", comment: ""), documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
            settings: [
                .readOnly("working", label: NSLocalizedString("状态", comment: ""), value: { .bool(model.isWorking) }),
                .readOnly("deleting_id", label: NSLocalizedString("删除", comment: ""), value: { .string(deletingCharacter?.id.uuidString ?? deletingPersona?.id.uuidString ?? "") })
            ] + (library == .characters ? [
                .readOnly("characters", label: NSLocalizedString("角色卡", comment: ""), value: { model.snapshot.characterGuideValue })
            ] : [
                .readOnly("personas", label: NSLocalizedString("用户身份", comment: ""), value: { model.snapshot.personaGuideValue })
            ])
        )
    }

    private func edit(_ character: RoleplayCharacter, isNew: Bool = false) {
        let id = UUID()
        preparationID = id
        Task {
            let draft = await Task.detached { MacRoleplayCharacterDraft(character: character, isNew: isNew) }.value
            guard preparationID == id, !workspace.isRestoringData else { return }
            editingCharacter = draft
        }
    }
}

struct MacRoleplayPersonaDraft: Identifiable {
    let original: PersonaProfile?
    let persona: PersonaProfile
    var id: UUID { persona.id }
    init(persona: PersonaProfile, isNew: Bool = false) { self.persona = persona; original = isNew ? nil : persona }
}

// ============================================================================
// RoleplaySettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理角色卡、Persona、会话绑定与 SillyTavern 兼容状态。
// ============================================================================

import ETOSCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum RoleplaySettingsTab: String {
    case session
    case characters
    case personas
}

struct RoleplaySettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @State private var selectedTab: RoleplaySettingsTab = .session

    var body: some View {
        TabView(selection: $selectedTab) {
            RoleplaySessionBindingView(
                currentSession: $viewModel.currentSession,
                isGuideActive: selectedTab == .session
            )
                .tabItem {
                    Label(NSLocalizedString("当前会话", comment: "Roleplay current session tab"), systemImage: "link")
                }
                .tag(RoleplaySettingsTab.session)

            RoleplayCharacterLibraryView(isGuideActive: selectedTab == .characters)
                .tabItem {
                    Label(NSLocalizedString("角色卡", comment: "Roleplay character cards tab"), systemImage: "person.crop.rectangle.stack")
                }
                .tag(RoleplaySettingsTab.characters)

            PersonaLibraryView(isGuideActive: selectedTab == .personas)
                .tabItem {
                    Label(NSLocalizedString("用户身份", comment: "Roleplay personas tab"), systemImage: "person.text.rectangle")
                }
                .tag(RoleplaySettingsTab.personas)
        }
        .navigationTitle(NSLocalizedString("角色扮演与酒馆兼容", comment: "Roleplay compatibility title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RoleplayCharacterLibraryView: View {
    let isGuideActive: Bool
    @State private var characters: [RoleplayCharacter] = []
    @State private var isImporting = false
    @State private var isSelectingCardPhoto = false
    @State private var selectedCardPhoto: PhotosPickerItem?
    @State private var importError: String?
    @State private var importedCharacter: RoleplayCharacter?
    @State private var characterToDelete: RoleplayCharacter?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading) {
                    Label(NSLocalizedString("SillyTavern 角色卡", comment: "Roleplay card intro title"), systemImage: "theatermasks")
                        .etFont(.headline)
                    Text(NSLocalizedString("导入 V2/V3 JSON 或 PNG 角色卡；内嵌世界书、角色正则、助手脚本和扩展字段会一起保留。", comment: "Roleplay card intro detail"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    RoleplayCharacterProfileEditorView(
                        character: RoleplayCharacter(
                            name: "",
                            sourceSpec: "chara_card_v2",
                            sourceSpecVersion: "2.0"
                        ),
                        isCreating: true
                    )
                } label: {
                    Label(NSLocalizedString("新增角色卡", comment: "Add character card"), systemImage: "person.badge.plus")
                }

                Menu {
                    Button {
                        isSelectingCardPhoto = true
                    } label: {
                        Label(NSLocalizedString("从照片选择", comment: "Choose roleplay card from Photos"), systemImage: "photo.on.rectangle")
                    }

                    Button {
                        isImporting = true
                    } label: {
                        Label(NSLocalizedString("从文件选择", comment: "Choose roleplay card from Files"), systemImage: "folder")
                    }
                } label: {
                    Label(NSLocalizedString("导入角色卡", comment: "Import roleplay card"), systemImage: "square.and.arrow.down")
                }
            }

            if let importError {
                Section(NSLocalizedString("导入错误", comment: "Import error section")) {
                    Text(importError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section(String(format: NSLocalizedString("角色卡 (%d)", comment: "Roleplay character count"), characters.count)) {
                if characters.isEmpty {
                    Text(NSLocalizedString("暂无角色卡。", comment: "No roleplay characters"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(characters) { character in
                        NavigationLink {
                            RoleplayCharacterDetailView(character: character)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(character.name)
                                    .etFont(.headline)
                                HStack {
                                    Text(String(format: NSLocalizedString("正则 %d", comment: "Roleplay regex count"), character.regexRules.count))
                                    Text(String(format: NSLocalizedString("脚本 %d", comment: "Roleplay script count"), character.helperScripts.count))
                                    if character.embeddedWorldbookID != nil {
                                        Text(NSLocalizedString("内嵌世界书", comment: "Embedded lorebook badge"))
                                    }
                                }
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                characterToDelete = character
                            } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("角色卡", comment: "Roleplay character cards title"))
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json, .png, UTType(filenameExtension: "charx", conformingTo: .zip) ?? .zip],
            allowsMultipleSelection: false,
            onCompletion: importCard
        )
        .photosPicker(
            isPresented: $isSelectingCardPhoto,
            selection: $selectedCardPhoto,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: selectedCardPhoto) { _, photo in
            guard let photo else { return }
            importCard(from: photo)
        }
        .alert(
            NSLocalizedString("角色卡导入完成", comment: "Roleplay card import complete"),
            isPresented: Binding(
                get: { importedCharacter != nil },
                set: { if !$0 { importedCharacter = nil } }
            )
        ) {
            Button(NSLocalizedString("好的", comment: "OK")) {}
        } message: {
            if let character = importedCharacter {
                Text(String(
                    format: NSLocalizedString("已导入“%@”：%d 条角色正则，%d 个助手脚本。", comment: "Roleplay card import summary"),
                    character.name,
                    character.regexRules.count,
                    character.helperScripts.count
                ))
            }
        }
        .confirmationDialog(
            NSLocalizedString("确认删除角色卡", comment: "Delete roleplay card confirmation"),
            isPresented: Binding(
                get: { characterToDelete != nil },
                set: { if !$0 { characterToDelete = nil } }
            )
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                if let characterToDelete {
                    ChatService.shared.deleteRoleplayCharacter(id: characterToDelete.id)
                    self.characterToDelete = nil
                    reload()
                }
            }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            reload()
        }
        .guideSettingsPageContext(
            id: "settings-roleplay-characters",
            title: NSLocalizedString("角色卡", comment: "角色卡向导标题"),
            documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
            isActive: isGuideActive,
            settings: [
                .readOnly("characters", label: NSLocalizedString("已安装角色卡", comment: "角色卡向导字段"), value: {
                    .array(characters.map { character in
                        .dictionary([
                            "id": .string(character.id.uuidString),
                            "name": .string(character.name),
                            "creator": .string(character.creator),
                            "format": .string([character.sourceSpec, character.sourceSpecVersion].compactMap { $0 }.joined(separator: " ")),
                            "regex_rule_count": .int(character.regexRules.count),
                            "helper_script_count": .int(character.helperScripts.count),
                            "has_embedded_worldbook": .bool(character.embeddedWorldbookID != nil)
                        ])
                    })
                })
            ]
        )
    }

    private func reload() {
        Task {
            characters = await Task.detached(priority: .utility) {
                ChatService.shared.loadRoleplayCharacters().sorted { $0.updatedAt > $1.updatedAt }
            }.value
        }
    }

    private func importCard(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        let hasAccess = url.startAccessingSecurityScopedResource()
        Task {
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                try await importCard(data: data, fileName: url.lastPathComponent)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importCard(from photo: PhotosPickerItem) {
        Task {
            defer { selectedCardPhoto = nil }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    importError = NSLocalizedString("无法读取图片数据。", comment: "Unable to read roleplay card image data")
                    return
                }
                let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                guard data.starts(with: pngSignature) else {
                    importError = NSLocalizedString("请选择 PNG 格式的角色卡图片。", comment: "Roleplay card photo must be PNG")
                    return
                }
                try await importCard(data: data, fileName: "photo-library-card.png")
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importCard(data: Data, fileName: String) async throws {
        let imported = try await Task.detached(priority: .userInitiated) {
            try ChatService.shared.importRoleplayCard(data: data, fileName: fileName)
        }.value
        importError = nil
        importedCharacter = imported.character
        reload()
    }
}

private struct RoleplayCharacterDetailView: View {
    @State private var character: RoleplayCharacter
    @State private var isCreatingEmbeddedWorldbook = false

    init(character: RoleplayCharacter) {
        self._character = State(initialValue: character)
    }

    var body: some View {
        List {
            Section(NSLocalizedString("角色资料", comment: "Roleplay character details section")) {
                detail(NSLocalizedString("名称", comment: "Name"), character.name)
                detail(NSLocalizedString("作者", comment: "Creator"), character.creator)
                detail(NSLocalizedString("版本", comment: "Version"), character.characterVersion)
                detail(NSLocalizedString("格式", comment: "Format"), [character.sourceSpec, character.sourceSpecVersion].compactMap { $0 }.joined(separator: " "))
                NavigationLink {
                    RoleplayCharacterProfileEditorView(character: character)
                } label: {
                    Label(NSLocalizedString("查看与编辑完整资料", comment: "View and edit complete character profile"), systemImage: "square.and.pencil")
                }
            }

            Section(NSLocalizedString("角色定义", comment: "Character definition section")) {
                preview(NSLocalizedString("角色描述", comment: "Character description"), character.description)
                preview(NSLocalizedString("性格摘要", comment: "Character personality summary"), character.personality)
                preview(NSLocalizedString("场景", comment: "Character scenario"), character.scenario)
            }

            Section(NSLocalizedString("对话资料", comment: "Character conversation data")) {
                preview(NSLocalizedString("首条消息", comment: "Character first message"), character.firstMessage)
                detail(NSLocalizedString("候选开场白", comment: "Alternate greetings"), "\(character.alternateGreetings.count)")
                preview(NSLocalizedString("示例对话", comment: "Character example messages"), character.messageExamples)
            }

            Section(NSLocalizedString("提示词覆盖", comment: "Character prompt overrides")) {
                preview(NSLocalizedString("系统提示词", comment: "Character system prompt"), character.systemPrompt)
                preview(NSLocalizedString("历史后指令", comment: "Character post-history instructions"), character.postHistoryInstructions)
            }

            Section(NSLocalizedString("创作者资料", comment: "Character creator metadata")) {
                preview(NSLocalizedString("创作者备注", comment: "Character creator notes"), character.creatorNotes)
                detail(NSLocalizedString("标签", comment: "Tags"), "\(character.tags.count)")
            }

            Section(NSLocalizedString("兼容性报告", comment: "Roleplay compatibility report")) {
                ForEach(character.compatibilityReport.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                        Text(item.localizedTitle)
                    if !item.localizedDetail.isEmpty {
                        Text(item.localizedDetail)
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: statusIcon(item.status))
                            .foregroundStyle(statusColor(item.status))
                    }
                }
            }

            Section(NSLocalizedString("内容", comment: "Content section")) {
                NavigationLink {
                    RoleplayRegexRulesView(characterID: character.id)
                } label: {
                    detail(NSLocalizedString("角色正则", comment: "Roleplay character regex"), "\(character.regexRules.count)")
                }
                NavigationLink {
                    RoleplayHelperScriptsView(characterID: character.id)
                } label: {
                    detail(NSLocalizedString("助手脚本", comment: "Roleplay helper scripts"), "\(character.helperScripts.count)")
                }
                if let worldbookID = character.embeddedWorldbookID {
                    NavigationLink {
                        WorldbookDetailView(worldbookID: worldbookID)
                    } label: {
                        detail(NSLocalizedString("内嵌世界书", comment: "Embedded lorebook"), NSLocalizedString("编辑", comment: "Edit"))
                    }
                } else {
                    Button {
                        createEmbeddedWorldbook()
                    } label: {
                        Label(NSLocalizedString("创建内嵌世界书", comment: "Create embedded lorebook"), systemImage: "books.vertical.fill")
                    }
                    .disabled(isCreatingEmbeddedWorldbook)
                }
                detail(NSLocalizedString("初始变量", comment: "Roleplay initial variables"), "\(character.initialVariables.count)")
                detail(NSLocalizedString("可选开场白", comment: "Available greetings"), "\(availableGreetingCount)")
                detail(NSLocalizedString("资源文件", comment: "Character asset files"), "\(character.assets?.count ?? 0)")
                detail(NSLocalizedString("扩展字段", comment: "Character extension fields"), "\(character.extensions.count)")
            }
        }
        .navigationTitle(character.name)
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            reload()
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "roleplay-character-\(character.id.uuidString.lowercased())"),
            title: String(format: NSLocalizedString("角色卡：%@", comment: "角色卡详情向导标题"), character.name),
            documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
            settings: [
                .readOnly("id", label: NSLocalizedString("角色卡 ID", comment: "角色卡详情向导字段"), value: { .string(character.id.uuidString) }),
                .readOnly("name", label: NSLocalizedString("名称", comment: "角色卡详情向导字段"), value: { .string(character.name) }),
                .readOnly("creator", label: NSLocalizedString("作者", comment: "角色卡详情向导字段"), value: { .string(character.creator) }),
                .readOnly("format", label: NSLocalizedString("格式", comment: "角色卡详情向导字段"), value: { .string([character.sourceSpec, character.sourceSpecVersion].compactMap { $0 }.joined(separator: " ")) }),
                .readOnly("content_summary", label: NSLocalizedString("内容结构", comment: "角色卡详情向导字段"), value: {
                    .dictionary([
                        "description_characters": .int(character.description.count),
                        "personality_characters": .int(character.personality.count),
                        "scenario_characters": .int(character.scenario.count),
                        "alternate_greeting_count": .int(character.alternateGreetings.count),
                        "regex_rule_count": .int(character.regexRules.count),
                        "helper_script_count": .int(character.helperScripts.count),
                        "initial_variable_count": .int(character.initialVariables.count),
                        "asset_count": .int(character.assets?.count ?? 0),
                        "extension_field_count": .int(character.extensions.count),
                        "embedded_worldbook_id": .string(character.embeddedWorldbookID?.uuidString ?? "")
                    ])
                })
            ]
        )
    }

    private func detail(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func preview(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .etFont(.subheadline)
            Text(value.isEmpty ? NSLocalizedString("未填写", comment: "Empty character field") : value)
                .etFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private func statusIcon(_ status: RoleplayCompatibilityStatus) -> String {
        switch status {
        case .supported: return "checkmark.circle.fill"
        case .translated: return "arrow.triangle.2.circlepath.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .unsupported: return "xmark.circle.fill"
        }
    }

    private func statusColor(_ status: RoleplayCompatibilityStatus) -> Color {
        switch status {
        case .supported: return .green
        case .translated: return .blue
        case .partial: return .orange
        case .unsupported: return .red
        }
    }

    private var availableGreetingCount: Int {
        character.alternateGreetings.count + (character.firstMessage.isEmpty ? 0 : 1)
    }

    private func reload() {
        let characterID = character.id
        Task {
            if let updated = await Task.detached(priority: .utility, operation: {
                ChatService.shared.loadRoleplayCharacters().first { $0.id == characterID }
            }).value {
                character = updated
            }
        }
    }

    private func createEmbeddedWorldbook() {
        guard !isCreatingEmbeddedWorldbook else { return }
        isCreatingEmbeddedWorldbook = true
        let characterID = character.id
        let worldbookName = String(
            format: NSLocalizedString("%@ 的世界书", comment: "Default embedded lorebook name"),
            character.name
        )
        Task {
            await Task.detached(priority: .utility) {
                let worldbook = Worldbook(name: worldbookName, entries: [])
                ChatService.shared.saveWorldbook(worldbook)
                guard var updated = ChatService.shared.loadRoleplayCharacters().first(where: { $0.id == characterID }) else { return }
                updated.embeddedWorldbookID = worldbook.id
                ChatService.shared.saveRoleplayCharacter(updated)
            }.value
            isCreatingEmbeddedWorldbook = false
            reload()
        }
    }
}

private struct PersonaLibraryView: View {
    let isGuideActive: Bool
    @State private var personas: [PersonaProfile] = []
    @State private var editingPersona: PersonaProfile?
    @State private var personaToDelete: PersonaProfile?

    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("Persona 表示一场角色扮演中的用户身份，与现实用户资料和长期记忆相互独立。", comment: "Persona explanation"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    editingPersona = PersonaProfile(name: "")
                } label: {
                    Label(NSLocalizedString("新增用户身份", comment: "Add persona"), systemImage: "person.badge.plus")
                }
            }
            Section(String(format: NSLocalizedString("用户身份 (%d)", comment: "Persona count"), personas.count)) {
                if personas.isEmpty {
                    Text(NSLocalizedString("暂无用户身份。", comment: "No personas"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(personas) { persona in
                        Button {
                            editingPersona = persona
                        } label: {
                            VStack(alignment: .leading) {
                                Text(persona.name)
                                    .foregroundStyle(.primary)
                                if !persona.description.isEmpty {
                                    Text(persona.description)
                                        .etFont(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { personaToDelete = persona } label: {
                                Label(NSLocalizedString("删除", comment: "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("用户身份", comment: "Persona title"))
        .sheet(item: $editingPersona) { persona in
            PersonaEditorView(persona: persona) { persona, avatarData in
                Task {
                    _ = await Task.detached(priority: .utility) {
                        ChatService.shared.savePersonaProfile(persona, avatarData: avatarData)
                    }.value
                    editingPersona = nil
                    reload()
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("确认删除用户身份", comment: "Delete persona confirmation"),
            isPresented: Binding(
                get: { personaToDelete != nil },
                set: { if !$0 { personaToDelete = nil } }
            )
        ) {
            Button(NSLocalizedString("删除", comment: "Delete"), role: .destructive) {
                if let personaToDelete {
                    ChatService.shared.deletePersonaProfile(id: personaToDelete.id)
                    self.personaToDelete = nil
                    reload()
                }
            }
        }
        .task { reload() }
        .guideSettingsPageContext(
            id: "settings-roleplay-personas",
            title: NSLocalizedString("用户身份", comment: "用户身份向导标题"),
            documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
            isActive: isGuideActive,
            settings: [
                .readOnly("personas", label: NSLocalizedString("可用用户身份", comment: "用户身份向导字段"), value: {
                    .array(personas.map { persona in
                        .dictionary([
                            "id": .string(persona.id.uuidString),
                            "name": .string(persona.name),
                            "description": .string(persona.description)
                        ])
                    })
                })
            ]
        )
    }

    private func reload() {
        Task {
            personas = await Task.detached(priority: .utility) {
                ChatService.shared.loadPersonaProfiles().sorted { $0.updatedAt > $1.updatedAt }
            }.value
        }
    }
}

private struct PersonaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var persona: PersonaProfile
    @State private var avatarData: Data?
    @State private var isImportingAvatar = false
    @State private var isSelectingAvatarPhoto = false
    @State private var selectedAvatarPhoto: PhotosPickerItem?
    @State private var avatarError: String?
    let onSave: (PersonaProfile, Data?) -> Void

    init(persona: PersonaProfile, onSave: @escaping (PersonaProfile, Data?) -> Void) {
        self._persona = State(initialValue: persona)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("身份", comment: "Persona identity section")) {
                    TextField(NSLocalizedString("名称", comment: "Name"), text: $persona.name)
                    TextField(NSLocalizedString("称谓或代词", comment: "Pronouns"), text: $persona.pronouns)
                }
                Section(NSLocalizedString("头像", comment: "Persona avatar section")) {
                    Menu {
                        Button {
                            isSelectingAvatarPhoto = true
                        } label: {
                            Label(NSLocalizedString("从照片选择", comment: "Choose persona avatar from Photos"), systemImage: "photo.on.rectangle")
                        }

                        Button {
                            isImportingAvatar = true
                        } label: {
                            Label(NSLocalizedString("从文件选择", comment: "Choose persona avatar from Files"), systemImage: "folder")
                        }
                    } label: {
                        Label(NSLocalizedString("选择头像", comment: "Choose persona avatar"), systemImage: "person.crop.circle.badge.plus")
                    }
                    if avatarData != nil {
                        Label(NSLocalizedString("已选择新头像", comment: "New persona avatar selected"), systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else if persona.avatarFileName != nil {
                        Label(NSLocalizedString("已设置头像", comment: "Persona avatar configured"), systemImage: "person.crop.circle")
                            .foregroundStyle(.secondary)
                    }
                    if let avatarError {
                        Text(avatarError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section(NSLocalizedString("角色扮演资料", comment: "Persona roleplay profile section")) {
                    TextEditor(text: $persona.description)
                        .frame(minHeight: 140)
                }
            }
            .navigationTitle(NSLocalizedString("编辑用户身份", comment: "Edit persona"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "Save")) {
                        onSave(persona, avatarData)
                        dismiss()
                    }
                    .disabled(persona.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(
                isPresented: $isImportingAvatar,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else {
                    if case .failure(let error) = result { avatarError = error.localizedDescription }
                    return
                }
                let hasAccess = url.startAccessingSecurityScopedResource()
                Task {
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
                        await selectAvatar(data: data)
                    } catch {
                        avatarError = error.localizedDescription
                    }
                }
            }
            .photosPicker(
                isPresented: $isSelectingAvatarPhoto,
                selection: $selectedAvatarPhoto,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: selectedAvatarPhoto) { _, photo in
                guard let photo else { return }
                importAvatar(from: photo)
            }
        }
    }

    private func importAvatar(from photo: PhotosPickerItem) {
        Task {
            defer { selectedAvatarPhoto = nil }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    avatarError = NSLocalizedString("无法读取图片数据。", comment: "Unable to read persona avatar image data")
                    return
                }
                await selectAvatar(data: data)
            } catch {
                avatarError = error.localizedDescription
            }
        }
    }

    private func selectAvatar(data: Data) async {
        let pngData = await Task.detached(priority: .utility) {
            UIImage(data: data)?.pngData()
        }.value
        guard let pngData else {
            avatarError = NSLocalizedString("无法解析图片。", comment: "Unable to decode persona avatar image")
            return
        }
        avatarData = pngData
        avatarError = nil
    }
}

private struct RoleplaySessionBindingView: View {
    @Binding var currentSession: ChatSession?
    let isGuideActive: Bool

    @State private var characters: [RoleplayCharacter] = []
    @State private var personas: [PersonaProfile] = []
    @State private var selectedCharacterID: UUID?
    @State private var selectedPersonaID: UUID?
    @State private var selectedGreetingIndex = 0
    @State private var greetingOptions: [GreetingOption] = []
    @State private var selectedGreetingPreview: String?
    @State private var htmlRenderingEnabled = true
    @State private var helperScriptsEnabled = true

    var body: some View {
        Form {
            if currentSession == nil {
                ContentUnavailableView(
                    NSLocalizedString("没有当前会话", comment: "No current roleplay session"),
                    systemImage: "bubble.left.and.exclamationmark.bubble.right"
                )
            } else {
                Section(NSLocalizedString("角色与用户身份", comment: "Roleplay character and persona section")) {
                    Picker(NSLocalizedString("角色卡", comment: "Roleplay character card"), selection: selectedCharacterBinding) {
                        Text(NSLocalizedString("未绑定", comment: "Not bound")).tag(UUID?.none)
                        ForEach(characters) { character in
                            Text(character.name).tag(Optional(character.id))
                        }
                    }

                    Picker(NSLocalizedString("用户身份", comment: "Roleplay persona"), selection: selectedPersonaBinding) {
                        Text(NSLocalizedString("默认用户", comment: "Default user persona")).tag(UUID?.none)
                        ForEach(personas) { persona in
                            Text(persona.name).tag(Optional(persona.id))
                        }
                    }
                }

                Section {
                    Toggle(
                        NSLocalizedString("屏蔽记忆", comment: "Block memory for current session"),
                        isOn: Binding(
                            get: { currentSession?.memoryContextIsolationEnabled ?? false },
                            set: { updateContextIsolation(\.memoryContextIsolationEnabled, isEnabled: $0) }
                        )
                    )

                    Toggle(
                        NSLocalizedString("屏蔽工具", comment: "Block tools for current session"),
                        isOn: Binding(
                            get: { currentSession?.toolContextIsolationEnabled ?? false },
                            set: { updateContextIsolation(\.toolContextIsolationEnabled, isEnabled: $0) }
                        )
                    )

                    Toggle(
                        NSLocalizedString("屏蔽全局系统提示词", comment: "Block global system prompt for current session"),
                        isOn: Binding(
                            get: { currentSession?.globalSystemPromptIsolationEnabled ?? false },
                            set: { updateContextIsolation(\.globalSystemPromptIsolationEnabled, isEnabled: $0) }
                        )
                    )
                } footer: {
                    Text(NSLocalizedString("分别控制当前会话是否发送记忆、工具和全局系统提示词。角色卡、会话提示词与世界书不受影响。", comment: "Independent session context isolation description"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !greetingOptions.isEmpty {
                    Section(NSLocalizedString("开场白", comment: "Roleplay greeting section")) {
                        Picker(NSLocalizedString("候选开场白", comment: "Alternate greeting picker"), selection: selectedGreetingBinding) {
                            ForEach(greetingOptions) { option in
                                Text(String(format: NSLocalizedString("开场白 %d", comment: "Greeting number"), option.number))
                                    .tag(option.index)
                            }
                        }

                        if let selectedGreetingPreview {
                            Text(selectedGreetingPreview)
                                .etFont(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(5)
                        }
                    }
                }

                Section {
                    Toggle(NSLocalizedString("自动渲染 HTML", comment: "Auto-render roleplay HTML"), isOn: $htmlRenderingEnabled)
                        .onChange(of: htmlRenderingEnabled) { _, _ in persist() }
                    Toggle(NSLocalizedString("启用助手脚本", comment: "Enable roleplay helper scripts"), isOn: $helperScriptsEnabled)
                        .onChange(of: helperScriptsEnabled) { _, _ in persist() }
                } header: {
                    Text(NSLocalizedString("酒馆兼容", comment: "Tavern compatibility section"))
                } footer: {
                    Text(NSLocalizedString("角色正则、宏和 MVU 始终按角色卡运行；这里控制 HTML 与助手脚本承载。", comment: "Roleplay compatibility controls footer"))
                }

                Section {
                    if let sessionID = currentSession?.id {
                        NavigationLink {
                            RoleplayDataSettingsView(sessionID: sessionID)
                        } label: {
                            Label(NSLocalizedString("宏与变量", comment: "Roleplay macros and variables"), systemImage: "curlybraces.square")
                        }
                    }

                    NavigationLink {
                        WorldbookSettingsView()
                    } label: {
                        Label(NSLocalizedString("管理与绑定世界书", comment: "Manage roleplay lorebooks"), systemImage: "books.vertical")
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("当前会话", comment: "Roleplay current session title"))
        .task { load() }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            load()
        }
        .guideSettingsPageContext(
            id: "settings-roleplay-session",
            title: NSLocalizedString("当前会话角色扮演", comment: "角色扮演会话向导标题"),
            documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
            isActive: isGuideActive,
            settings: guideSettings
        )
    }

    private var guideSettings: [GuidePageSetting] {
        guard let session = currentSession else {
            return [.readOnly("has_current_session", label: NSLocalizedString("存在当前会话", comment: "角色扮演向导字段"), value: { .bool(false) })]
        }
        return [
            .readOnly("session_id", label: NSLocalizedString("会话 ID", comment: "角色扮演向导字段"), value: { .string(session.id.uuidString) }),
            .string(
                "character_id",
                label: NSLocalizedString("绑定角色卡", comment: "角色扮演向导字段"),
                allowedValues: [""] + characters.map { $0.id.uuidString },
                get: { selectedCharacterID?.uuidString ?? "" },
                set: { rawValue in selectedCharacterBinding.wrappedValue = UUID(uuidString: rawValue) }
            ),
            .string(
                "persona_id",
                label: NSLocalizedString("绑定用户身份", comment: "角色扮演向导字段"),
                allowedValues: [""] + personas.map { $0.id.uuidString },
                get: { selectedPersonaID?.uuidString ?? "" },
                set: { rawValue in selectedPersonaBinding.wrappedValue = UUID(uuidString: rawValue) }
            ),
            .integer(
                "greeting_index",
                label: NSLocalizedString("开场白索引", comment: "角色扮演向导字段"),
                range: 0...max(0, greetingOptions.map(\.index).max() ?? 0),
                get: { selectedGreetingIndex },
                set: { selectedGreetingBinding.wrappedValue = $0 }
            ),
            .bool("html_rendering_enabled", label: NSLocalizedString("自动渲染 HTML", comment: "角色扮演向导字段"), get: { htmlRenderingEnabled }, set: { htmlRenderingEnabled = $0; persist() }),
            .bool("helper_scripts_enabled", label: NSLocalizedString("启用助手脚本", comment: "角色扮演向导字段"), get: { helperScriptsEnabled }, set: { helperScriptsEnabled = $0; persist() }),
            .bool("isolate_memory", label: NSLocalizedString("屏蔽记忆", comment: "角色扮演向导字段"), get: { currentSession?.memoryContextIsolationEnabled ?? false }, set: { updateContextIsolation(\.memoryContextIsolationEnabled, isEnabled: $0) }),
            .bool("isolate_tools", label: NSLocalizedString("屏蔽工具", comment: "角色扮演向导字段"), get: { currentSession?.toolContextIsolationEnabled ?? false }, set: { updateContextIsolation(\.toolContextIsolationEnabled, isEnabled: $0) }),
            .bool("isolate_global_system_prompt", label: NSLocalizedString("屏蔽全局系统提示词", comment: "角色扮演向导字段"), get: { currentSession?.globalSystemPromptIsolationEnabled ?? false }, set: { updateContextIsolation(\.globalSystemPromptIsolationEnabled, isEnabled: $0) }),
            .readOnly("available_characters", label: NSLocalizedString("可用角色卡", comment: "角色扮演向导字段"), value: {
                .array(characters.map { .dictionary(["id": .string($0.id.uuidString), "name": .string($0.name)]) })
            }),
            .readOnly("available_personas", label: NSLocalizedString("可用用户身份", comment: "角色扮演向导字段"), value: {
                .array(personas.map { .dictionary(["id": .string($0.id.uuidString), "name": .string($0.name)]) })
            }),
            .readOnly("available_greetings", label: NSLocalizedString("可用开场白", comment: "角色扮演向导字段"), value: {
                .array(greetingOptions.map { .dictionary(["index": .int($0.index), "preview": .string($0.text)]) })
            })
        ]
    }

    private struct GreetingOption: Identifiable {
        let index: Int
        let number: Int
        let text: String
        var id: Int { index }
    }

    private var selectedCharacterBinding: Binding<UUID?> {
        Binding(
            get: { selectedCharacterID },
            set: { characterID in
                selectedCharacterID = characterID
                updateGreetingOptions(for: characterID, preferredIndex: nil)
                persist(seedGreeting: true)
            }
        )
    }

    private var selectedPersonaBinding: Binding<UUID?> {
        Binding(
            get: { selectedPersonaID },
            set: { personaID in
                selectedPersonaID = personaID
                ChatService.shared.setPreferredRoleplayPersonaID(personaID)
                persist()
            }
        )
    }

    private var selectedGreetingBinding: Binding<Int> {
        Binding(
            get: { selectedGreetingIndex },
            set: { greetingIndex in
                selectedGreetingIndex = greetingIndex
                selectedGreetingPreview = greetingOptions.first { $0.index == greetingIndex }?.text
                persist(seedGreeting: true)
            }
        )
    }

    private func updateGreetingOptions(for characterID: UUID?, preferredIndex: Int?) {
        guard let characterID,
              let character = characters.first(where: { $0.id == characterID }) else {
            greetingOptions = []
            selectedGreetingIndex = 0
            selectedGreetingPreview = nil
            return
        }
        let available = ([character.firstMessage] + character.alternateGreetings).enumerated().compactMap { index, text -> (Int, String)? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (index, trimmed)
        }
        greetingOptions = available.enumerated().map { displayIndex, item in
            GreetingOption(index: item.0, number: displayIndex + 1, text: item.1)
        }
        let availableIndices = Set(greetingOptions.map(\.index))
        selectedGreetingIndex = preferredIndex.flatMap { availableIndices.contains($0) ? $0 : nil }
            ?? greetingOptions.first?.index
            ?? 0
        selectedGreetingPreview = greetingOptions.first { $0.index == selectedGreetingIndex }?.text
    }

    private func load() {
        Task {
            let loaded = await Task.detached(priority: .utility) {
                (
                    ChatService.shared.loadRoleplayCharacters(),
                    ChatService.shared.loadPersonaProfiles()
                )
            }.value
            characters = loaded.0
            personas = loaded.1
            loadBinding()
        }
    }

    private func loadBinding() {
        guard let sessionID = currentSession?.id,
              let binding = ChatService.shared.roleplayBinding(sessionID: sessionID) else {
            selectedCharacterID = nil
            selectedPersonaID = ChatService.shared.preferredRoleplayPersonaID()
            selectedGreetingIndex = 0
            htmlRenderingEnabled = true
            helperScriptsEnabled = true
            updateGreetingOptions(for: nil, preferredIndex: nil)
            return
        }
        selectedCharacterID = binding.characterIDs.first
        selectedPersonaID = binding.personaID
        updateGreetingOptions(for: selectedCharacterID, preferredIndex: binding.selectedGreetingIndex)
        htmlRenderingEnabled = binding.htmlRenderingEnabled
        helperScriptsEnabled = binding.helperScriptsEnabled
    }

    private func persist(seedGreeting: Bool = false) {
        guard let sessionID = currentSession?.id else { return }
        let characterIDs = selectedCharacterID.map { [$0] } ?? []
        let additionalWorldbookIDs = ChatService.shared
            .roleplayBinding(sessionID: sessionID)?
            .additionalWorldbookIDs ?? []
        // 未绑定角色时仍保留非默认承载设置；恢复默认后才移除空绑定。
        guard !characterIDs.isEmpty
                || selectedPersonaID != nil
                || !additionalWorldbookIDs.isEmpty
                || !htmlRenderingEnabled
                || !helperScriptsEnabled else {
            ChatService.shared.unbindRoleplay(sessionID: sessionID)
            return
        }
        ChatService.shared.bindRoleplay(
            sessionID: sessionID,
            characterIDs: characterIDs,
            personaID: selectedPersonaID,
            additionalWorldbookIDs: additionalWorldbookIDs,
            selectedGreetingIndex: selectedGreetingIndex,
            htmlRenderingEnabled: htmlRenderingEnabled,
            helperScriptsEnabled: helperScriptsEnabled,
            seedGreetingIfEmpty: seedGreeting
        )
    }

    private func updateContextIsolation(
        _ keyPath: WritableKeyPath<ChatSession, Bool>,
        isEnabled: Bool
    ) {
        guard var session = currentSession else { return }
        session[keyPath: keyPath] = isEnabled
        currentSession = session
        ChatService.shared.updateWorldbookSessionSettings(
            sessionID: session.id,
            worldbookIDs: session.lorebookIDs,
            memoryContextIsolationEnabled: session.memoryContextIsolationEnabled,
            toolContextIsolationEnabled: session.toolContextIsolationEnabled,
            globalSystemPromptIsolationEnabled: session.globalSystemPromptIsolationEnabled
        )
    }
}

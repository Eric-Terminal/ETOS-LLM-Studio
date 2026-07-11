// ============================================================================
// RoleplaySettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理角色卡、Persona、会话绑定与 SillyTavern 兼容状态。
// ============================================================================

import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct RoleplaySettingsView: View {
    @EnvironmentObject private var viewModel: ChatViewModel

    var body: some View {
        TabView {
            NavigationStack {
                RoleplayCharacterLibraryView()
            }
            .tabItem {
                Label(NSLocalizedString("角色卡", comment: "Roleplay character cards tab"), systemImage: "person.crop.rectangle.stack")
            }

            NavigationStack {
                PersonaLibraryView()
            }
            .tabItem {
                Label(NSLocalizedString("用户身份", comment: "Roleplay personas tab"), systemImage: "person.text.rectangle")
            }

            NavigationStack {
                RoleplaySessionBindingView(currentSession: $viewModel.currentSession)
            }
            .tabItem {
                Label(NSLocalizedString("当前会话", comment: "Roleplay current session tab"), systemImage: "link")
            }
        }
        .navigationTitle(NSLocalizedString("角色扮演与酒馆兼容", comment: "Roleplay compatibility title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RoleplayCharacterLibraryView: View {
    @State private var characters: [RoleplayCharacter] = []
    @State private var isImporting = false
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

            Section(NSLocalizedString("导入", comment: "Import section")) {
                Button {
                    isImporting = true
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
            allowedContentTypes: [.json, .png],
            allowsMultipleSelection: false,
            onCompletion: importCard
        )
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
                let imported = try await Task.detached(priority: .userInitiated) {
                    try ChatService.shared.importRoleplayCard(data: data, fileName: url.lastPathComponent)
                }.value
                importError = nil
                importedCharacter = imported.character
                reload()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

private struct RoleplayCharacterDetailView: View {
    let character: RoleplayCharacter

    var body: some View {
        List {
            Section(NSLocalizedString("角色资料", comment: "Roleplay character details section")) {
                detail(NSLocalizedString("名称", comment: "Name"), character.name)
                detail(NSLocalizedString("作者", comment: "Creator"), character.creator)
                detail(NSLocalizedString("版本", comment: "Version"), character.characterVersion)
                detail(NSLocalizedString("格式", comment: "Format"), [character.sourceSpec, character.sourceSpecVersion].compactMap { $0 }.joined(separator: " "))
            }

            Section(NSLocalizedString("兼容性报告", comment: "Roleplay compatibility report")) {
                ForEach(character.compatibilityReport.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.title)
                            if !item.detail.isEmpty {
                                Text(item.detail)
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
                detail(NSLocalizedString("角色正则", comment: "Roleplay character regex"), "\(character.regexRules.count)")
                detail(NSLocalizedString("助手脚本", comment: "Roleplay helper scripts"), "\(character.helperScripts.count)")
                detail(NSLocalizedString("初始变量", comment: "Roleplay initial variables"), "\(character.initialVariables.count)")
                detail(NSLocalizedString("候选开场白", comment: "Alternate greetings"), "\(character.alternateGreetings.count)")
            }
        }
        .navigationTitle(character.name)
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
}

private struct PersonaLibraryView: View {
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
        .toolbar {
            Button {
                editingPersona = PersonaProfile(name: "")
            } label: {
                Label(NSLocalizedString("新增用户身份", comment: "Add persona"), systemImage: "plus")
            }
        }
        .sheet(item: $editingPersona) { persona in
            PersonaEditorView(persona: persona) {
                ChatService.shared.savePersonaProfile($0)
                editingPersona = nil
                reload()
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
    let onSave: (PersonaProfile) -> Void

    init(persona: PersonaProfile, onSave: @escaping (PersonaProfile) -> Void) {
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
                        onSave(persona)
                        dismiss()
                    }
                    .disabled(persona.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct RoleplaySessionBindingView: View {
    @Binding var currentSession: ChatSession?

    @State private var characters: [RoleplayCharacter] = []
    @State private var personas: [PersonaProfile] = []
    @State private var selectedCharacterID: UUID?
    @State private var selectedPersonaID: UUID?
    @State private var selectedGreetingIndex = 0
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
                    Picker(NSLocalizedString("角色卡", comment: "Roleplay character card"), selection: $selectedCharacterID) {
                        Text(NSLocalizedString("未绑定", comment: "Not bound")).tag(UUID?.none)
                        ForEach(characters) { character in
                            Text(character.name).tag(Optional(character.id))
                        }
                    }
                    .onChange(of: selectedCharacterID) { _, _ in persist(seedGreeting: true) }

                    Picker(NSLocalizedString("用户身份", comment: "Roleplay persona"), selection: $selectedPersonaID) {
                        Text(NSLocalizedString("默认用户", comment: "Default user persona")).tag(UUID?.none)
                        ForEach(personas) { persona in
                            Text(persona.name).tag(Optional(persona.id))
                        }
                    }
                    .onChange(of: selectedPersonaID) { _, _ in persist() }
                }

                if !selectedCharacterGreetings.isEmpty {
                    Section(NSLocalizedString("开场白", comment: "Roleplay greeting section")) {
                        Picker(NSLocalizedString("候选开场白", comment: "Alternate greeting picker"), selection: $selectedGreetingIndex) {
                            ForEach(selectedCharacterGreetings.indices, id: \.self) { index in
                                Text(String(format: NSLocalizedString("开场白 %d", comment: "Greeting number"), index + 1)).tag(index)
                            }
                        }
                        .onChange(of: selectedGreetingIndex) { _, _ in persist() }
                    }
                }

                Section(NSLocalizedString("酒馆兼容", comment: "Tavern compatibility section")) {
                    Toggle(NSLocalizedString("自动渲染 HTML", comment: "Auto-render roleplay HTML"), isOn: $htmlRenderingEnabled)
                        .onChange(of: htmlRenderingEnabled) { _, _ in persist() }
                    Toggle(NSLocalizedString("启用助手脚本", comment: "Enable roleplay helper scripts"), isOn: $helperScriptsEnabled)
                        .onChange(of: helperScriptsEnabled) { _, _ in persist() }
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
            loadBinding()
        }
    }

    private var selectedCharacterGreetings: [String] {
        guard let selectedCharacterID,
              let character = characters.first(where: { $0.id == selectedCharacterID }) else { return [] }
        return [character.firstMessage] + character.alternateGreetings
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
            selectedPersonaID = nil
            selectedGreetingIndex = 0
            htmlRenderingEnabled = true
            helperScriptsEnabled = true
            return
        }
        selectedCharacterID = binding.characterIDs.first
        selectedPersonaID = binding.personaID
        selectedGreetingIndex = binding.selectedGreetingIndex
        htmlRenderingEnabled = binding.htmlRenderingEnabled
        helperScriptsEnabled = binding.helperScriptsEnabled
    }

    private func persist(seedGreeting: Bool = false) {
        guard let sessionID = currentSession?.id else { return }
        guard let selectedCharacterID else {
            ChatService.shared.unbindRoleplay(sessionID: sessionID)
            return
        }
        ChatService.shared.bindRoleplay(
            sessionID: sessionID,
            characterIDs: [selectedCharacterID],
            personaID: selectedPersonaID,
            selectedGreetingIndex: selectedGreetingIndex,
            htmlRenderingEnabled: htmlRenderingEnabled,
            helperScriptsEnabled: helperScriptsEnabled,
            seedGreetingIfEmpty: seedGreeting
        )
    }
}

// ============================================================================
// RoleplaySettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 端角色卡、Persona 与当前会话绑定管理。
// ============================================================================

import ETOSCore
import SwiftUI
import UniformTypeIdentifiers

struct RoleplaySettingsView: View {
    @ObservedObject var viewModel: ChatViewModel

    @State private var characters: [RoleplayCharacter] = []
    @State private var personas: [PersonaProfile] = []
    @State private var selectedCharacterID: UUID?
    @State private var selectedPersonaID: UUID?
    @State private var htmlRenderingEnabled = true
    @State private var helperScriptsEnabled = true
    @State private var isImporting = false
    @State private var importError: String?
    @State private var isAddingPersona = false

    var body: some View {
        List {
            Section {
                Text(NSLocalizedString("导入酒馆角色卡，在当前会话绑定角色、用户身份和世界书。", comment: "Watch roleplay intro"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if viewModel.currentSession != nil {
                Section(NSLocalizedString("当前会话", comment: "Roleplay current session section")) {
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

                    Toggle(NSLocalizedString("自动渲染 HTML", comment: "Auto-render roleplay HTML"), isOn: $htmlRenderingEnabled)
                        .onChange(of: htmlRenderingEnabled) { _, _ in persist() }

                    Toggle(NSLocalizedString("启用助手脚本", comment: "Enable roleplay helper scripts"), isOn: $helperScriptsEnabled)
                        .onChange(of: helperScriptsEnabled) { _, _ in persist() }
                }
            }

            Section(NSLocalizedString("角色卡", comment: "Roleplay character cards section")) {
                Button {
                    isImporting = true
                } label: {
                    Label(NSLocalizedString("导入角色卡", comment: "Import roleplay card"), systemImage: "square.and.arrow.down")
                }

                if characters.isEmpty {
                    Text(NSLocalizedString("暂无角色卡。", comment: "No roleplay characters"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(characters) { character in
                        NavigationLink {
                            WatchRoleplayCharacterDetailView(character: character)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(character.name)
                                Text(String(
                                    format: NSLocalizedString("正则 %d · 脚本 %d", comment: "Watch roleplay card counts"),
                                    character.regexRules.count,
                                    character.helperScripts.count
                                ))
                                .etFont(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            ChatService.shared.deleteRoleplayCharacter(id: characters[index].id)
                        }
                        reload()
                    }
                }
            }

            Section(NSLocalizedString("用户身份", comment: "Roleplay personas section")) {
                Button {
                    isAddingPersona = true
                } label: {
                    Label(NSLocalizedString("新增用户身份", comment: "Add persona"), systemImage: "person.badge.plus")
                }
                ForEach(personas) { persona in
                    Text(persona.name)
                }
                .onDelete { offsets in
                    for index in offsets {
                        ChatService.shared.deletePersonaProfile(id: personas[index].id)
                    }
                    reload()
                }
            }

            Section {
                NavigationLink {
                    WorldbookSettingsView(viewModel: viewModel)
                } label: {
                    Label(NSLocalizedString("管理与绑定世界书", comment: "Manage roleplay lorebooks"), systemImage: "books.vertical")
                }
            }

            if let importError {
                Section(NSLocalizedString("导入错误", comment: "Import error section")) {
                    Text(importError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(NSLocalizedString("酒馆兼容", comment: "Watch roleplay compatibility title"))
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json, .png],
            allowsMultipleSelection: false,
            onCompletion: importCard
        )
        .sheet(isPresented: $isAddingPersona) {
            WatchPersonaEditorView {
                ChatService.shared.savePersonaProfile($0)
                isAddingPersona = false
                reload()
            }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            reloadBinding()
        }
    }

    private func reload() {
        Task {
            let loaded = await Task.detached(priority: .utility) {
                (
                    ChatService.shared.loadRoleplayCharacters(),
                    ChatService.shared.loadPersonaProfiles()
                )
            }.value
            characters = loaded.0
            personas = loaded.1
            reloadBinding()
        }
    }

    private func reloadBinding() {
        guard let sessionID = viewModel.currentSession?.id,
              let binding = ChatService.shared.roleplayBinding(sessionID: sessionID) else {
            selectedCharacterID = nil
            selectedPersonaID = nil
            htmlRenderingEnabled = true
            helperScriptsEnabled = true
            return
        }
        selectedCharacterID = binding.characterIDs.first
        selectedPersonaID = binding.personaID
        htmlRenderingEnabled = binding.htmlRenderingEnabled
        helperScriptsEnabled = binding.helperScriptsEnabled
    }

    private func persist(seedGreeting: Bool = false) {
        guard let sessionID = viewModel.currentSession?.id else { return }
        guard let selectedCharacterID else {
            ChatService.shared.unbindRoleplay(sessionID: sessionID)
            return
        }
        ChatService.shared.bindRoleplay(
            sessionID: sessionID,
            characterIDs: [selectedCharacterID],
            personaID: selectedPersonaID,
            htmlRenderingEnabled: htmlRenderingEnabled,
            helperScriptsEnabled: helperScriptsEnabled,
            seedGreetingIfEmpty: seedGreeting
        )
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
                _ = try await Task.detached(priority: .userInitiated) {
                    try ChatService.shared.importRoleplayCard(data: data, fileName: url.lastPathComponent)
                }.value
                importError = nil
                reload()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

private struct WatchRoleplayCharacterDetailView: View {
    let character: RoleplayCharacter

    var body: some View {
        List {
            Section {
                Text(character.name)
                    .etFont(.headline)
                if !character.creator.isEmpty {
                    Text(character.creator)
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section(NSLocalizedString("兼容性报告", comment: "Roleplay compatibility report")) {
                ForEach(character.compatibilityReport.items) { item in
                    HStack {
                        Text(item.title)
                        Spacer()
                        Image(systemName: item.status == .unsupported ? "xmark.circle" : "checkmark.circle")
                    }
                }
            }
        }
        .navigationTitle(character.name)
    }
}

private struct WatchPersonaEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    let onSave: (PersonaProfile) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("名称", comment: "Name"), text: $name)
                TextField(NSLocalizedString("角色扮演资料", comment: "Persona roleplay profile"), text: $description)
                Button(NSLocalizedString("保存", comment: "Save")) {
                    onSave(PersonaProfile(name: name, description: description))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle(NSLocalizedString("新增用户身份", comment: "Add persona"))
        }
    }
}

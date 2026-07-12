// ============================================================================
// RoleplaySettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// watchOS 端角色卡、Persona 与当前会话绑定管理。
// ============================================================================

import ETOSCore
import Foundation
import SwiftUI

struct RoleplaySettingsView: View {
    @ObservedObject var viewModel: ChatViewModel

    @State private var characters: [RoleplayCharacter] = []
    @State private var personas: [PersonaProfile] = []
    @State private var selectedCharacterID: UUID?
    @State private var selectedPersonaID: UUID?
    @State private var selectedGreetingIndex = 0
    @State private var htmlRenderingEnabled = true
    @State private var helperScriptsEnabled = true

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

                Section {
                    Toggle(
                        NSLocalizedString("屏蔽记忆与工具", comment: "Session memory and tool isolation toggle"),
                        isOn: Binding(
                            get: { viewModel.currentSession?.worldbookContextIsolationEnabled ?? false },
                            set: { updateContextIsolation($0) }
                        )
                    )

                    Text(NSLocalizedString("开启后，当前会话不会向模型发送记忆上下文、工具定义或历史工具调用。", comment: "Session memory and tool isolation description"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !selectedCharacterGreetings.isEmpty {
                    Section(NSLocalizedString("开场白", comment: "Roleplay greeting section")) {
                        Picker(
                            NSLocalizedString("候选开场白", comment: "Alternate greeting picker"),
                            selection: $selectedGreetingIndex
                        ) {
                            ForEach(selectedCharacterGreetings.indices, id: \.self) { index in
                                Text(String(
                                    format: NSLocalizedString("开场白 %d", comment: "Greeting number"),
                                    index + 1
                                ))
                                .tag(index)
                            }
                        }
                        .onChange(of: selectedGreetingIndex) { _, _ in persist(seedGreeting: true) }
                    }
                }
            }

            Section {
                NavigationLink {
                    WatchRoleplayCharacterLibraryView()
                } label: {
                    Label(NSLocalizedString("角色卡", comment: "Roleplay character cards title"), systemImage: "person.crop.rectangle.stack")
                }

                NavigationLink {
                    WatchPersonaLibraryView()
                } label: {
                    Label(NSLocalizedString("用户身份", comment: "Roleplay personas title"), systemImage: "person.text.rectangle")
                }
            }

            Section {
                if let sessionID = viewModel.currentSession?.id {
                    NavigationLink {
                        RoleplayDataSettingsView(sessionID: sessionID)
                    } label: {
                        Label(NSLocalizedString("宏与变量", comment: "Roleplay macros and variables"), systemImage: "curlybraces.square")
                    }
                }

                NavigationLink {
                    WorldbookSettingsView(viewModel: viewModel)
                } label: {
                    Label(NSLocalizedString("管理与绑定世界书", comment: "Manage roleplay lorebooks"), systemImage: "books.vertical")
                }
            }
        }
        .navigationTitle(NSLocalizedString("酒馆兼容", comment: "Watch roleplay compatibility title"))
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification)) { _ in
            reload()
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

    private var selectedCharacterGreetings: [String] {
        guard let selectedCharacterID,
              let character = characters.first(where: { $0.id == selectedCharacterID }) else { return [] }
        return [character.firstMessage] + character.alternateGreetings
    }

    private func reloadBinding() {
        guard let sessionID = viewModel.currentSession?.id,
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
        guard let sessionID = viewModel.currentSession?.id else { return }
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

    private func updateContextIsolation(_ isEnabled: Bool) {
        guard var session = viewModel.currentSession else { return }
        session.worldbookContextIsolationEnabled = isEnabled
        viewModel.currentSession = session
        ChatService.shared.updateWorldbookSessionSettings(
            sessionID: session.id,
            worldbookIDs: session.lorebookIDs,
            worldbookContextIsolationEnabled: isEnabled
        )
    }
}

private struct WatchRoleplayCharacterLibraryView: View {
    @State private var characters: [RoleplayCharacter] = []
    @State private var importURLText = ""
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        List {
            Section(NSLocalizedString("导入", comment: "Import section")) {
                TextField(
                    NSLocalizedString("角色卡链接", comment: "Roleplay card URL field"),
                    text: $importURLText.watchKeyboardNewlineBinding()
                )

                Button {
                    importCardFromURL()
                } label: {
                    Label(
                        NSLocalizedString("从 URL 导入角色卡", comment: "Import roleplay card from URL"),
                        systemImage: "link.badge.plus"
                    )
                }
                .disabled(isImporting)

                if isImporting {
                    ProgressView()
                }
            }

            if let importError {
                Section(NSLocalizedString("导入错误", comment: "Import error section")) {
                    Text(importError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section(NSLocalizedString("角色卡", comment: "Roleplay character cards section")) {
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
        }
        .navigationTitle(NSLocalizedString("角色卡", comment: "Roleplay character cards title"))
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

    private func importCardFromURL() {
        let trimmed = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importError = NSLocalizedString("链接不能为空。", comment: "URL cannot be empty")
            return
        }
        guard let url = URL(string: trimmed) else {
            importError = NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "Invalid URL format")
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            importError = NSLocalizedString("仅支持 http/https 链接。", comment: "Only http or https is supported")
            return
        }

        importError = nil
        isImporting = true
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                let (downloadedURL, response) = try await SyncPackageUploadService.downloadTemporaryFile(request: request)
                defer { try? FileManager.default.removeItem(at: downloadedURL) }
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: downloadedURL)
                }.value
                let fileName = suggestedCardFileName(from: url, response: response)
                _ = try await Task.detached(priority: .userInitiated) {
                    try ChatService.shared.importRoleplayCard(data: data, fileName: fileName)
                }.value
                importURLText = ""
                importError = nil
                isImporting = false
                reload()
            } catch {
                importError = error.localizedDescription
                isImporting = false
            }
        }
    }

    private func suggestedCardFileName(from url: URL, response: URLResponse) -> String {
        let suggested = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pathName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = suggested.isEmpty ? pathName : suggested
        let lowercased = fileName.lowercased()
        if lowercased.hasSuffix(".json") || lowercased.hasSuffix(".png") || lowercased.hasSuffix(".charx") {
            return fileName
        }
        if let httpResponse = response as? HTTPURLResponse,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() {
            if contentType.contains("png") { return "\(fileName.isEmpty ? "character-card" : fileName).png" }
            if contentType.contains("zip") { return "\(fileName.isEmpty ? "character-card" : fileName).charx" }
        }
        return "\(fileName.isEmpty ? "character-card" : fileName).json"
    }
}

private struct WatchPersonaLibraryView: View {
    @State private var personas: [PersonaProfile] = []
    @State private var isAddingPersona = false

    var body: some View {
        List {
            Section {
                Button {
                    isAddingPersona = true
                } label: {
                    Label(NSLocalizedString("新增用户身份", comment: "Add persona"), systemImage: "person.badge.plus")
                }
            }

            Section(NSLocalizedString("用户身份", comment: "Roleplay personas section")) {
                if personas.isEmpty {
                    Text(NSLocalizedString("暂无用户身份。", comment: "No personas"))
                        .foregroundStyle(.secondary)
                } else {
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
            }
        }
        .navigationTitle(NSLocalizedString("用户身份", comment: "Roleplay personas title"))
        .sheet(isPresented: $isAddingPersona) {
            WatchPersonaEditorView { persona, avatarData in
                Task {
                    _ = await Task.detached(priority: .utility) {
                        ChatService.shared.savePersonaProfile(persona, avatarData: avatarData)
                    }.value
                    isAddingPersona = false
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
            personas = await Task.detached(priority: .utility) {
                ChatService.shared.loadPersonaProfiles().sorted { $0.updatedAt > $1.updatedAt }
            }.value
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
                        Text(item.localizedTitle)
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
    @State private var avatarData: Data?
    @State private var avatarURLText = ""
    @State private var isImportingAvatar = false
    @State private var avatarError: String?
    let onSave: (PersonaProfile, Data?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField(NSLocalizedString("名称", comment: "Name"), text: $name)
                TextField(NSLocalizedString("角色扮演资料", comment: "Persona roleplay profile"), text: $description)
                TextField(
                    NSLocalizedString("头像链接", comment: "Persona avatar URL field"),
                    text: $avatarURLText.watchKeyboardNewlineBinding()
                )
                Button {
                    loadAvatarFromURL()
                } label: {
                    Label(
                        NSLocalizedString("从 URL 载入头像", comment: "Load persona avatar from URL"),
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
                .disabled(isImportingAvatar)
                if isImportingAvatar {
                    ProgressView()
                }
                if avatarData != nil {
                    Label(NSLocalizedString("已选择新头像", comment: "New persona avatar selected"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let avatarError {
                    Text(avatarError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
                Button(NSLocalizedString("保存", comment: "Save")) {
                    onSave(PersonaProfile(name: name, description: description), avatarData)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle(NSLocalizedString("新增用户身份", comment: "Add persona"))
        }
    }

    private func loadAvatarFromURL() {
        let trimmed = avatarURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            avatarError = NSLocalizedString("链接不能为空。", comment: "URL cannot be empty")
            return
        }
        guard let url = URL(string: trimmed) else {
            avatarError = NSLocalizedString("链接格式无效，请输入完整 URL。", comment: "Invalid URL format")
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            avatarError = NSLocalizedString("仅支持 http/https 链接。", comment: "Only http or https is supported")
            return
        }

        avatarError = nil
        isImportingAvatar = true
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 45
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }
                avatarData = data
                avatarURLText = ""
                isImportingAvatar = false
            } catch {
                avatarError = error.localizedDescription
                isImportingAvatar = false
            }
        }
    }
}

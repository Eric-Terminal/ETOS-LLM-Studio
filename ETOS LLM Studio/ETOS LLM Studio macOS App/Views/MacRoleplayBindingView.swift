import ETOSCore
import SwiftUI

struct MacRoleplayBindingView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let session: ChatSession
    @State private var draft: MacRoleplayBindingDraft
    @State private var catalog = MacRoleplayBindingCatalog()
    @State private var loaded = false
    @State private var loading = true
    @State private var changedExternally = false
    @State private var saving = false
    @State private var confirmingRemoval = false
    @State private var refreshID = UUID()
    @State private var error: String?

    init(session: ChatSession) {
        self.session = session
        _draft = State(initialValue: MacRoleplayBindingDraft(sessionID: session.id, original: nil, preferredPersonaID: nil))
    }

    private var greetings: MacRoleplayGreetingCatalog { catalog.greetings[draft.characterID] ?? .init() }
    private var editable: Bool { loaded && !loading && !changedExternally && !saving && !workspace.isRestoringData }

    var body: some View {
        NavigationStack {
            Form {
                Section { LabeledContent(NSLocalizedString("当前会话", comment: ""), value: session.name) }
                if loaded {
                    Section(NSLocalizedString("角色与用户身份", comment: "")) {
                        Picker(NSLocalizedString("绑定角色卡", comment: ""), selection: Binding(get: { draft.characterID }, set: selectCharacter)) {
                            Text(NSLocalizedString("未绑定", comment: "")).tag("")
                            ForEach(catalog.characters) { Text($0.name).tag($0.id) }
                            if !catalog.characterIDSet.contains(draft.characterID) {
                                Text(NSLocalizedString("角色卡不存在或已被删除。", comment: "")).tag(draft.characterID)
                            }
                        }
                        Picker(NSLocalizedString("用户身份", comment: ""), selection: $draft.personaID) {
                            Text(NSLocalizedString("默认用户", comment: "")).tag("")
                            ForEach(catalog.personas) { Text($0.name).tag($0.id) }
                            if !catalog.personaIDSet.contains(draft.personaID) {
                                Text(NSLocalizedString("已选身份不可用", comment: "")).tag(draft.personaID)
                            }
                        }
                    }
                    if !greetings.rows.isEmpty {
                        Section(NSLocalizedString("开场白", comment: "")) {
                            Picker(NSLocalizedString("候选开场白", comment: ""), selection: $draft.greetingIndex) {
                                ForEach(greetings.rows) { Text($0.title).tag($0.id) }
                                if greetings.byIndex[draft.greetingIndex] == nil {
                                    Text(NSLocalizedString("已选开场白不可用", comment: "")).tag(draft.greetingIndex)
                                }
                            }
                            if let greeting = greetings.byIndex[draft.greetingIndex] {
                                Text(greeting.text).font(.footnote).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                            }
                        }
                    }
                    Section(NSLocalizedString("酒馆兼容", comment: "")) {
                        Toggle(NSLocalizedString("自动渲染 HTML", comment: ""), isOn: $draft.htmlRenderingEnabled)
                        Toggle(NSLocalizedString("启用助手脚本", comment: ""), isOn: $draft.helperScriptsEnabled)
                    }
                    Section {
                        MacSettingsIntroCard(id: "roleplay-binding", title: NSLocalizedString("使用说明", comment: ""),
                                             details: NSLocalizedString("Mac 会话角色绑定使用说明", comment: ""), documentID: "roleplay")
                        if draft.original != nil {
                            Button(NSLocalizedString("解除角色扮演绑定", comment: ""), role: .destructive) { confirmingRemoval = true }
                        }
                    } footer: {
                        Text(NSLocalizedString("修改保留为草稿，点击保存后生效。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                    }
                } else { ProgressView(NSLocalizedString("正在加载…", comment: "")) }
                if changedExternally {
                    Text(NSLocalizedString("配置已在其他页面修改，请重新打开后再编辑。", comment: "")).font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .disabled(!editable)
            .navigationTitle(NSLocalizedString("会话角色绑定", comment: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(NSLocalizedString("取消", comment: "")) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) { save() }.disabled(!editable)
                }
            }
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "mac-roleplay-binding-\(session.id)-\(draft.characterID)-\(editable)-\(confirmingRemoval)"),
                title: NSLocalizedString("会话角色绑定", comment: ""), documents: [GuideDocumentReference(id: "roleplay", title: "Roleplay")],
                settings: guideSettings
            )
        }
        .modifier(MacGuideInspector())
        .frame(minWidth: 520, minHeight: 500)
        .interactiveDismissDisabled(saving)
        .confirmationDialog(NSLocalizedString("解除角色扮演绑定", comment: ""), isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(NSLocalizedString("解除角色扮演绑定", comment: ""), role: .destructive) { save(removing: true) }
        } message: {
            Text(NSLocalizedString("解除绑定会清除当前会话的角色扮演变量，保留聊天消息与角色资料。", comment: ""))
        }
        .task(id: refreshID) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: RoleplayStore.didChangeNotification).receive(on: DispatchQueue.main)) { notification in
            if notification.userInfo?[RoleplayStore.changeKindUserInfoKey] as? String == RoleplayStore.libraryChangeKind { refreshID = UUID() }
        }
        .onReceive(AppConfigStore.shared.$appLanguage.dropFirst()) { _ in refreshID = UUID() }
        .onChange(of: workspace.isRestoringData) { _, restoring in if restoring { dismiss() } }
    }

    private var guideSettings: [GuidePageSetting] {
        var fields: [GuidePageSetting] = [
            .readOnly("session_id", label: NSLocalizedString("当前会话", comment: ""), value: { .string(session.id.uuidString) }),
            .readOnly("requires_save", label: NSLocalizedString("修改后需要保存", comment: ""), value: { .bool(true) }),
            .readOnly("original_references", label: NSLocalizedString("角色与用户身份", comment: ""), value: { draft.originalReferences }),
            .readOnly("editable", label: NSLocalizedString("状态", comment: ""), value: { .bool(editable && !confirmingRemoval) }),
            .readOnly("available_characters", label: NSLocalizedString("角色卡", comment: ""), value: { catalog.charactersValue }),
            .readOnly("available_personas", label: NSLocalizedString("可用用户身份", comment: ""), value: { catalog.personasValue }),
            .readOnly("available_greetings", label: NSLocalizedString("可用开场白", comment: ""), value: { greetings.guideValue })
        ]
        guard editable, !confirmingRemoval else { return fields }
        fields += [
            .string("character_id", label: NSLocalizedString("绑定角色卡", comment: ""), allowedValues: catalog.characterIDs,
                    get: { draft.characterID }, set: { selectCharacter($0) }),
            .string("persona_id", label: NSLocalizedString("绑定用户身份", comment: ""), allowedValues: catalog.personaIDs,
                    get: { draft.personaID }, set: { draft.personaID = $0 }),
            .bool("html_rendering_enabled", label: NSLocalizedString("自动渲染 HTML", comment: ""), get: { draft.htmlRenderingEnabled }, set: { draft.htmlRenderingEnabled = $0 }),
            .bool("helper_scripts_enabled", label: NSLocalizedString("启用助手脚本", comment: ""), get: { draft.helperScriptsEnabled }, set: { draft.helperScriptsEnabled = $0 })
        ]
        if !greetings.rows.isEmpty {
            fields.append(.string("greeting_index", label: NSLocalizedString("开场白索引", comment: ""),
                                  allowedValues: greetings.guideIDs, allowsEmpty: false, get: { String(draft.greetingIndex) }, set: {
                if let index = Int($0), greetings.byIndex[index] != nil { draft.greetingIndex = index }
            }))
        }
        return fields
    }

    private func selectCharacter(_ id: String) {
        guard draft.characterID != id else { return }
        draft.characterID = id
        draft.greetingIndex = catalog.greetings[id]?.rows.first?.id ?? 0
    }

    private func load() async {
        loading = true
        let sessionID = session.id
        let wasLoaded = loaded
        let original = draft.original
        let result = await Task.detached(priority: .userInitiated) {
            let service = ChatService.shared
            let latest = service.roleplayBinding(sessionID: sessionID)
            let catalog = MacRoleplayBindingCatalog.prepare(characters: service.loadRoleplayCharacters(), personas: service.loadPersonaProfiles(),
                                                           original: wasLoaded ? original : latest)
            let initialDraft = MacRoleplayBindingDraft(sessionID: sessionID, original: latest, preferredPersonaID: service.preferredRoleplayPersonaID())
            return (latest, initialDraft, catalog)
        }.value
        guard !Task.isCancelled, !workspace.isRestoringData else { return }
        catalog = result.2
        loading = false
        if !loaded {
            draft = result.1
            loaded = true
        } else { changedExternally = result.0 != draft.original }
    }

    private func save(removing: Bool = false) {
        guard editable else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do { try await workspace.saveRoleplayBinding(draft, removing: removing); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

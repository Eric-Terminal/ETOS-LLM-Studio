// ============================================================================
// RoleplayDataSettingsView.swift
// ============================================================================
// ETOS LLM Studio
//
// 编辑当前角色扮演会话的自定义宏与分层变量。
// ============================================================================

import ETOSCore
import SwiftUI

struct RoleplayDataSettingsView: View {
    let sessionID: UUID

    @State private var snapshot = RoleplayVariableSnapshot()
    @State private var macroDrafts: [RoleplayMacroDraft] = []
    @State private var selectedScope: RoleplayVariableScope = .chat
    @State private var variablesJSON = "{}"
    @State private var latestMessageID: UUID?
    @State private var latestVersionIndex = 0
    @State private var statusText: String?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Text(NSLocalizedString("自定义宏会以 {{名称}} 或 {{{名称}}} 注入提示词、世界书和角色正则。", comment: "Custom roleplay macro detail"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(NSLocalizedString("自定义宏", comment: "Custom roleplay macros section")) {
                ForEach($macroDrafts) { $draft in
                    TextField(NSLocalizedString("宏名称", comment: "Roleplay macro name"), text: $draft.name)
                    TextField(NSLocalizedString("宏值", comment: "Roleplay macro value"), text: $draft.value, axis: .vertical)
                    Button(role: .destructive) {
                        macroDrafts.removeAll { $0.id == draft.id }
                    } label: {
                        Label(NSLocalizedString("删除此宏", comment: "Delete roleplay macro"), systemImage: "trash")
                    }
                }

                Button {
                    macroDrafts.append(.init())
                } label: {
                    Label(NSLocalizedString("新增宏", comment: "Add roleplay macro"), systemImage: "plus")
                }

                Button(NSLocalizedString("保存自定义宏", comment: "Save custom roleplay macros")) {
                    saveMacros()
                }
            }

            Section {
                Picker(NSLocalizedString("变量作用域", comment: "Roleplay variable scope"), selection: $selectedScope) {
                    ForEach(RoleplayVariableScope.allCases, id: \.self) { scope in
                        Text(scope.localizedName).tag(scope)
                    }
                }
                .onChange(of: selectedScope) { _, _ in refreshVariablesJSON() }

                TextEditor(text: $variablesJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)

                Button(NSLocalizedString("保存此作用域", comment: "Save roleplay variable scope")) {
                    saveVariables()
                }
                .disabled(selectedScope == .message && latestMessageID == nil)
            } header: {
                Text(NSLocalizedString("分层变量", comment: "Scoped roleplay variables section"))
            } footer: {
                Text(variableFooter)
            }

            if let statusText {
                Section {
                    Label(statusText, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle(NSLocalizedString("宏与变量", comment: "Roleplay macros and variables title"))
        .task { await load() }
        .alert(
            NSLocalizedString("无法保存", comment: "Unable to save roleplay data"),
            isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )
        ) {
            Button(NSLocalizedString("好的", comment: "OK")) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var variableFooter: String {
        if selectedScope == .message && latestMessageID == nil {
            return NSLocalizedString("当前会话还没有消息，暂时无法保存消息版本变量。", comment: "No message for message variables")
        }
        return NSLocalizedString("变量必须填写为 JSON 对象。消息变量会绑定当前消息的当前版本，切换回复版本时互不覆盖。", comment: "Roleplay variable JSON detail")
    }

    @MainActor
    private func load() async {
        let loaded = await Task.detached(priority: .utility) {
            let snapshot = ChatService.shared.roleplayVariableSnapshot(sessionID: sessionID)
            let message = Persistence.loadMessages(for: sessionID).last
            return (snapshot, message?.id, message?.getCurrentVersionIndex() ?? 0)
        }.value
        snapshot = loaded.0
        latestMessageID = loaded.1
        latestVersionIndex = loaded.2
        macroDrafts = snapshot.customMacros.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { RoleplayMacroDraft(name: $0.key, value: $0.value) }
        refreshVariablesJSON()
    }

    private func refreshVariablesJSON() {
        variablesJSON = Self.jsonString(snapshot.scopedVariables(
            selectedScope,
            messageID: latestMessageID,
            versionIndex: latestVersionIndex
        ))
    }

    private func saveMacros() {
        let drafts = macroDrafts
        Task {
            do {
                let updated = try await Task.detached(priority: .utility) {
                    var macros: [String: String] = [:]
                    for draft in drafts {
                        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { throw RoleplayDataEditorError.emptyMacroName }
                        guard !name.contains("{{"), !name.contains("}}") else { throw RoleplayDataEditorError.invalidMacroName }
                        macros[name] = draft.value
                    }
                    var snapshot = ChatService.shared.roleplayVariableSnapshot(sessionID: sessionID)
                    snapshot.replaceCustomMacros(macros)
                    ChatService.shared.saveRoleplayVariableSnapshot(snapshot, sessionID: sessionID)
                    return snapshot
                }.value
                snapshot = updated
                statusText = NSLocalizedString("自定义宏已保存。", comment: "Custom roleplay macros saved")
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func saveVariables() {
        let json = variablesJSON
        let scope = selectedScope
        let messageID = latestMessageID
        let versionIndex = latestVersionIndex
        Task {
            do {
                let updated = try await Task.detached(priority: .utility) {
                    guard let data = json.data(using: .utf8),
                          let values = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
                        throw RoleplayDataEditorError.invalidVariablesJSON
                    }
                    var snapshot = ChatService.shared.roleplayVariableSnapshot(sessionID: sessionID)
                    snapshot.replaceVariables(values, scope: scope, messageID: messageID, versionIndex: versionIndex)
                    ChatService.shared.saveRoleplayVariableSnapshot(snapshot, sessionID: sessionID)
                    return snapshot
                }.value
                snapshot = updated
                statusText = NSLocalizedString("变量已保存。", comment: "Roleplay variables saved")
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private static func jsonString(_ values: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(values), let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

private struct RoleplayMacroDraft: Identifiable, Sendable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

private enum RoleplayDataEditorError: LocalizedError {
    case emptyMacroName
    case invalidMacroName
    case invalidVariablesJSON

    var errorDescription: String? {
        switch self {
        case .emptyMacroName:
            return NSLocalizedString("宏名称不能为空。", comment: "Empty roleplay macro name")
        case .invalidMacroName:
            return NSLocalizedString("宏名称不要包含花括号。", comment: "Invalid roleplay macro name")
        case .invalidVariablesJSON:
            return NSLocalizedString("变量内容必须是有效的 JSON 对象。", comment: "Invalid roleplay variables JSON")
        }
    }
}

private extension RoleplayVariableScope {
    var localizedName: String {
        switch self {
        case .global: return NSLocalizedString("全局变量", comment: "Global roleplay variables")
        case .preset: return NSLocalizedString("预设变量", comment: "Preset roleplay variables")
        case .character: return NSLocalizedString("角色变量", comment: "Character roleplay variables")
        case .persona: return NSLocalizedString("用户身份变量", comment: "Persona roleplay variables")
        case .chat: return NSLocalizedString("会话变量", comment: "Chat roleplay variables")
        case .message: return NSLocalizedString("消息版本变量", comment: "Message-version roleplay variables")
        case .script: return NSLocalizedString("脚本变量", comment: "Script roleplay variables")
        }
    }
}

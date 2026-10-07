import Combine
import ETOSCore
import Foundation

enum MacRoleplayDataSection: Hashable, Sendable {
    case macros
    case variables(RoleplayVariableScope)

    var id: String {
        switch self { case .macros: "macros"; case .variables(let scope): scope.rawValue }
    }
    var title: String {
        switch self { case .macros: NSLocalizedString("自定义宏", comment: ""); case .variables(let scope): scope.macLabel }
    }
    func target(message: ChatMessage?) -> RoleplayDataTarget {
        switch self {
        case .macros: .macros
        case .variables(let scope): .variables(scope, messageID: scope == .message ? message?.id : nil,
                                             versionIndex: scope == .message ? message?.getCurrentVersionIndex() ?? 0 : 0)
        }
    }
}

struct MacRoleplayMacroRow: Identifiable, Sendable {
    let id = UUID()
    var name = ""
    var value = ""
}

struct MacRoleplayDataBuffer: Sendable {
    let values: [String: JSONValue]
    let field: GuideSnapshotField
    let text: String
    let macros: [MacRoleplayMacroRow]

    init(values: [String: JSONValue], section: MacRoleplayDataSection) {
        self.values = values
        let value = JSONValue.dictionary(values)
        field = GuideSnapshotField(label: section.title, value: value)
        text = value.prettyPrinted()
        if section == .macros {
            macros = values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.compactMap {
                guard case .string(let text) = $0.value else { return nil }
                return MacRoleplayMacroRow(name: $0.key, value: text)
            }
        } else { macros = [] }
    }

    static func values(text: String, macros: [MacRoleplayMacroRow], section: MacRoleplayDataSection) throws -> [String: JSONValue] {
        if section == .macros {
            var values: [String: JSONValue] = [:]
            for row in macros {
                guard values[row.name] == nil else { throw RoleplayDataDraftError.duplicateMacroName }
                values[row.name] = .string(row.value)
            }
            return try RoleplayDataDraft.normalizeMacros(values)
        }
        guard let values = try? JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) else {
            throw MacRoleplayDataError.invalidJSON
        }
        return values
    }
}

@MainActor
final class MacRoleplayDataModel: ObservableObject {
    let sessionID: UUID
    let section: MacRoleplayDataSection
    @Published var text = "" { didSet { if !applyingBuffer { prepare() } } }
    @Published var macros: [MacRoleplayMacroRow] = [] { didSet { if !applyingBuffer { prepare() } } }
    @Published private(set) var source: RoleplayDataDraft?
    @Published private(set) var message: ChatMessage?
    @Published private(set) var subjectName: String?
    @Published private(set) var prepared: MacRoleplayDataBuffer?
    @Published private(set) var saving = false
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    @Published private(set) var status: String?
    private weak var workspace: MacWorkspaceModel?
    private var applyingBuffer = false
    private var revision = UUID()
    private var preparation: Task<Void, Never>?

    init(sessionID: UUID, section: MacRoleplayDataSection) { self.sessionID = sessionID; self.section = section }

    var pageID: GuidePageID {
        GuidePageID(rawValue: "mac-roleplay-data-\(sessionID)-\(section.id)-\(message?.id.uuidString ?? "none")-\(message?.getCurrentVersionIndex() ?? 0)")
    }
    var editable: Bool { source != nil && !loading && !saving && workspace?.isRestoringData == false && AppLockManager.shared.state != .locked }
    var canSave: Bool { editable && prepared != nil }

    func load(workspace: MacWorkspaceModel) async {
        self.workspace = workspace
        guard source == nil else { prepare(); return }
        loading = true
        error = nil
        let sessionID = sessionID, section = section
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let service = ChatService.shared
                guard service.chatSessionsSubject.value.contains(where: { $0.id == sessionID }) else { throw RoleplayDraftWriteError.changedExternally }
                let message = section == .variables(.message) ? service.messagesSnapshot(for: sessionID).last : nil
                let source = try service.roleplayDataDraft(sessionID: sessionID, target: section.target(message: message))
                let subjectName: String?
                switch section {
                case .variables(.character): subjectName = service.loadRoleplayCharacters().first { $0.id == source.subjectID }?.name
                case .variables(.persona): subjectName = service.loadPersonaProfiles().first { $0.id == source.subjectID }?.name
                default: subjectName = nil
                }
                return (source, message, MacRoleplayDataBuffer(values: source.originalValues, section: section), subjectName)
            }.value
            guard !Task.isCancelled, !workspace.isRestoringData else { return }
            source = loaded.0
            message = loaded.1
            subjectName = loaded.3
            apply(loaded.2)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        loading = false
    }

    func prepare() {
        revision = UUID()
        preparation?.cancel()
        prepared = nil
        error = nil
        status = nil
        guard let source else { return }
        let text = text, macros = macros, section = section
        preparation = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let result = try await Task.detached(priority: .userInitiated) {
                    let values = try MacRoleplayDataBuffer.values(text: text, macros: macros, section: section)
                    return MacRoleplayDataBuffer(values: try source.normalizedValues(values), section: section)
                }.value
                guard let self, !Task.isCancelled else { return }
                prepared = result
            } catch { if !Task.isCancelled { self?.error = error.localizedDescription } }
        }
    }

    func save() async {
        guard canSave, let source, let prepared, let workspace else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            self.source = try await workspace.saveRoleplayData(source, values: prepared.values, message: message)
            apply(prepared)
            status = section == .macros ? NSLocalizedString("自定义宏已保存。", comment: "") : NSLocalizedString("变量已保存。", comment: "")
        } catch { self.error = error.localizedDescription }
    }

    func cancelPreparation() {
        preparation?.cancel()
        revision = UUID()
    }

    func buildProposal(_ call: InternalToolCall) async throws -> GuideActionProposal {
        guard editable, let source else { throw GuideError.invalidToolArguments }
        let revision = revision, pageID = pageID, section = section
        let value = try await Task.detached {
            let arguments = try GuideToolArguments.decode(call.arguments)
            try GuideToolArguments.requireOnlyKeys(["values"], in: arguments)
            guard case .dictionary(let values) = arguments["values"] else { throw GuideError.invalidToolArguments }
            let normalized = JSONValue.dictionary(try source.normalizedValues(values))
            return (normalized, GuideSecretRedactor.containsSensitiveField(normalized))
        }.value
        guard editable, self.revision == revision else { throw GuideError.pageChanged }
        return GuideActionProposal(pageID: pageID, toolCallID: call.id, toolName: call.toolName, summary: section.title,
                                   mutations: [GuideSettingMutation(path: "values", label: section.title, oldValue: nil, newValue: value.0, isSensitive: value.1)],
                                   arguments: ["values": value.0, "revision": .string(revision.uuidString)])
    }

    func execute(_ proposal: GuideActionProposal) async throws -> GuideActionExecution {
        guard editable, proposal.pageID == pageID, let source,
              try GuideToolArguments.string("revision", in: proposal.arguments) == revision.uuidString,
              case .dictionary(let values) = proposal.arguments["values"] else { throw GuideError.pageChanged }
        let revision = revision, section = section
        let buffer = try await Task.detached {
            MacRoleplayDataBuffer(values: try source.normalizedValues(values), section: section)
        }.value
        guard editable, self.revision == revision else { throw GuideError.pageChanged }
        apply(buffer)
        return GuideActionExecution(message: NSLocalizedString("已更新草稿，请保存配置以生效。", comment: ""))
    }

    private func apply(_ buffer: MacRoleplayDataBuffer) {
        preparation?.cancel()
        applyingBuffer = true
        text = buffer.text
        macros = buffer.macros
        applyingBuffer = false
        prepared = buffer
        revision = UUID()
        error = nil
        status = nil
    }
}

enum MacRoleplayDataError: LocalizedError {
    case invalidJSON
    var errorDescription: String? { NSLocalizedString("变量内容必须是有效的 JSON 对象。", comment: "") }
}

extension RoleplayVariableScope {
    var macLabel: String {
        switch self {
        case .global: NSLocalizedString("全局变量", comment: "")
        case .preset: NSLocalizedString("预设变量", comment: "")
        case .character: NSLocalizedString("角色变量", comment: "")
        case .persona: NSLocalizedString("用户身份变量", comment: "")
        case .chat: NSLocalizedString("会话变量", comment: "")
        case .message: NSLocalizedString("消息版本变量", comment: "")
        case .script: NSLocalizedString("脚本变量", comment: "")
        }
    }
}

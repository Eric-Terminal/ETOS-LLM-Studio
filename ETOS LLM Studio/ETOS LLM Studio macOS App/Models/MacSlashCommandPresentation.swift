import ETOSCore
import Foundation

struct MacSlashCommandRow: Identifiable, Sendable {
    let suggestion: ChatSlashCommandSuggestion
    let invocation: String
    let description: String
    let systemImage: String
    let aliases: String
    var id: String { suggestion.id }

    init(_ suggestion: ChatSlashCommandSuggestion) {
        self.suggestion = suggestion
        invocation = suggestion.invocation
        description = String(suggestion.displayDescription.prefix(160))
        systemImage = suggestion.systemImage
        if case .builtIn(let command) = suggestion { aliases = command.aliases.map { "/" + $0 }.joined(separator: ", ") }
        else { aliases = "" }
    }
}

struct MacSlashCommandCatalog: Sendable {
    let snapshot: CustomChatSlashCommandSnapshot
    let custom: [MacSlashCommandRow]
    let builtIn: [MacSlashCommandRow]
    let guideCommands: JSONValue
    let guideBuiltIn: JSONValue
    let commandsByID: [UUID: CustomChatSlashCommand]

    init(_ snapshot: CustomChatSlashCommandSnapshot) {
        self.snapshot = snapshot
        custom = snapshot.commands.map { MacSlashCommandRow(.custom($0)) }
        builtIn = ChatSlashCommand.allCases.map { MacSlashCommandRow(.builtIn($0)) }
        guideCommands = GuideSlashCommandSettingsSupport.value(snapshot.commands)
        guideBuiltIn = .array(ChatSlashCommand.allCases.map { .string($0.invocation) })
        commandsByID = Dictionary(uniqueKeysWithValues: snapshot.commands.map { ($0.id, $0) })
    }

    static func guideReplacement(_ value: JSONValue, original: CustomChatSlashCommandSnapshot) throws -> [CustomChatSlashCommand] {
        guard case .array(let rows) = value else { throw GuideError.invalidToolArguments }
        let originals = Dictionary(uniqueKeysWithValues: original.commands.map { ($0.id, $0) })
        let commands = try rows.map { row -> CustomChatSlashCommand in
            guard case .dictionary(let fields) = row,
                  case .string(let rawTrigger)? = fields["trigger"], case .string(let prompt)? = fields["prompt"] else {
                throw GuideError.invalidToolArguments
            }
            try GuideToolArguments.requireOnlyKeys(["id", "trigger", "prompt"], in: fields)
            let id: UUID
            if let raw = fields["id"] {
                guard case .string(let text) = raw, let parsed = UUID(uuidString: text) else { throw GuideError.invalidToolArguments }
                id = parsed
            } else { id = UUID() }
            let trigger = CustomChatSlashCommandStore.canonicalTrigger(rawTrigger)
            if let old = originals[id], old.trigger == trigger, old.prompt == prompt { return old }
            return CustomChatSlashCommand(id: id, trigger: trigger, prompt: prompt)
        }
        return try CustomChatSlashCommandLibrary.validated(commands)
    }
}

struct MacSlashCommandInput: Sendable {
    let text: String
    let sessionID: UUID?
    let recognized: ChatSlashCommandSuggestion?
    let rows: [MacSlashCommandRow]
    let indicesByID: [String: Int]

    init(text: String, sessionID: UUID?, enabled: Bool, commands: [CustomChatSlashCommand], literalPrefill: String?) {
        self.text = text; self.sessionID = sessionID
        if enabled && text != literalPrefill {
            recognized = ChatSlashCommandParser.recognizedSuggestion(in: text, customCommands: commands)
            rows = ChatSlashCommandParser.suggestions(for: text, customCommands: commands).map(MacSlashCommandRow.init)
        } else { recognized = nil; rows = [] }
        indicesByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
    }
}

enum MacSlashCommandRoute: Hashable {
    case new, model, sessions, settings, daily, temporary, compact, retry, stop, clear
    case page(MacChatQuickActionPage)
    init(_ command: ChatSlashCommand) {
        switch command {
        case .new: self = .new
        case .model: self = .model
        case .sessions: self = .sessions
        case .settings: self = .settings
        case .daily: self = .daily
        case .temporary: self = .temporary
        case .compact: self = .compact
        case .retry: self = .retry
        case .stop: self = .stop
        case .clear: self = .clear
        case .tools: self = .page(.toolCenter)
        case .usage: self = .page(.usageAnalytics)
        case .memory: self = .page(.memory)
        case .mcp: self = .page(.mcp)
        case .skills: self = .page(.agentSkills)
        case .shortcuts: self = .page(.shortcuts)
        case .roleplay: self = .page(.roleplay)
        case .worldbook: self = .page(.worldbook)
        case .features: self = .page(.extendedFeatures)
        }
    }
}

struct MacSlashCommandEditorTarget: Identifiable {
    let id = UUID()
    let command: CustomChatSlashCommand?
    let original: CustomChatSlashCommandSnapshot
    let epoch: UUID
}

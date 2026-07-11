// ============================================================================
// RoleplayModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义角色卡、Persona、会话绑定、酒馆正则、助手脚本与兼容性报告。
// ============================================================================

import Foundation

public enum RoleplayRegexPlacement: Int, Codable, CaseIterable, Hashable, Sendable {
    case userInput = 1
    case aiOutput = 2
    case slashCommand = 3
    case worldInfo = 5
    case reasoning = 6
}

public enum RoleplayRegexScope: String, Codable, CaseIterable, Hashable, Sendable {
    case global
    case preset
    case character
    case session
}

public struct RoleplayRegexRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var scriptName: String
    public var findRegex: String
    public var replaceString: String
    public var trimStrings: [String]
    public var placements: [RoleplayRegexPlacement]
    public var scope: RoleplayRegexScope
    public var disabled: Bool
    public var markdownOnly: Bool
    public var promptOnly: Bool
    public var runOnEdit: Bool
    public var minDepth: Int?
    public var maxDepth: Int?
    /// 0 不替换，1 原样替换宏，2 将宏结果转义后替换。
    public var substituteRegex: Int
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        scriptName: String = "",
        findRegex: String = "",
        replaceString: String = "",
        trimStrings: [String] = [],
        placements: [RoleplayRegexPlacement] = [.aiOutput],
        scope: RoleplayRegexScope = .character,
        disabled: Bool = false,
        markdownOnly: Bool = false,
        promptOnly: Bool = false,
        runOnEdit: Bool = false,
        minDepth: Int? = nil,
        maxDepth: Int? = nil,
        substituteRegex: Int = 0,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.scriptName = scriptName
        self.findRegex = findRegex
        self.replaceString = replaceString
        self.trimStrings = trimStrings
        self.placements = placements
        self.scope = scope
        self.disabled = disabled
        self.markdownOnly = markdownOnly
        self.promptOnly = promptOnly
        self.runOnEdit = runOnEdit
        self.minDepth = minDepth
        self.maxDepth = maxDepth
        self.substituteRegex = substituteRegex
        self.metadata = metadata
    }
}

public struct RoleplayScriptButton: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var visible: Bool
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        name: String,
        visible: Bool = true,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.visible = visible
        self.metadata = metadata
    }
}

public struct RoleplayHelperScript: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var content: String
    public var info: String
    public var enabled: Bool
    public var buttons: [RoleplayScriptButton]
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        name: String,
        content: String,
        info: String = "",
        enabled: Bool = true,
        buttons: [RoleplayScriptButton] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.info = info
        self.enabled = enabled
        self.buttons = buttons
        self.metadata = metadata
    }
}

public enum RoleplayCompatibilityStatus: String, Codable, Hashable, Sendable {
    case supported
    case translated
    case partial
    case unsupported
}

public struct RoleplayCompatibilityItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var status: RoleplayCompatibilityStatus
    public var detail: String

    public init(id: String, title: String, status: RoleplayCompatibilityStatus, detail: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }
}

public struct RoleplayCompatibilityReport: Codable, Hashable, Sendable {
    public var items: [RoleplayCompatibilityItem]
    public var detectedDOMAccess: Bool
    public var detectedNetworkAccess: Bool
    public var detectedMVUUsage: Bool

    public init(
        items: [RoleplayCompatibilityItem] = [],
        detectedDOMAccess: Bool = false,
        detectedNetworkAccess: Bool = false,
        detectedMVUUsage: Bool = false
    ) {
        self.items = items
        self.detectedDOMAccess = detectedDOMAccess
        self.detectedNetworkAccess = detectedNetworkAccess
        self.detectedMVUUsage = detectedMVUUsage
    }
}

public struct RoleplayCharacter: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var avatarFileName: String?
    public var description: String
    public var personality: String
    public var scenario: String
    public var firstMessage: String
    public var alternateGreetings: [String]
    public var messageExamples: String
    public var creatorNotes: String
    public var systemPrompt: String
    public var postHistoryInstructions: String
    public var tags: [String]
    public var creator: String
    public var characterVersion: String
    public var sourceFileName: String?
    public var sourceSpec: String?
    public var sourceSpecVersion: String?
    public var embeddedWorldbookID: UUID?
    public var regexRules: [RoleplayRegexRule]
    public var helperScripts: [RoleplayHelperScript]
    public var initialVariables: [String: JSONValue]
    public var extensions: [String: JSONValue]
    public var rawCardData: [String: JSONValue]
    public var compatibilityReport: RoleplayCompatibilityReport
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        avatarFileName: String? = nil,
        description: String = "",
        personality: String = "",
        scenario: String = "",
        firstMessage: String = "",
        alternateGreetings: [String] = [],
        messageExamples: String = "",
        creatorNotes: String = "",
        systemPrompt: String = "",
        postHistoryInstructions: String = "",
        tags: [String] = [],
        creator: String = "",
        characterVersion: String = "",
        sourceFileName: String? = nil,
        sourceSpec: String? = nil,
        sourceSpecVersion: String? = nil,
        embeddedWorldbookID: UUID? = nil,
        regexRules: [RoleplayRegexRule] = [],
        helperScripts: [RoleplayHelperScript] = [],
        initialVariables: [String: JSONValue] = [:],
        extensions: [String: JSONValue] = [:],
        rawCardData: [String: JSONValue] = [:],
        compatibilityReport: RoleplayCompatibilityReport = .init(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.avatarFileName = avatarFileName
        self.description = description
        self.personality = personality
        self.scenario = scenario
        self.firstMessage = firstMessage
        self.alternateGreetings = alternateGreetings
        self.messageExamples = messageExamples
        self.creatorNotes = creatorNotes
        self.systemPrompt = systemPrompt
        self.postHistoryInstructions = postHistoryInstructions
        self.tags = tags
        self.creator = creator
        self.characterVersion = characterVersion
        self.sourceFileName = sourceFileName
        self.sourceSpec = sourceSpec
        self.sourceSpecVersion = sourceSpecVersion
        self.embeddedWorldbookID = embeddedWorldbookID
        self.regexRules = regexRules
        self.helperScripts = helperScripts
        self.initialVariables = initialVariables
        self.extensions = extensions
        self.rawCardData = rawCardData
        self.compatibilityReport = compatibilityReport
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct PersonaProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var avatarFileName: String?
    public var description: String
    public var pronouns: String
    public var metadata: [String: JSONValue]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        avatarFileName: String? = nil,
        description: String = "",
        pronouns: String = "",
        metadata: [String: JSONValue] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.avatarFileName = avatarFileName
        self.description = description
        self.pronouns = pronouns
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SessionRoleplayBinding: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID { sessionID }
    public var sessionID: UUID
    public var characterIDs: [UUID]
    public var personaID: UUID?
    public var additionalWorldbookIDs: [UUID]
    public var selectedGreetingIndex: Int
    public var htmlRenderingEnabled: Bool
    public var helperScriptsEnabled: Bool
    public var updatedAt: Date

    public init(
        sessionID: UUID,
        characterIDs: [UUID] = [],
        personaID: UUID? = nil,
        additionalWorldbookIDs: [UUID] = [],
        selectedGreetingIndex: Int = 0,
        htmlRenderingEnabled: Bool = true,
        helperScriptsEnabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.characterIDs = characterIDs
        self.personaID = personaID
        self.additionalWorldbookIDs = additionalWorldbookIDs
        self.selectedGreetingIndex = max(0, selectedGreetingIndex)
        self.htmlRenderingEnabled = htmlRenderingEnabled
        self.helperScriptsEnabled = helperScriptsEnabled
        self.updatedAt = updatedAt
    }
}

struct RoleplayLibrarySnapshot: Codable, Sendable {
    var characters: [RoleplayCharacter] = []
    var personas: [PersonaProfile] = []
    var bindings: [SessionRoleplayBinding] = []
}

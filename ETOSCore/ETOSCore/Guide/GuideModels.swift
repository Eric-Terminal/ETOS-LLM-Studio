// ============================================================================
// GuideModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 向导的领域模型。这里的类型不依赖 SwiftUI，iOS 与 watchOS 使用同一套协议。
// ============================================================================

import Foundation

public struct GuidePageID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

public struct GuideDocumentReference: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public enum GuideSnapshotAccess: String, Codable, Hashable, Sendable {
    case readOnly
    case readWrite
    case writeOnly
}

public struct GuideSnapshotField: Codable, Hashable, Sendable {
    public let label: String
    public let value: JSONValue
    public let access: GuideSnapshotAccess

    public init(label: String, value: JSONValue, access: GuideSnapshotAccess = .readWrite) {
        self.label = label
        self.value = access == .writeOnly
            ? .string(Self.hiddenValue)
            : GuideSecretRedactor.redact(value)
        self.access = access
    }

    public static let hiddenValue = "<hidden>"
}

public struct GuidePageSnapshot: Codable, Hashable, Sendable {
    public let fields: [String: GuideSnapshotField]

    public init(fields: [String: GuideSnapshotField] = [:]) {
        self.fields = fields
    }

    public static let empty = GuidePageSnapshot()
}

public enum GuideSecretRedactor {
    public static func redact(_ value: JSONValue) -> JSONValue {
        redact(value, fieldName: nil)
    }

    public static func containsSensitiveField(_ value: JSONValue) -> Bool {
        switch value {
        case .dictionary(let values):
            return values.contains { key, child in
                isSensitiveFieldName(key) || containsSensitiveField(child)
            }
        case .array(let values):
            return values.contains(where: containsSensitiveField)
        default:
            return false
        }
    }

    private static func redact(_ value: JSONValue, fieldName: String?) -> JSONValue {
        if let fieldName, isSensitiveFieldName(fieldName) {
            return .string(GuideSnapshotField.hiddenValue)
        }
        switch value {
        case .dictionary(let values):
            return .dictionary(values.reduce(into: [String: JSONValue]()) { result, pair in
                result[pair.key] = redact(pair.value, fieldName: pair.key)
            })
        case .array(let values):
            return .array(values.map { redact($0, fieldName: nil) })
        default:
            return value
        }
    }

    private static func isSensitiveFieldName(_ fieldName: String) -> Bool {
        let normalized = fieldName
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let exactNames: Set<String> = [
            "authorization",
            "proxy_authorization",
            "cookie",
            "set_cookie",
            "api_key",
            "apikey",
            "x_api_key",
            "token",
            "credential",
            "credentials"
        ]
        return exactNames.contains(normalized)
            || normalized.contains("password")
            || normalized.contains("secret")
            || normalized.hasSuffix("_token")
    }
}

public enum GuideToolAccess: String, Codable, Hashable, Sendable {
    case read
    case proposeChange
}

public struct GuidePageTool: Codable, Hashable, Sendable {
    public let definition: InternalToolDefinition
    public let access: GuideToolAccess

    public init(definition: InternalToolDefinition, access: GuideToolAccess) {
        self.definition = definition
        self.access = access
    }
}

public enum GuideMode: String, Codable, Hashable, Sendable {
    case contextualHelp
    case modelSetup
}

public struct GuidePageDescriptor: Codable, Hashable, Sendable {
    public let id: GuidePageID
    public let title: String
    public let mode: GuideMode
    public let documents: [GuideDocumentReference]
    public let tools: [GuidePageTool]

    public init(
        id: GuidePageID,
        title: String,
        mode: GuideMode = .contextualHelp,
        documents: [GuideDocumentReference] = [],
        tools: [GuidePageTool] = []
    ) {
        self.id = id
        self.title = title
        self.mode = mode
        self.documents = documents
        self.tools = tools
    }
}

public struct GuidePageContext: Codable, Hashable, Sendable {
    public let descriptor: GuidePageDescriptor
    public let snapshot: GuidePageSnapshot

    public init(descriptor: GuidePageDescriptor, snapshot: GuidePageSnapshot) {
        self.descriptor = descriptor
        self.snapshot = snapshot
    }
}

public struct GuideSettingMutation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let label: String
    public let oldValue: JSONValue?
    public let newValue: JSONValue
    public let isSensitive: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        label: String,
        oldValue: JSONValue?,
        newValue: JSONValue,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.path = path
        self.label = label
        self.oldValue = isSensitive ? nil : oldValue
        self.newValue = isSensitive ? .string(GuideSnapshotField.hiddenValue) : newValue
        self.isSensitive = isSensitive
    }
}

public struct GuideActionProposal: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let pageID: GuidePageID
    public let toolCallID: String
    public let toolName: String
    public let summary: String
    public let mutations: [GuideSettingMutation]
    /// 执行器需要使用原始参数；它只留在内存，不会显示在预览里。
    public let arguments: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        pageID: GuidePageID,
        toolCallID: String,
        toolName: String,
        summary: String,
        mutations: [GuideSettingMutation],
        arguments: [String: JSONValue]
    ) {
        self.id = id
        self.pageID = pageID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.summary = summary
        self.mutations = mutations
        self.arguments = arguments
    }
}

public struct GuideActionExecution: Codable, Hashable, Sendable {
    public let message: String
    public let undoProposal: GuideActionProposal?

    public init(message: String, undoProposal: GuideActionProposal? = nil) {
        self.message = message
        self.undoProposal = undoProposal
    }
}

public enum GuideRoute: String, Codable, CaseIterable, Sendable {
    case builtIn
    case userModel
}

public enum GuideModelSetupState: String, Codable, Hashable, Sendable {
    case needsProvider
    case needsCredential
    case needsModel
    case needsActivationOrSelection
    case ready
}

public struct GuideConversationMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Hashable, Sendable {
        case user
        case assistant
        case tool
        case error
    }

    public let id: UUID
    public let role: Role
    public var content: String
    public let toolCalls: [InternalToolCall]

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCalls: [InternalToolCall] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }
}

public enum GuideCompletionEvent: Sendable {
    case contentDelta(String)
    case completed(ChatMessage)
}

enum GuideStreamTerminationPolicy {
    static func shouldFinish(after termination: ChatMessagePart.StreamTermination?) -> Bool {
        guard let termination else { return false }
        switch termination {
        case .completed, .failed:
            return true
        }
    }
}

public protocol GuideCompletionClient: Sendable {
    func events(
        messages: [ChatMessage],
        tools: [InternalToolDefinition],
        sessionID: UUID
    ) -> AsyncThrowingStream<GuideCompletionEvent, Error>
}

public enum GuideError: LocalizedError {
    case noActivePage
    case pageChanged
    case unsupportedTool(String)
    case invalidToolArguments
    case invalidResponse
    case missingRunnableModel
    case sourceUnavailable

    public var errorDescription: String? {
        switch self {
        case .noActivePage:
            return NSLocalizedString("当前页面尚未接入向导。", comment: "Guide page unavailable error")
        case .pageChanged:
            return NSLocalizedString("页面已经变化，请重新生成这项修改。", comment: "Guide page changed error")
        case .unsupportedTool(let name):
            return String(
                format: NSLocalizedString("当前页面不支持向导工具“%@”。", comment: "Guide unsupported tool error"),
                name
            )
        case .invalidToolArguments:
            return NSLocalizedString("向导返回的修改参数无法读取。", comment: "Guide invalid tool arguments error")
        case .invalidResponse:
            return NSLocalizedString("向导服务返回了无法识别的响应。", comment: "Guide invalid response error")
        case .missingRunnableModel:
            return NSLocalizedString("所选向导模型当前不可用。", comment: "Guide selected model unavailable error")
        case .sourceUnavailable:
            return NSLocalizedString("当前构建无法安全定位对应源码。", comment: "Guide source unavailable error")
        }
    }
}

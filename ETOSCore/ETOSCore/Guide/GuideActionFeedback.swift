import Foundation

/// 只描述客户端已完成的动作，不含配置原文；不写入持久对话，恢复历史不能推断提案仍有效。
public struct GuideActionFeedback: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case executed
        case rejected
        case undone
    }

    public let status: Status
    public let pageID: GuidePageID
    public let toolName: String
    public let message: String
    public let requiresConfirmation: Bool

    public init(status: Status, pageID: GuidePageID, toolName: String, message: String) {
        self.status = status
        self.pageID = pageID
        self.toolName = toolName
        self.message = message
        self.requiresConfirmation = false
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case pageID = "page_id"
        case toolName = "tool_name"
        case message
        case requiresConfirmation = "requires_confirmation"
    }

    public var encodedResult: String {
        GuideToolArguments.encodedResult(.dictionary([
            "status": .string(status.rawValue), "page_id": .string(pageID.rawValue),
            "tool_name": .string(toolName), "message": .string(message),
            "requires_confirmation": .bool(requiresConfirmation)
        ]))
    }
}

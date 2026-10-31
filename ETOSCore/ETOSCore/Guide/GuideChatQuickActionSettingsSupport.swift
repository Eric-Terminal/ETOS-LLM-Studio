import Foundation

/// 两端共用有序标识校验；向导只修改配置，不调用聊天功能。
public enum GuideChatQuickActionSettingsSupport {
    public static let actionsSchema = schema(minimumCount: 1)
    public static let toolbarSchema = schema(minimumCount: 0)

    public static func actions(from value: JSONValue, allowsEmpty: Bool = false) throws -> [ChatQuickAction] {
        guard case .array(let items) = value,
              (allowsEmpty || !items.isEmpty), items.count <= ChatQuickAction.allCases.count else {
            throw GuideError.invalidToolArguments
        }
        var seen = Set<ChatQuickAction>()
        return try items.map { item in
            guard case .string(let identifier) = item,
                  let action = ChatQuickAction(rawValue: identifier), seen.insert(action).inserted else {
                throw GuideError.invalidToolArguments
            }
            return action
        }
    }

    private static func schema(minimumCount: Int) -> JSONValue {
        .dictionary([
            "type": .string("array"), "minItems": .int(minimumCount),
            "maxItems": .int(ChatQuickAction.allCases.count), "uniqueItems": .bool(true),
            "items": .dictionary([
                "type": .string("string"), "enum": .array(ChatQuickAction.allCases.map { .string($0.rawValue) })
            ])
        ])
    }
}

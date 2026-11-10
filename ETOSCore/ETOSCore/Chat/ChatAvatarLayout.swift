import Foundation

public enum ChatAvatarPosition: String, Codable, CaseIterable, Sendable {
    case side, above
}

public struct ChatAvatarLayout: Codable, Equatable, Sendable {
    public var position: ChatAvatarPosition = .side
    public var edgeInset: Double = 6
    public var messageSpacing: Double = 6
    public var showsTimestamp = false

    public init() {}

    /// 上方布局不占正文的横向空间；三端均用同一数值计算头像与正文宽度。
    public func sideWidth(avatarDiameter: Double) -> Double {
        position == .side ? avatarDiameter + messageSpacing : 0
    }
}

struct ChatAvatarNames: Equatable, Sendable {
    var assistant: String?
    var user: String?

    /// 名称取身份本身，与头像图片是否缺失无关；默认名称留给界面按当前语言显示。
    static func resolve(prompt: GlobalSystemPromptEntry?, character: RoleplayCharacter?, persona: PersonaProfile?) -> Self {
        Self(assistant: character?.name ?? prompt?.title, user: persona?.name)
    }
}

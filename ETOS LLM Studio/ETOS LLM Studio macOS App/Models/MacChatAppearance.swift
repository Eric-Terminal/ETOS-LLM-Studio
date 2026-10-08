import ETOSCore
import Foundation
import SwiftUI

enum MacAppearanceTextGroup: String, CaseIterable, Identifiable, Sendable {
    case userLight, userDark, assistantLight, assistantDark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .userLight: NSLocalizedString("用户白天文字样式", comment: "")
        case .userDark: NSLocalizedString("用户夜览文字样式", comment: "")
        case .assistantLight: NSLocalizedString("助手白天文字样式", comment: "")
        case .assistantDark: NSLocalizedString("助手夜览文字样式", comment: "")
        }
    }
    var bodyPath: WritableKeyPath<ChatAppearanceProfile, ChatAppearanceColorSlot> {
        switch self {
        case .userLight: \.userLightText
        case .userDark: \.userDarkText
        case .assistantLight: \.assistantLightText
        case .assistantDark: \.assistantDarkText
        }
    }
    var stylesPath: WritableKeyPath<ChatAppearanceProfile, ChatAppearanceTextStyleColors> {
        switch self {
        case .userLight: \.userLightTextStyles
        case .userDark: \.userDarkTextStyles
        case .assistantLight: \.assistantLightTextStyles
        case .assistantDark: \.assistantDarkTextStyles
        }
    }
    static func resolve(outgoing: Bool, dark: Bool) -> Self {
        outgoing ? (dark ? .userDark : .userLight) : (dark ? .assistantDark : .assistantLight)
    }
}

/// 颜色字符串在后台转换。聊天行只选择现成的角色/明暗分支。
struct MacChatTextPalette: @unchecked Sendable {
    let body: Color?
    let emphasis: Color?
    let strong: Color?
    let code: Color?
    init(body: ChatAppearanceColorSlot, styles: ChatAppearanceTextStyleColors) {
        self.body = body.isEnabled ? ChatAppearanceColorCodec.color(from: body.hex, fallback: .primary) : nil
        emphasis = styles.emphasis.isEnabled ? ChatAppearanceColorCodec.color(from: styles.emphasis.hex, fallback: .primary) : nil
        strong = styles.strong.isEnabled ? ChatAppearanceColorCodec.color(from: styles.strong.hex, fallback: .primary) : nil
        code = styles.code.isEnabled ? ChatAppearanceColorCodec.color(from: styles.code.hex, fallback: .primary) : nil
    }
    static let automatic = MacChatTextPalette(body: .defaultLightText, styles: .init(defaultHex: "1C1C1EFF"))
}

struct MacChatPalette: @unchecked Sendable {
    let userBubble: Color
    let assistantBubble: Color?
    let text: [MacAppearanceTextGroup: MacChatTextPalette]
    init(_ profile: ChatAppearanceProfile) {
        userBubble = profile.userBubble.isEnabled
            ? ChatAppearanceColorCodec.color(from: profile.userBubble.hex, fallback: .accentColor) : .accentColor
        assistantBubble = profile.assistantBubble.isEnabled
            ? ChatAppearanceColorCodec.color(from: profile.assistantBubble.hex, fallback: .primary) : nil
        text = Dictionary(uniqueKeysWithValues: MacAppearanceTextGroup.allCases.map { group in
            (group, MacChatTextPalette(body: profile[keyPath: group.bodyPath], styles: profile[keyPath: group.stylesPath]))
        })
    }
}

struct MacAppearanceCatalog: Sendable {
    struct Profile: Identifiable, Sendable { let id: String; let title: String; let value: ChatAppearanceProfile }
    struct Schedule: Identifiable, Sendable { let id: String; let title: String; let value: ChatAppearanceScheduleRule }
    let configuration: ChatAppearanceProfileConfiguration
    let defaultProfile: ChatAppearanceProfile
    let profiles: [Profile]
    let profileIDs: [String]
    let schedules: [Schedule]
    let activeTitle: String
    let activeProfile: ChatAppearanceProfile
    let nextBoundary: Date?
    let guideValue: JSONValue

    init(_ configuration: ChatAppearanceProfileConfiguration, date: Date = .now, calendar: Calendar = .current) {
        self.configuration = configuration
        defaultProfile = configuration.defaultProfile
        profiles = configuration.profiles.map { .init(id: $0.id, title: Self.title($0), value: $0) }
        profileIDs = profiles.map(\.id)
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.title) })
        schedules = configuration.scheduleRules.map {
            .init(id: $0.id, title: String(format: NSLocalizedString("%@：%@", comment: ""), names[$0.profileID] ?? $0.profileID, $0.displayTimeRange), value: $0)
        }
        activeProfile = configuration.activeProfile(at: date, calendar: calendar)
        activeTitle = Self.title(activeProfile)
        nextBoundary = configuration.nextBoundary(after: date, calendar: calendar)
        guideValue = .array(profiles.map { .dictionary(["id": .string($0.id), "name": .string($0.title)]) })
    }
    static func title(_ profile: ChatAppearanceProfile) -> String {
        profile.isDefaultProfile && profile.name == ChatAppearanceProfile.defaultProfileID
            ? NSLocalizedString("默认配置", comment: "") : profile.name
    }
}

enum MacAppearanceChange: Sendable {
    case profile(ChatAppearanceProfile)
    case deleteProfile(String)
    case schedule(ChatAppearanceScheduleRule)
    case deleteSchedule(String)

    func applying(to original: ChatAppearanceProfileConfiguration) throws -> ChatAppearanceProfileConfiguration {
        var result = original
        switch self {
        case .profile(let profile):
            if let index = result.profiles.firstIndex(where: { $0.id == profile.id }) { result.profiles[index] = profile }
            else { result.profiles.append(profile) }
        case .deleteProfile(let id):
            guard id != ChatAppearanceProfile.defaultProfileID else { throw ChatAppearanceProfileError.defaultProfileCannotBeDeleted }
            result.profiles.removeAll { $0.id == id }
            result.scheduleRules.removeAll { $0.profileID == id }
        case .schedule(let rule):
            if let index = result.scheduleRules.firstIndex(where: { $0.id == rule.id }) { result.scheduleRules[index] = rule }
            else { result.scheduleRules.append(rule) }
        case .deleteSchedule(let id): result.scheduleRules.removeAll { $0.id == id }
        }
        return result
    }
}

import Foundation
import Testing
@testable import ETOSCore

struct ChatAvatarTests {
    @Test("提示词头像只覆盖 AI，切换及缺失时按优先级回退")
    func promptSelection() {
        let first = UUID(), second = UUID()
        var configuration = ChatAvatarConfiguration()
        configuration.files = ["assistant": "default.png", "user": "me.png",
                               ChatAvatarTarget.prompt(first).key: "first.png",
                               ChatAvatarTarget.prompt(second).key: "second.png"]
        #expect(ChatAvatarPair.resolve(configuration: configuration, promptID: first, character: nil, persona: nil)
                == ChatAvatarPair(assistant: "first.png", user: "me.png"))
        #expect(ChatAvatarPair.resolve(configuration: configuration, promptID: second, character: nil, persona: nil).assistant == "second.png")
        #expect(ChatAvatarPair.resolve(configuration: configuration, promptID: UUID(), character: nil, persona: nil).assistant == "default.png")
        #expect(ChatAvatarPair.resolve(configuration: configuration, promptID: nil, character: nil, persona: nil).user == "me.png")
    }

    @Test("酒馆双方头像优先且独立回退，不依赖内联内容")
    func roleplayPriority() {
        let prompt = UUID()
        var configuration = ChatAvatarConfiguration()
        configuration.files = ["assistant": "default.png", "user": "me.png", ChatAvatarTarget.prompt(prompt).key: "prompt.png"]
        var character = RoleplayCharacter(name: "角色", avatarFileName: "character.png")
        var persona = PersonaProfile(name: "身份", avatarFileName: "persona.png")
        #expect(ChatAvatarPair.resolve(configuration: configuration, promptID: prompt, character: character, persona: persona)
                == ChatAvatarPair(assistant: "character.png", user: "persona.png"))
        character.avatarFileName = nil
        #expect(ChatAvatarPair.resolve(configuration: configuration, promptID: prompt, character: character, persona: persona)
                == ChatAvatarPair(assistant: "prompt.png", user: "persona.png"))
        persona.avatarFileName = nil
        #expect(ChatAvatarPair.resolve(configuration: configuration, promptID: prompt, character: character, persona: persona).user == "me.png")
    }

    @Test("头像显示开关独立持久化，不改已有图片引用")
    func configurationRoundTrip() throws {
        var configuration = ChatAvatarConfiguration()
        #expect(!configuration.showAssistant && !configuration.showUser)
        configuration.showAssistant = true
        configuration.files["assistant"] = "retained.png"
        let restored = try JSONDecoder().decode(ChatAvatarConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(restored.showAssistant && !restored.showUser)
        #expect(restored.files["assistant"] == "retained.png")
        for assistant in [false, true] {
            for user in [false, true] {
                configuration.showAssistant = assistant
                configuration.showUser = user
                #expect(configuration.isVisible(role: .assistant) == assistant)
                #expect(configuration.isVisible(role: .user) == user)
                #expect(!configuration.isVisible(role: .tool))
                #expect(!configuration.isVisible(role: .system))
                #expect(!configuration.isVisible(role: .error))
            }
        }
        #expect(throws: CocoaError.self) { try ChatAvatarStore.prepareImage(Data("不是图片".utf8)) }
    }

    @Test("头像向导说明覆盖三端、优先级与图片访问边界")
    func guideKnowledge() throws {
        #expect(GuideDocumentCatalog.documents.contains { $0.id == "chat-avatars" })
        let chinese = GuideChatAvatarKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("原生确认"))
        #expect(chinese.content.contains("不公开图片、路径或下载链接"))
        #expect(chinese.content.contains("HTML"))
        let english = GuideChatAvatarKnowledge.document(locale: Locale(identifier: "fr"))
        #expect(english.content.contains("watchOS"))
        #expect(english.content.contains("off by default"))
        #expect(english.content.contains("first valid character"))
        for field in ["avatar_position", "avatar_edge_inset", "avatar_message_spacing", "avatar_header_timestamp"] {
            #expect(chinese.content.contains(field))
            #expect(english.content.contains(field))
        }
    }

    @Test("旧头像配置升级保留双方开关和图片，新增布局使用紧凑侧边默认值")
    func legacyConfiguration() throws {
        let data = Data(#"{"showAssistant":true,"showUser":false,"files":{"assistant":"kept.png","user":"me.png","prompt-test":"prompt.png"}}"#.utf8)
        let restored = try JSONDecoder().decode(ChatAvatarConfiguration.self, from: data)
        #expect(restored.showAssistant && !restored.showUser)
        #expect(restored.files == ["assistant": "kept.png", "user": "me.png", "prompt-test": "prompt.png"])
        #expect(restored.layout == ChatAvatarLayout())
        #expect(restored.layout.position == .side)
        #expect(!restored.layout.showsTimestamp)
    }

    @Test("上方布局不扣除侧边宽度，布局与间距完整持久化")
    func layoutRoundTrip() throws {
        var configuration = ChatAvatarConfiguration()
        configuration.showAssistant = true
        configuration.files["assistant"] = "kept.png"
        for position in ChatAvatarPosition.allCases {
            for spacing in [0.0, 6.0, 24.0] {
                configuration.layout.position = position
                configuration.layout.edgeInset = 24 - spacing
                configuration.layout.messageSpacing = spacing
                configuration.layout.showsTimestamp = true
                let restored = try JSONDecoder().decode(ChatAvatarConfiguration.self, from: JSONEncoder().encode(configuration))
                #expect(restored == configuration)
                for diameter in [24.0, 32.0] {
                    #expect(restored.layout.sideWidth(avatarDiameter: diameter) == (position == .side ? diameter + spacing : 0))
                }
            }
        }
    }

    @Test("名称随当前身份切换，角色未设置头像也不会回退成提示词名称")
    func headerNames() {
        let first = GlobalSystemPromptEntry(title: "第一条提示词", content: "")
        let second = GlobalSystemPromptEntry(title: "第二条提示词", content: "")
        #expect(ChatAvatarNames.resolve(prompt: first, character: nil, persona: nil).assistant == first.title)
        #expect(ChatAvatarNames.resolve(prompt: second, character: nil, persona: nil).assistant == second.title)
        let character = RoleplayCharacter(name: "酒馆角色")
        let persona = PersonaProfile(name: "用户身份")
        let names = ChatAvatarNames.resolve(prompt: first, character: character, persona: persona)
        #expect(names == ChatAvatarNames(assistant: character.name, user: persona.name))
        #expect(ChatAvatarNames.resolve(prompt: nil, character: nil, persona: nil) == ChatAvatarNames())
    }
}

@Suite("聊天头像图片保存", .serialized)
struct ChatAvatarPersistenceTests {
    @Test("角色头像替换保留角色内容，损坏图片不覆盖已有头像，清除不删除原始资源")
    func characterAvatarReplacement() throws {
        let roleplay = RoleplayStore.shared
        let originalName = "avatar-test-\(UUID().uuidString).png"
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="))
        let png = try ChatAvatarStore.prepareImage(data)
        #expect(Persistence.saveImage(png, fileName: originalName) != nil)
        let character = RoleplayCharacter(name: "头像回归角色", avatarFileName: originalName,
            description: "保留描述", firstMessage: "保留开场", extensions: ["vendor": .string("preserved")])
        try roleplay.saveCharacterDraft(character, replacing: nil)
        defer {
            roleplay.deleteCharacter(id: character.id)
            Persistence.deleteImage(fileName: originalName)
        }

        try ChatAvatarStore.shared.setImage(png, for: .character(character.id))
        let saved = try #require(roleplay.character(id: character.id))
        let customName = try #require(saved.avatarFileName)
        #expect(customName != originalName)
        #expect(saved.description == character.description)
        #expect(saved.firstMessage == character.firstMessage)
        #expect(saved.extensions == character.extensions)
        #expect(Persistence.loadImage(fileName: customName) != nil)
        #expect(throws: CocoaError.self) {
            try ChatAvatarStore.shared.setImage(Data("无效图片".utf8), for: .character(character.id))
        }
        #expect(roleplay.character(id: character.id)?.avatarFileName == customName)
        try ChatAvatarStore.shared.setImage(nil, for: .character(character.id))
        #expect(roleplay.character(id: character.id)?.avatarFileName == nil)
        #expect(Persistence.loadImage(fileName: originalName) != nil)
        #expect(Persistence.loadImage(fileName: customName) == nil)
    }
}

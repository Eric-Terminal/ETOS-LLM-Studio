import ETOSCore
import Foundation
import SwiftUI
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacAppearanceTests {
    @Test("删除颜色配置只移除关联时间段，默认配置不能删除")
    func deletionKeepsOtherProfiles() throws {
        let first = ChatAppearanceProfile(id: "first", name: "第一套"), second = ChatAppearanceProfile(id: "second", name: "第二套")
        let configuration = ChatAppearanceProfileConfiguration(profiles: [.defaultProfile, first, second], scheduleRules: [
            .init(profileID: first.id, startMinuteOfDay: 60, endMinuteOfDay: 120),
            .init(profileID: second.id, startMinuteOfDay: 120, endMinuteOfDay: 180)
        ])
        let changed = try MacAppearanceChange.deleteProfile(first.id).applying(to: configuration)
        #expect(changed.profiles == [.defaultProfile, second])
        #expect(changed.scheduleRules == [configuration.scheduleRules[1]])
        #expect(throws: ChatAppearanceProfileError.self) { try MacAppearanceChange.deleteProfile("default").applying(to: configuration) }
    }

    @Test("修改配置保留其他配置及其规则，新增配置不替换默认项")
    func updateKeepsOtherData() throws {
        let original = ChatAppearanceProfileConfiguration()
        let profile = ChatAppearanceProfile(id: "new", name: "新配置")
        var added = try MacAppearanceChange.profile(profile).applying(to: original)
        var changed = profile; changed.userLightTextStyles.customRules = [.init(exactText: "内容", colorHex: "12345678")]
        added = try MacAppearanceChange.profile(changed).applying(to: added)
        #expect(added.profiles == [.defaultProfile, changed])
        #expect(original.profiles == [.defaultProfile])
    }

    @Test("用户和助手的明暗配色独立解析，关闭自定义后回到原生文字色")
    func paletteResolvesRoleAndScheme() {
        var profile = ChatAppearanceProfile.defaultProfile
        profile.userLightText = .init(isEnabled: true, hex: "112233FF")
        profile.assistantDarkText = .init(isEnabled: true, hex: "445566FF")
        let palette = MacChatPalette(profile)
        #expect(palette.text[.resolve(outgoing: true, dark: false)]?.body.flatMap(ChatAppearanceColorCodec.hexRGBA(from:)) == "112233FF")
        #expect(palette.text[.resolve(outgoing: false, dark: true)]?.body.flatMap(ChatAppearanceColorCodec.hexRGBA(from:)) == "445566FF")
        #expect(palette.text[.userDark]?.body == nil)
        #expect(palette.text[.assistantLight]?.body == nil)
    }

    @Test("后台准备浅深色规则文本，正文、原文与行内代码保持正确边界")
    func rulesPrepareForBothSchemes() async throws {
        var profile = ChatAppearanceProfile.defaultProfile
        profile.assistantLightTextStyles.customRules = [.init(exactText: "目标", colorHex: "FF0000FF")]
        profile.assistantDarkTextStyles.customRules = [.init(exactText: "目标", colorHex: "0000FFFF")]
        let message = ChatMessage(role: .assistant, content: "**目标** `目标`")
        let row = try #require(try await MacMessagePresentationStore().prepare([message], markdown: true, language: "zh-Hans", appearance: profile).first)
        let light = try #require(row.content.lightRules), dark = try #require(row.content.darkRules)
        #expect(colors(light) == ["FF0000FF"])
        #expect(colors(dark) == ["0000FFFF"])
        #expect(row.content.source == message.content && row.message == message)
        #expect(row.content.markdown != nil)
    }

    @Test("移除最后一条规则后不复用旧颜色，未变化 Markdown 解析仍复用")
    func removalInvalidatesColorsOnly() async throws {
        let store = MacMessagePresentationStore()
        var profile = ChatAppearanceProfile.defaultProfile
        profile.assistantLightTextStyles.customRules = [.init(exactText: "目标", colorHex: "FF0000FF")]
        let message = ChatMessage(role: .assistant, content: "目标")
        let first = try #require(try await store.prepare([message], markdown: true, language: "en", appearance: profile).first)
        let restored = try #require(try await store.prepare([message], markdown: true, language: "en", appearance: .defaultProfile).first)
        #expect(first.content.lightRules != nil && restored.content.lightRules == nil)
        #expect(first.content.id == restored.content.id)
        #expect(restored.message == message)
    }

    @Test("用户截断预览也应用规则，完整原文仍保留用于复制和模型输入")
    func truncatedPreviewUsesOwnColorCache() async throws {
        var profile = ChatAppearanceProfile.defaultProfile
        profile.userLightTextStyles.customRules = [.init(exactText: "目标", colorHex: "FF0000FF")]
        let message = ChatMessage(role: .user, content: "目标以及更多内容")
        let row = try #require(try await MacMessagePresentationStore().prepare([message], markdown: true, language: "en", userPreviewLimit: 2, appearance: profile).first)
        #expect(row.userPreview?.source == "目标…")
        #expect(row.userPreview?.lightRules != nil)
        #expect(row.userPreview?.id != row.content.id)
        #expect(row.content.source == message.content && row.message.content == message.content)
    }

    @Test("包含专门 Markdown 块时保留原渲染，不将代码块降为规则纯文本")
    func specializedMarkdownKeepsOriginalRenderer() async throws {
        var profile = ChatAppearanceProfile.defaultProfile
        profile.assistantLightTextStyles.customRules = [.init(exactText: "目标", colorHex: "FF0000FF")]
        let message = ChatMessage(role: .assistant, content: "目标\n```swift\nlet x = 1\n```")
        let row = try #require(try await MacMessagePresentationStore().prepare([message], markdown: true, language: "en", appearance: profile).first)
        #expect(row.content.lightRules == nil && row.content.markdown != nil)
    }

    @Test("重置颜色保留配置身份与名称，并清除草稿中的自定义规则")
    @MainActor func resetPreservesIdentity() {
        var profile = ChatAppearanceProfile(id: "custom", name: "我的配置")
        profile.userLightTextStyles.customRules = [.init(exactText: "内容", colorHex: "123456FF")]
        let draft = MacAppearanceProfileDraft(profile)
        draft.reset()
        #expect(draft.profile == ChatAppearanceProfile(id: profile.id, name: profile.name))
        #expect(profile.userLightTextStyles.customRules.count == 1)
    }

    private func colors(_ value: AttributedString) -> [String] {
        value.runs.compactMap { $0.foregroundColor.flatMap(ChatAppearanceColorCodec.hexRGBA(from:)) }
    }
}

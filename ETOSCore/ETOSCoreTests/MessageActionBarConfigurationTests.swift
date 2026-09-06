// ============================================================================
// MessageActionBarConfigurationTests.swift
// ============================================================================
// 气泡功能栏配置测试
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("气泡功能栏配置测试")
struct MessageActionBarConfigurationTests {

    @Test("iOS 默认配置只在助手气泡启用多版本切换")
    func iOSDefaultConfigurationOnlyKeepsVersionSwitcher() {
        let configuration = MessageActionBarConfiguration.iOSDefaultConfiguration

        #expect(configuration.assistantItems == [.versionSwitcher])
        #expect(configuration.userItems.isEmpty)
        #expect(configuration.assistantAlignment == .trailing)
        #expect(configuration.userAlignment == .trailing)
        #expect(configuration.showsOuterBorder == false)
        #expect(configuration.fontScale == FontLibrary.defaultFontScale)
    }

    @Test("watchOS 默认配置不启用气泡功能栏项目")
    func watchOSDefaultConfigurationKeepsActionBarEmpty() {
        let configuration = MessageActionBarConfiguration.watchOSDefaultConfiguration

        #expect(configuration.assistantItems.isEmpty)
        #expect(configuration.userItems.isEmpty)
        #expect(configuration.assistantAlignment == .trailing)
        #expect(configuration.userAlignment == .trailing)
        #expect(configuration.showsOuterBorder == false)
        #expect(configuration.fontScale == FontLibrary.defaultFontScale)
    }

    @Test("当前平台默认配置符合平台策略")
    func defaultConfigurationFollowsCurrentPlatformPolicy() {
        let configuration = MessageActionBarConfiguration.defaultConfiguration

        #if os(watchOS)
        #expect(configuration.assistantItems.isEmpty)
        #else
        #expect(configuration.assistantItems == [.versionSwitcher])
        #endif
        #expect(configuration.userItems.isEmpty)
        #expect(configuration.assistantAlignment == .trailing)
        #expect(configuration.userAlignment == .trailing)
        #expect(configuration.showsOuterBorder == false)
        #expect(configuration.fontScale == FontLibrary.defaultFontScale)
    }

    @Test("配置编解码会去重并保留助手用户独立顺序")
    func configurationRoundTripKeepsIndependentOrderedItems() {
        let configuration = MessageActionBarConfiguration(
            assistantItems: [.quickRetry, .copyMessage, .costEstimate, .quickRetry, .versionSwitcher],
            userItems: [.requestTime, .inputTokens, .costEstimate, .outputTokens, .requestTime],
            assistantAlignment: .leading,
            userAlignment: .trailing,
            showsOuterBorder: true,
            fontScale: 1.35
        )

        let decoded = MessageActionBarConfiguration.decoded(from: configuration.encodedString())

        #expect(decoded.assistantItems == [.quickRetry, .copyMessage, .costEstimate, .versionSwitcher])
        #expect(decoded.userItems == [.requestTime, .inputTokens, .costEstimate, .outputTokens])
        #expect(decoded.assistantAlignment == .leading)
        #expect(decoded.userAlignment == .trailing)
        #expect(decoded.showsOuterBorder == true)
        #expect(decoded.fontScale == 1.35)
    }

    @Test("旧配置缺少外围边框字段时默认关闭")
    func legacyConfigurationDefaultsOuterBorderToOff() {
        let rawValue = #"{"assistantItems":["versionSwitcher"],"userItems":[],"assistantAlignment":"trailing","userAlignment":"trailing"}"#

        let decoded = MessageActionBarConfiguration.decoded(from: rawValue)

        #expect(decoded.assistantItems == [.versionSwitcher])
        #expect(decoded.userItems.isEmpty)
        #expect(decoded.showsOuterBorder == false)
        #expect(decoded.fontScale == FontLibrary.defaultFontScale)
    }

    @Test("功能栏字号倍率会限制在允许范围内")
    func fontScaleIsClampedToSupportedRange() {
        let minimumConfiguration = MessageActionBarConfiguration(
            assistantItems: [],
            userItems: [],
            assistantAlignment: .trailing,
            userAlignment: .trailing,
            fontScale: 0.1
        )
        let maximumConfiguration = MessageActionBarConfiguration(
            assistantItems: [],
            userItems: [],
            assistantAlignment: .trailing,
            userAlignment: .trailing,
            fontScale: 5
        )

        #expect(minimumConfiguration.fontScale == FontLibrary.minimumFontScale)
        #expect(maximumConfiguration.fontScale == FontLibrary.maximumFontScale)
    }

    @Test("用户气泡配置会过滤重试和多版本切换")
    func userConfigurationFiltersAssistantOnlyItems() {
        let configuration = MessageActionBarConfiguration(
            assistantItems: [.quickRetry, .versionSwitcher],
            userItems: [.quickRetry, .copyMessage, .versionSwitcher, .requestTime],
            assistantAlignment: .trailing,
            userAlignment: .leading
        )

        #expect(configuration.assistantItems == [.quickRetry, .versionSwitcher])
        #expect(configuration.userItems == [.copyMessage, .requestTime])
    }

    @Test("重试可用性会一次性预计算可操作消息")
    func retryAvailabilityPrecomputesMessageIDs() {
        let firstUser = ChatMessage(role: .user, content: "Hi")
        let assistant = ChatMessage(role: .assistant, content: "Hello")
        let lastUser = ChatMessage(role: .user, content: "Again")
        let messages = [firstUser, assistant, lastUser]

        let idleIDs = MessageActionBarAvailability.retryableMessageIDs(in: messages, isSending: false)
        let sendingIDs = MessageActionBarAvailability.retryableMessageIDs(in: messages, isSending: true)

        #expect(idleIDs == Set(messages.map(\.id)))
        #expect(sendingIDs == [lastUser.id])
    }

    @Test("朗读项目往返保留顺序并过滤用户气泡中的朗读入口")
    func readAloudConfigurationRoundTrip() {
        let configuration = MessageActionBarConfiguration(
            assistantItems: [.readAloud, .copyMessage, .readAloud, .versionSwitcher],
            userItems: [.copyMessage, .readAloud],
            assistantAlignment: .leading,
            userAlignment: .trailing
        )
        let restored = MessageActionBarConfiguration.decoded(from: configuration.encodedString())

        #expect(restored.assistantItems == [.readAloud, .copyMessage, .versionSwitcher])
        #expect(restored.userItems == [.copyMessage])
        #expect(MessageActionBarItem.supportedItems(for: .assistant).contains(.readAloud))
        #expect(!MessageActionBarItem.supportedItems(for: .user).contains(.readAloud))
    }

    @Test("功能栏朗读仅提供给有正文的助手、工具和系统消息")
    func readAloudAvailabilityMatchesMessageActions() {
        for role in [MessageRole.assistant, .tool, .system] {
            #expect(MessageActionBarAvailability.canReadAloud(ChatMessage(role: role, content: "可朗读的正文")))
            #expect(!MessageActionBarAvailability.canReadAloud(ChatMessage(role: role, content: "")))
        }
        for role in [MessageRole.user, .error] {
            #expect(!MessageActionBarAvailability.canReadAloud(ChatMessage(role: role, content: "不提供朗读入口")))
        }
    }

    @Test("向导接受朗读配置并随消息类型更新可选值")
    func guideReadAloudSchemaFollowsRole() throws {
        let value = JSONValue.array([.string("readAloud"), .string("copyMessage")])
        #expect(try GuideDisplayActionSettingsSupport.normalizeMessageActionItems(value) == value)
        #expect(try GuideDisplayActionSettingsSupport.messageActionItems(from: value) == [.readAloud, .copyMessage])

        for role in MessageActionBarRole.allCases {
            let schema = GuideDisplayActionSettingsSupport.messageActionItemsSchema(for: role)
            guard case .dictionary(let fields) = schema,
                  case .dictionary(let items)? = fields["items"],
                  case .array(let values)? = items["enum"] else {
                Issue.record("功能栏向导缺少可选项目声明")
                return
            }
            #expect(values.contains(.string("readAloud")) == (role == .assistant))
        }
    }
}

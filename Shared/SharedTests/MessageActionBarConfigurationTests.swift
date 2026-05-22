// ============================================================================
// MessageActionBarConfigurationTests.swift
// ============================================================================
// 气泡功能栏配置测试
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("气泡功能栏配置测试")
struct MessageActionBarConfigurationTests {

    @Test("iOS 默认配置只在助手气泡启用多版本切换")
    func iOSDefaultConfigurationOnlyKeepsVersionSwitcher() {
        let configuration = MessageActionBarConfiguration.iOSDefaultConfiguration

        #expect(configuration.assistantItems == [.versionSwitcher])
        #expect(configuration.userItems.isEmpty)
        #expect(configuration.assistantAlignment == .trailing)
        #expect(configuration.userAlignment == .trailing)
    }

    @Test("watchOS 默认配置不启用气泡功能栏项目")
    func watchOSDefaultConfigurationKeepsActionBarEmpty() {
        let configuration = MessageActionBarConfiguration.watchOSDefaultConfiguration

        #expect(configuration.assistantItems.isEmpty)
        #expect(configuration.userItems.isEmpty)
        #expect(configuration.assistantAlignment == .trailing)
        #expect(configuration.userAlignment == .trailing)
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
    }

    @Test("配置编解码会去重并保留助手用户独立顺序")
    func configurationRoundTripKeepsIndependentOrderedItems() {
        let configuration = MessageActionBarConfiguration(
            assistantItems: [.quickRetry, .copyMessage, .quickRetry, .versionSwitcher],
            userItems: [.requestTime, .inputTokens, .outputTokens, .requestTime],
            assistantAlignment: .leading,
            userAlignment: .trailing
        )

        let decoded = MessageActionBarConfiguration.decoded(from: configuration.encodedString())

        #expect(decoded.assistantItems == [.quickRetry, .copyMessage, .versionSwitcher])
        #expect(decoded.userItems == [.requestTime, .inputTokens, .outputTokens])
        #expect(decoded.assistantAlignment == .leading)
        #expect(decoded.userAlignment == .trailing)
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
}

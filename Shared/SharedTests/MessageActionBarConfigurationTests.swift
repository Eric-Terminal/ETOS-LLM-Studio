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

    @Test("默认配置只在助手气泡启用多版本切换")
    func defaultConfigurationOnlyKeepsVersionSwitcher() {
        let configuration = MessageActionBarConfiguration.defaultConfiguration

        #expect(configuration.assistantItems == [.versionSwitcher])
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

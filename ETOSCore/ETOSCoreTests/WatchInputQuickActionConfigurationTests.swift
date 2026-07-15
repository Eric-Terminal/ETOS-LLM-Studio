// ============================================================================
// WatchInputQuickActionConfigurationTests.swift
// ============================================================================
// watchOS 输入栏快捷功能配置测试
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("watchOS 输入栏快捷功能配置测试")
struct WatchInputQuickActionConfigurationTests {

    @Test("默认配置保持当前输入栏左右快捷功能")
    func defaultConfigurationKeepsCurrentLayout() {
        let configuration = WatchInputQuickActionConfiguration.defaultConfiguration

        #expect(configuration.leadingActions == [
            .requestControls,
            .sessionHistory,
            .contextCompression
        ])
        #expect(configuration.trailingActions == [
            .roleplayScripts,
            .addAttachment,
            .clearInput
        ])
    }

    @Test("配置编解码保留左右分组与用户顺序")
    func roundTripKeepsEdgesAndOrder() {
        let configuration = WatchInputQuickActionConfiguration(
            leadingActions: [.dailyPulse, .sessionHistory, .settings],
            trailingActions: [.imageGallery, .contextCompression, .toolCenter]
        )

        let decoded = WatchInputQuickActionConfiguration.decoded(
            from: configuration.encodedString()
        )

        #expect(decoded == configuration)
    }

    @Test("重复功能只保留第一次出现的位置")
    func duplicateActionsKeepFirstPlacement() {
        let configuration = WatchInputQuickActionConfiguration(
            leadingActions: [.settings, .settings, .sessionHistory],
            trailingActions: [.settings, .toolCenter, .toolCenter]
        )

        #expect(configuration.leadingActions == [.settings, .sessionHistory])
        #expect(configuration.trailingActions == [.toolCenter])
    }

    @Test("损坏配置回退到默认布局")
    func invalidConfigurationFallsBackToDefault() {
        let configuration = WatchInputQuickActionConfiguration.decoded(from: "invalid")

        #expect(configuration == .defaultConfiguration)
    }
}

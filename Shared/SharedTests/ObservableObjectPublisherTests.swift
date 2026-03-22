// ============================================================================
// ObservableObjectPublisherTests.swift
// ============================================================================
// SharedTests
//
// 覆盖内容:
// - 启动阶段关键 ObservableObject 显式持有 objectWillChange
// - 避免 Release 包重新退回 Combine 的运行时反射路径
// ============================================================================

import Testing
import Foundation
import Combine
@testable import Shared

@Suite("ObservableObjectPublisher Tests")
struct ObservableObjectPublisherTests {
    @Test("启动阶段关键 ObservableObject 持有显式 publisher")
    @MainActor
    func startupObservableObjectsStoreExplicitPublisher() {
        let samples: [(String, Any)] = [
            ("AnnouncementManager", AnnouncementManager.shared),
            ("CloudSyncManager", CloudSyncManager.shared),
            ("FeedbackService", FeedbackService.shared),
            ("MCPManager", MCPManager.shared),
            ("ToolPermissionCenter", ToolPermissionCenter.shared),
            ("AppToolManager", AppToolManager.shared),
            ("AppLogCenter", AppLogCenter.shared),
            ("ShortcutToolManager", ShortcutToolManager.shared),
            ("LocalDebugServer", LocalDebugServer())
        ]

        for (name, object) in samples {
            let hasStoredPublisher = Mirror(reflecting: object).children.contains { child in
                child.label == "objectWillChange"
            }
            #expect(hasStoredPublisher, "\(name) 应显式存储 objectWillChange，避免运行时反射。")
        }
    }

    @Test("启动阶段关键 ObservableObject 可直接读取 publisher")
    @MainActor
    func startupObservableObjectsExposePublisherGetterSafely() {
        let publishers: [(String, () -> ObservableObjectPublisher)] = [
            ("AnnouncementManager", { AnnouncementManager.shared.objectWillChange }),
            ("CloudSyncManager", { CloudSyncManager.shared.objectWillChange }),
            ("FeedbackService", { FeedbackService.shared.objectWillChange }),
            ("MCPManager", { MCPManager.shared.objectWillChange }),
            ("ToolPermissionCenter", { ToolPermissionCenter.shared.objectWillChange }),
            ("AppToolManager", { AppToolManager.shared.objectWillChange }),
            ("AppLogCenter", { AppLogCenter.shared.objectWillChange }),
            ("ShortcutToolManager", { ShortcutToolManager.shared.objectWillChange }),
            ("LocalDebugServer", { LocalDebugServer().objectWillChange })
        ]

        for (name, makePublisher) in publishers {
            let publisher = makePublisher()
            #expect(type(of: publisher) == ObservableObjectPublisher.self, "\(name) 的 objectWillChange 类型应为 ObservableObjectPublisher。")
        }
    }

    @Test("MCPManager 切换聊天工具总开关会触发 objectWillChange")
    @MainActor
    func mcpManagerPublishesWhenTogglingChatToolsEnabled() {
        let manager = MCPManager.shared
        let original = manager.chatToolsEnabled

        var changeCount = 0
        let cancellable = manager.objectWillChange.sink { _ in
            changeCount += 1
        }

        manager.setChatToolsEnabled(!original)
        manager.setChatToolsEnabled(original)

        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test("AnnouncementManager 切换公告提示会触发 objectWillChange")
    @MainActor
    func announcementManagerPublishesWhenAlertStateChanges() {
        let manager = AnnouncementManager.shared
        let original = manager.shouldShowAlert

        var changeCount = 0
        let cancellable = manager.objectWillChange.sink { _ in
            changeCount += 1
        }

        manager.shouldShowAlert = !original
        manager.shouldShowAlert = original

        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test("CloudSyncManager 状态变化会触发 objectWillChange")
    @MainActor
    func cloudSyncManagerPublishesWhenStateChanges() async {
        let suiteName = "ObservableObjectPublisherTests.CloudSync.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        let manager = CloudSyncManager(userDefaults: userDefaults)

        var changeCount = 0
        let cancellable = manager.objectWillChange.sink { _ in
            changeCount += 1
        }

        await manager.performSync(options: [.providers], silent: false)

        let didEnterFailedState: Bool
        switch manager.state {
        case .failed:
            didEnterFailedState = true
        default:
            didEnterFailedState = false
        }
        #expect(didEnterFailedState, "CloudSyncManager 在关闭状态下执行同步应进入失败态。")
        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    #if canImport(WatchConnectivity)
    @Test("WatchSyncManager 状态变化会触发 objectWillChange")
    @MainActor
    func watchSyncManagerPublishesWhenStateChanges() {
        let manager = WatchSyncManager.shared

        var changeCount = 0
        let cancellable = manager.objectWillChange.sink { _ in
            changeCount += 1
        }

        manager.performSync(options: [.providers], silent: false)

        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }
    #endif

    @Test("ToolPermissionCenter 切换自动批准开关会触发 objectWillChange")
    @MainActor
    func toolPermissionCenterPublishesWhenTogglingAutoApprove() {
        let center = ToolPermissionCenter.shared
        let original = center.autoApproveEnabled

        var changeCount = 0
        let cancellable = center.objectWillChange.sink { _ in
            changeCount += 1
        }

        center.setAutoApproveEnabled(!original)
        center.setAutoApproveEnabled(original)

        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test("AppToolManager 切换聊天工具总开关会触发 objectWillChange")
    @MainActor
    func appToolManagerPublishesWhenTogglingChatToolsEnabled() {
        let manager = AppToolManager.shared
        let original = manager.chatToolsEnabled

        var changeCount = 0
        let cancellable = manager.objectWillChange.sink { _ in
            changeCount += 1
        }

        manager.setChatToolsEnabled(!original)
        manager.setChatToolsEnabled(original)

        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test("AppLogCenter 写入日志会触发 objectWillChange")
    @MainActor
    func appLogCenterPublishesWhenAppendingLogs() {
        let center = AppLogCenter.shared
        let marker = "observable-log-\(UUID().uuidString)"

        var changeCount = 0
        let cancellable = center.objectWillChange.sink { _ in
            changeCount += 1
        }

        center.logDeveloper(category: "Tests", action: "Append", message: marker)

        #expect(center.developerLogs.contains(where: { $0.message == marker }))
        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test("ShortcutToolManager 切换聊天工具总开关会触发 objectWillChange")
    @MainActor
    func shortcutToolManagerPublishesWhenTogglingChatToolsEnabled() {
        let manager = ShortcutToolManager.shared
        let original = manager.chatToolsEnabled

        var changeCount = 0
        let cancellable = manager.objectWillChange.sink { _ in
            changeCount += 1
        }

        manager.setChatToolsEnabled(!original)
        manager.setChatToolsEnabled(original)

        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test("FeedbackService 重载工单会触发 objectWillChange")
    @MainActor
    func feedbackServicePublishesWhenReloadingTickets() {
        let issueNumber = Int.random(in: 700_000...799_999)
        let ticket = FeedbackTicket(
            issueNumber: issueNumber,
            ticketToken: "token-\(issueNumber)",
            category: .bug,
            title: "测试工单 \(issueNumber)",
            createdAt: Date(),
            lastKnownStatus: .triage
        )
        let service = FeedbackService()

        FeedbackStore.deleteTicket(issueNumber: issueNumber)
        defer {
            FeedbackStore.deleteTicket(issueNumber: issueNumber)
        }

        var changeCount = 0
        let cancellable = service.objectWillChange.sink { _ in
            changeCount += 1
        }

        FeedbackStore.upsertTicket(ticket)
        service.reloadTickets()

        #expect(service.tickets.contains(where: { $0.issueNumber == issueNumber }))
        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test("LocalDebugServer 写入调试日志会触发 objectWillChange")
    @MainActor
    func localDebugServerPublishesWhenAppendingLogs() {
        let server = LocalDebugServer()
        let marker = "debug-log-\(UUID().uuidString)"

        var changeCount = 0
        let cancellable = server.objectWillChange.sink { _ in
            changeCount += 1
        }

        server.addLog(marker)

        #expect(server.debugLogs.contains(where: { $0.message == marker }))
        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }

    @Test("ChatMessageRenderState 更新会触发 objectWillChange")
    @MainActor
    func chatMessageRenderStatePublishesOnUpdate() {
        let messageID = UUID()
        let initial = ChatMessage(id: messageID, role: .assistant, content: "旧内容")
        let updated = ChatMessage(id: messageID, role: .assistant, content: "新内容")
        let state = ChatMessageRenderState(message: initial)

        var changeCount = 0
        let cancellable = state.objectWillChange.sink { _ in
            changeCount += 1
        }

        state.update(with: updated)

        #expect(state.message.content == "新内容")
        #expect(changeCount >= 1)
        withExtendedLifetime(cancellable) {}
    }
}

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
@testable import Shared

@Suite("ObservableObjectPublisher Tests")
struct ObservableObjectPublisherTests {
    @Test("启动阶段关键 ObservableObject 持有显式 publisher")
    @MainActor
    func startupObservableObjectsStoreExplicitPublisher() {
        let sampleMessage = ChatMessage(role: .assistant, content: "测试消息")
        let samples: [(String, Any)] = [
            ("AnnouncementManager", AnnouncementManager.shared),
            ("CloudSyncManager", CloudSyncManager.shared),
            ("FeedbackService", FeedbackService.shared),
            ("MCPManager", MCPManager.shared),
            ("ToolPermissionCenter", ToolPermissionCenter.shared),
            ("AppToolManager", AppToolManager.shared),
            ("AppLogCenter", AppLogCenter.shared),
            ("ShortcutToolManager", ShortcutToolManager.shared),
            ("LocalDebugServer", LocalDebugServer()),
            ("ChatMessageRenderState", ChatMessageRenderState(message: sampleMessage))
        ]

        for (name, object) in samples {
            let hasStoredPublisher = Mirror(reflecting: object).children.contains { child in
                child.label == "objectWillChange"
            }
            #expect(hasStoredPublisher, "\(name) 应显式存储 objectWillChange，避免运行时反射。")
        }
    }
}

// ============================================================================
// OnboardingSupportTests.swift
// ============================================================================
// 新手教程共享支持测试
// - 覆盖进度状态持久化
// - 覆盖快照条件推导
// ============================================================================

import Foundation
import Testing
@testable import Shared

@Suite("新手教程状态测试")
struct OnboardingSupportTests {

    @Test("默认进度为空")
    @MainActor
    func testProgressStoreStartsEmpty() {
        let suiteName = "OnboardingSupportTests.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = OnboardingProgressStore(userDefaults: defaults)

        #expect(store.seenGuideIDs.isEmpty)
        #expect(store.completedGuideIDs.isEmpty)
        #expect(store.dismissedHintIDs.isEmpty)
        #expect(store.visitedSurfaceIDs.isEmpty)
    }

    @Test("进度会写回到用户设置")
    @MainActor
    func testProgressStorePersistsChanges() {
        let suiteName = "OnboardingSupportTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let store = OnboardingProgressStore(userDefaults: defaults)
        store.markGuideSeen(.interactionPrimer)
        store.markGuideCompleted(.firstProvider)
        store.dismissHint(.chatMessages)
        store.markVisited(.toolCenter)

        let reloadedStore = OnboardingProgressStore(userDefaults: defaults)

        #expect(reloadedStore.hasSeenGuide(.interactionPrimer))
        #expect(reloadedStore.isGuideCompleted(.firstProvider))
        #expect(reloadedStore.isHintDismissed(.chatMessages))
        #expect(reloadedStore.hasVisitedSurface(.toolCenter))
    }

    @Test("提供商与工具页状态会自动满足对应教程")
    func testSnapshotSatisfiesProviderAndToolGuides() {
        let activeModel = Model(
            modelName: "gpt-test",
            displayName: "测试模型",
            isActivated: true
        )
        let provider = Provider(
            name: "测试提供商",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [activeModel]
        )
        let snapshot = OnboardingChecklistSnapshot.capture(
            providers: [provider],
            sessions: [],
            currentModel: RunnableModel(provider: provider, model: activeModel),
            visitedSurfaceIDs: [.providerManagement, .toolCenter],
            hasSentMessage: false
        )

        #expect(snapshot.isSatisfied(for: .firstProvider))
        #expect(snapshot.isSatisfied(for: .toolCenterBasics))
        #expect(!snapshot.isSatisfied(for: .firstChat))
        #expect(snapshot.currentModelDisplayName == "测试模型")
    }

    @Test("聊天教程需要进入聊天页并完成一次真实对话")
    func testSnapshotSatisfiesFirstChatGuide() {
        let activeModel = Model(
            modelName: "gpt-test",
            displayName: "测试模型",
            isActivated: true
        )
        let provider = Provider(
            name: "测试提供商",
            baseURL: "https://example.com/v1",
            apiKeys: ["key"],
            apiFormat: "openai-compatible",
            models: [activeModel]
        )
        let session = ChatSession(
            id: UUID(),
            name: "常驻会话",
            isTemporary: false
        )
        let snapshot = OnboardingChecklistSnapshot.capture(
            providers: [provider],
            sessions: [session],
            currentModel: RunnableModel(provider: provider, model: activeModel),
            visitedSurfaceIDs: [.chat],
            hasSentMessage: true
        )

        #expect(snapshot.isSatisfied(for: .firstChat))
        #expect(!snapshot.isSatisfied(for: .sessionManagement))
        #expect(!snapshot.isSatisfied(for: .interactionPrimer))
    }
}

import Combine
import Foundation
import Testing
@testable import ETOSCore

@MainActor
struct ChatComposerDraftStateTests {
    @Test("发送可用性跟随草稿变化，Unicode 空白和空行不能发送")
    func sendabilityFollowsDraftChanges() {
        let state = ChatComposerDraftState(text: " \t\n\u{3000}\u{00A0}")
        #expect(!state.hasSendableText)
        state.update(text: " \n内容\n ")
        #expect(state.hasSendableText)
        state.update(text: "")
        #expect(!state.hasSendableText)
    }
}

extension PersistenceTests {
    @Test("输入草稿仅通知输入组件，重复赋值不刷新，数据库恢复仍更新叶子状态")
    @MainActor
    func chatComposerDraftPublishesLocallyAndPersists() async {
        let config = AppConfigStore.shared
        await config.waitForPersistentStoreLoaded()
        let previousDraft = config.chatComposerDraft
        defer { config.chatComposerDraft = previousDraft }

        var configChanges = 0
        var receivedDrafts: [String] = []
        let configSubscription = config.objectWillChange.sink { configChanges += 1 }
        let draftSubscription = config.composerDraftState.$text.dropFirst().sink { receivedDrafts.append($0) }
        defer {
            configSubscription.cancel()
            draftSubscription.cancel()
        }

        let typedDraft = "输入中的草稿 \(UUID().uuidString)"
        config.chatComposerDraft = typedDraft
        config.chatComposerDraft = typedDraft
        #expect(configChanges == 0)
        #expect(receivedDrafts == [typedDraft])
        #expect(config.composerDraftState.text == typedDraft)
        #expect(config.value(for: .chatComposerDraft) == .text(typedDraft))
        #expect(config.snapshot(includeLocalOnly: true)[AppConfigKey.chatComposerDraft.rawValue] as? String == typedDraft)

        await config.flushPendingWrites()
        let restored = AppConfigStore()
        await restored.waitForPersistentStoreLoaded()
        #expect(restored.chatComposerDraft == typedDraft)
        #expect(restored.composerDraftState.text == typedDraft)

        // 持久化快照与外部填入都经过同一个赋值入口，不能只恢复业务值而遗漏输入组件。
        let replacement = "外部填入的草稿 \(UUID().uuidString)"
        config.setValue(replacement, for: .chatComposerDraft)
        #expect(config.composerDraftState.text == replacement)
        #expect(receivedDrafts == [typedDraft, replacement])
        #expect(configChanges == 0)
    }
}

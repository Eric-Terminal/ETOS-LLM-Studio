import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("用户消息预览设置", .serialized)
struct UserMessagePreviewSettingsTests {
    @Test("预览字符数使用平台默认值并通过数据库保存和同步")
    func persistsAndRestoresCharacterLimit() async {
        let key = AppConfigKey.userMessagePreviewCharacterLimit
        #expect(key.defaultValue == .integer(ChatUserMessagePreview.defaultCharacterLimit))
        #expect(key.participatesInSync)

        let appConfig = AppConfigStore.shared
        await appConfig.waitForPersistentStoreLoaded()
        let previousLimit = appConfig.userMessagePreviewCharacterLimit
        defer { appConfig.userMessagePreviewCharacterLimit = previousLimit }
        appConfig.userMessagePreviewCharacterLimit = 237
        await appConfig.flushPendingWrites()
        let stored = await Task.detached {
            Persistence.readAppConfigInteger(key: key.rawValue)
        }.value
        #expect(stored == 237)
        #expect(appConfig.snapshot()[key.rawValue] as? Int == 237)

        let restored = AppConfigStore()
        await restored.waitForPersistentStoreLoaded()
        #expect(restored.userMessagePreviewCharacterLimit == 237)
        appConfig.apply(snapshot: [key.rawValue: 850])
        #expect(appConfig.value(for: key) == .integer(850))

        appConfig.userMessagePreviewCharacterLimit = 0
        #expect(appConfig.userMessagePreviewCharacterLimit == 1)
        appConfig.apply(snapshot: [key.rawValue: Int.max])
        #expect(appConfig.userMessagePreviewCharacterLimit == ChatUserMessagePreview.characterLimitRange.upperBound)
    }

    @Test("向导只生成预览设置提案，确认后保存且换页后拒绝旧提案")
    func guideRequiresProposalExecutionOnCurrentPage() throws {
        let appConfig = AppConfigStore.shared
        let previousLimit = appConfig.userMessagePreviewCharacterLimit
        defer { appConfig.userMessagePreviewCharacterLimit = previousLimit }
        appConfig.userMessagePreviewCharacterLimit = 600
        let settings = [GuideDisplaySettingsSupport.userMessagePreviewCharacterLimit(appConfig: appConfig)]
        let snapshot = GuideDeclarativeSettingsSupport.snapshot(settings: settings)
        #expect(snapshot.fields["user_message_preview_character_limit"]?.value == .int(600))
        #expect(snapshot.fields["user_message_preview_character_limit"]?.access == .readWrite)
        let proposal = try GuideDeclarativeSettingsSupport.buildProposal(
            call: InternalToolCall(
                id: "preview-limit",
                toolName: GuideDeclarativeSettingsSupport.toolName,
                arguments: #"{"user_message_preview_character_limit":420}"#
            ),
            pageID: "settings-display-1",
            pageTitle: "显示设置",
            settings: settings,
            snapshot: snapshot
        )
        #expect(appConfig.userMessagePreviewCharacterLimit == 600)
        #expect(throws: GuideError.self) {
            _ = try GuideDeclarativeSettingsSupport.execute(
                proposal: proposal, pageID: "settings-display-0", pageTitle: "显示设置", settings: settings
            )
        }
        #expect(appConfig.userMessagePreviewCharacterLimit == 600)
        _ = try GuideDeclarativeSettingsSupport.execute(
            proposal: proposal, pageID: "settings-display-1", pageTitle: "显示设置", settings: settings
        )
        #expect(appConfig.userMessagePreviewCharacterLimit == 420)

        #expect(throws: GuideError.self) {
            _ = try GuideDeclarativeSettingsSupport.buildProposal(
                call: InternalToolCall(
                    id: "invalid-preview-limit",
                    toolName: GuideDeclarativeSettingsSupport.toolName,
                    arguments: #"{"user_message_preview_character_limit":0}"#
                ),
                pageID: "settings-display-1", pageTitle: "显示设置", settings: settings,
                snapshot: GuideDeclarativeSettingsSupport.snapshot(settings: settings)
            )
        }
    }
}

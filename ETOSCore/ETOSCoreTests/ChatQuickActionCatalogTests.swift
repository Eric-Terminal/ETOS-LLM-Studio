import Foundation
import Testing
@testable import ETOSCore

struct ChatQuickActionCatalogTests {
    @Test("共享目录保持已发布的十五个数据库标识及顺序")
    func preservesStoredIdentifiers() {
        #expect(ChatQuickAction.allCases.map(\.rawValue) == [
            "temporaryChat", "contextCompression", "settings", "toolCenter", "dailyPulse", "usageAnalytics", "memory", "mcp",
            "agentSkills", "shortcuts", "roleplay", "worldbook", "extendedFeatures", "browser", "localTerminal"
        ])
        guard case .text(let raw) = AppConfigKey.chatQuickActionIDs.defaultValue else {
            Issue.record("默认快捷功能配置应为文本"); return
        }
        #expect(ChatQuickActionSelection.decode(raw) == ChatQuickAction.allCases)
        #expect(ChatQuickActionSelection.encode([]) == ChatQuickActionSelection.encode(ChatQuickAction.allCases))
    }

    @Test("混合未知标识时保留有效选择并规范顺序，不扩展成全部")
    func mixedUnknownValuesKeepValidSubset() {
        #expect(ChatQuickActionSelection.decode("browser,unknown,mcp,browser") == [.mcp, .browser])
        #expect(ChatQuickActionSelection.encode([.browser, .mcp, .browser]) == "mcp,browser")
        #expect(ChatQuickActionSelection.decode("unknown,,") == ChatQuickAction.allCases)
    }

    @Test("临时对话在存储列表末尾时仍保留工具栏直接入口所需顺序")
    func temporaryChatIsNormalizedBeforeOverflowActions() {
        #expect(ChatQuickActionSelection.decode("settings,browser,temporaryChat") == [.temporaryChat, .settings, .browser])
    }

    @Test("临时聊天三种状态共享隐私图标，其他功能不受状态影响")
    func temporaryModeSymbolsRemainCompatible() {
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: false) == "eye")
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: true) == "eye.slash")
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: true, memoryMode: .isolated) == "eye.slash.fill")
        #expect(ChatQuickAction.browser.systemImage(isTemporaryChatEnabled: true, memoryMode: .isolated) == "safari")
    }
}

import Foundation
import Testing
@testable import ETOSCore

struct ChatQuickActionCatalogTests {
    @Test("共享目录保留已发布标识并将模型选择纳入默认配置")
    func preservesStoredIdentifiers() {
        #expect(ChatQuickAction.allCases.map(\.rawValue) == [
            "temporaryChat", "modelPicker", "contextCompression", "settings", "toolCenter", "dailyPulse", "usageAnalytics", "memory", "mcp",
            "agentSkills", "shortcuts", "roleplay", "worldbook", "extendedFeatures", "browser", "localTerminal"
        ])
        guard case .text(let raw) = AppConfigKey.chatQuickActionIDs.defaultValue else {
            Issue.record("默认快捷功能配置应为文本"); return
        }
        #expect(ChatQuickActionSelection.decode(raw) == ChatQuickAction.allCases)
        #expect(ChatQuickActionSelection.encode([]) == ChatQuickActionSelection.encode(ChatQuickAction.allCases))
    }

    @Test("混合未知标识时保留有效选择与首次出现顺序，不扩展成全部")
    func mixedUnknownValuesKeepValidSubset() {
        #expect(ChatQuickActionSelection.decode("browser,unknown,mcp,browser") == [.browser, .mcp])
        #expect(ChatQuickActionSelection.encode([.browser, .mcp, .browser]) == "browser,mcp")
        #expect(ChatQuickActionSelection.decode("unknown,,") == ChatQuickAction.allCases)
    }

    @Test("模型与临时对话服从用户顺序，不强制移到最前")
    func nativeEntriesRetainUserOrder() {
        #expect(ChatQuickActionSelection.decode("settings,modelPicker,browser,temporaryChat") == [.settings, .modelPicker, .browser, .temporaryChat])
        #expect(ChatQuickAction.modelPicker.systemImage == "cpu")
    }

    @Test("工具栏空集合表示全部放入更多，不回退为默认入口")
    func toolbarPreferencesAllowEmpty() {
        #expect(ChatQuickActionSelection.decodeToolbarActions("").isEmpty)
        #expect(ChatQuickActionSelection.encodeToolbarActions([]).isEmpty)
        #expect(ChatQuickActionSelection.decodeToolbarActions("browser,unknown,browser,modelPicker") == [.browser, .modelPicker])
        guard case .text(let raw) = AppConfigKey.chatToolbarActionIDs.defaultValue else {
            Issue.record("工具栏默认配置应为文本"); return
        }
        #expect(ChatQuickActionSelection.decodeToolbarActions(raw) == [.temporaryChat, .modelPicker])
    }

    @Test("向导保留排序，允许清空工具栏但拒绝清空全部功能及无效标识")
    func guideValidatesOrderedSelections() throws {
        let input: JSONValue = .array([.string("browser"), .string("modelPicker"), .string("temporaryChat")])
        #expect(try GuideChatQuickActionSettingsSupport.actions(from: input) == [.browser, .modelPicker, .temporaryChat])
        #expect(try GuideChatQuickActionSettingsSupport.actions(from: .array([]), allowsEmpty: true) == [])
        #expect(throws: GuideError.self) { try GuideChatQuickActionSettingsSupport.actions(from: .array([])) }
        let invalidValues: [JSONValue] = [.string("browser"), .array([.int(1)]), .array([.string("unknown")]), .array([.string("modelPicker"), .string("modelPicker")])]
        for invalid in invalidValues {
            #expect(throws: GuideError.self) { try GuideChatQuickActionSettingsSupport.actions(from: invalid, allowsEmpty: true) }
        }
    }

    @Test("临时聊天三种状态共享隐私图标，其他功能不受状态影响")
    func temporaryModeSymbolsRemainCompatible() {
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: false) == "eye")
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: true) == "eye.slash")
        #expect(ChatQuickAction.temporaryChat.systemImage(isTemporaryChatEnabled: true, memoryMode: .isolated) == "eye.slash.fill")
        #expect(ChatQuickAction.browser.systemImage(isTemporaryChatEnabled: true, memoryMode: .isolated) == "safari")
    }
}

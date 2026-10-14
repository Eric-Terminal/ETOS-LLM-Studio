import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacChatQuickActionsTests {
    @Test("已保存的选择按共同目录顺序展示，未知值不产生空白入口")
    func preparedSelectionUsesKnownOrderedEntries() {
        let state = MacChatQuickActionPresentation(rawValue: "browser,unknown,usageAnalytics,browser")
        #expect(state.selectedRows.map(\.action) == [.usageAnalytics, .browser])
        #expect(state.rows.map(\.action) == ChatQuickAction.allCases)
        #expect(state.selected == Set([.browser, .usageAnalytics]))
        #expect(state.guideValue == .array([.string("usageAnalytics"), .string("browser")]))
    }

    @Test("空配置回退到全部，单项配置保留直接入口")
    func fallbackAndSingleEntryRemainUsable() {
        #expect(MacChatQuickActionPresentation(rawValue: "").selectedRows.count == 15)
        let state = MacChatQuickActionPresentation(rawValue: "contextCompression")
        #expect(state.selectedRows.map(\.action) == [.contextCompression])
        #expect(state.selectedRows.first?.systemImage == "rectangle.compress.vertical")
    }

    @Test("向导拒绝空列表、未知项、重复项和错误类型")
    func guideRejectsInvalidSelection() {
        let invalid: [JSONValue] = [
            .array([]), .array([.string("unknown")]), .array([.string("browser"), .string("browser")]),
            .array([.int(1)]), .string("browser")
        ]
        for value in invalid {
            #expect(throws: GuideError.self) { try MacChatQuickActionPresentation.guideActions(value) }
        }
    }

    @Test("向导确认的选择采用数据库规范顺序")
    func guideSelectionNormalizesBeforeSaving() throws {
        let actions = try MacChatQuickActionPresentation.guideActions(.array([.string("worldbook"), .string("settings")]))
        #expect(actions == [.settings, .worldbook])
        #expect(ChatQuickActionSelection.encode(actions) == "settings,worldbook")
    }

    @Test("目录中每项都有独立页面或明确的原生入口")
    func allActionsHaveDestinations() {
        let native: Set<ChatQuickAction> = [.temporaryChat, .settings, .dailyPulse, .contextCompression]
        for action in ChatQuickAction.allCases {
            let page = MacChatQuickActionPage(rawValue: action.rawValue)
            #expect((page != nil) != native.contains(action))
            if let page { #expect(page.action == action) }
        }
        #expect(MacChatQuickActionPage.allCases.count + native.count == ChatQuickAction.allCases.count)
    }

    @Test("只有浏览器入口固定来源会话，管理页面和用户终端保留各自范围")
    func sessionScopedBrowserIsExplicit() {
        #expect(MacChatQuickActionPage.allCases.filter(\.requiresSession) == [.browser])
        let target = MacChatQuickActionDestination(page: .browser, sessionID: UUID(), isTemporary: true)
        #expect(target.sessionID != nil && target.isTemporary)
    }

    @Test("双语向导说明立即保存与禁止触发操作，明确尚未对齐的高级功能")
    func guideExplainsScopeAndRemainingWork() {
        let chinese = GuideChatQuickActionsKnowledge.document(locale: Locale(identifier: "zh_CN")).content
        let english = GuideChatQuickActionsKnowledge.document(locale: Locale(identifier: "en_US")).content
        #expect(chinese.contains("修改立即保存") && chinese.contains("不能通过向导触发快捷功能"))
        #expect(english.contains("cannot launch an action") && english.contains("still require Mac source work"))
        #expect(GuideDocumentCatalog.documents.contains { $0.id == "chat-quick-actions" })
    }
}

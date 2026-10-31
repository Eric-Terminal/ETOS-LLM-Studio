import ETOSCore
import Foundation
import Testing
@testable import ETOS_LLM_Studio_macOS_App

struct MacChatQuickActionsTests {
    @Test("已保存的选择按用户顺序展示，未知值不产生空白入口")
    func preparedSelectionUsesKnownOrderedEntries() {
        let state = MacChatQuickActionPresentation(rawValue: "browser,unknown,usageAnalytics,browser")
        #expect(state.selectedRows.map(\.action) == [.browser, .usageAnalytics])
        #expect(state.rows.map(\.action) == [.browser, .usageAnalytics] + ChatQuickAction.allCases.filter { !state.selected.contains($0) })
        #expect(state.selected == Set([.browser, .usageAnalytics]))
        #expect(state.guideValue == .array([.string("browser"), .string("usageAnalytics")]))
    }

    @Test("空配置回退到全部，单项配置保留选择")
    func fallbackAndSingleEntryRemainUsable() {
        #expect(MacChatQuickActionPresentation(rawValue: "").selectedRows.count == 16)
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

    @Test("向导确认的选择保留用户顺序")
    func guideSelectionRetainsOrderBeforeSaving() throws {
        let actions = try MacChatQuickActionPresentation.guideActions(.array([.string("worldbook"), .string("settings")]))
        #expect(actions == [.worldbook, .settings])
        #expect(ChatQuickActionSelection.encode(actions) == "worldbook,settings")
    }

    @Test("目录中每项都有独立页面或明确的原生入口")
    func allActionsHaveDestinations() {
        let native: Set<ChatQuickAction> = [.temporaryChat, .modelPicker, .settings, .dailyPulse, .contextCompression]
        for action in ChatQuickAction.allCases {
            let page = MacChatQuickActionPage(rawValue: action.rawValue)
            #expect((page != nil) != native.contains(action))
            if let page { #expect(page.action == action) }
        }
        #expect(MacChatQuickActionPage.allCases.count + native.count == ChatQuickAction.allCases.count)
    }

    @Test("工具栏和更多分别保持用户顺序，隐藏项即使有工具栏偏好也不显示")
    func preferredAndOverflowActionsRetainOrder() {
        let state = MacChatQuickActionPresentation(rawValue: "browser,modelPicker,settings,temporaryChat",
            toolbarRawValue: "temporaryChat,usageAnalytics,browser,modelPicker")
        #expect(state.toolbarRows.map(\.action) == [.browser, .modelPicker, .temporaryChat])
        #expect(state.menuRows.map(\.action) == [.settings])
        #expect(!state.toolbarRows.contains { $0.action == .usageAnalytics })
        let allInMenu = MacChatQuickActionPresentation(rawValue: "modelPicker,browser", toolbarRawValue: "")
        #expect(allInMenu.toolbarRows.isEmpty)
        #expect(allInMenu.menuRows.map(\.action) == [.modelPicker, .browser])
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

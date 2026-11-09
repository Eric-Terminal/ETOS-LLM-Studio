import Foundation
import Testing
@testable import ETOSCore

struct GuideAdaptiveLayoutKnowledgeTests {
    @Test("布局文档可检索且不会赋予向导设备或聊天操作权限")
    func documentsLayoutWithoutExecutionAuthority() throws {
        let catalogEntry = try #require(GuideDocumentCatalog.documents.first { $0.id == "adaptive-layout" })
        #expect(catalogEntry.keywords.contains("iPhone Duo"))
        let chinese = GuideAdaptiveLayoutKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("不新增设置开关"))
        #expect(chinese.content.contains("不能替用户折叠设备、改变窗口、发送消息或点击快捷功能"))
        let fallback = GuideAdaptiveLayoutKnowledge.document(locale: Locale(identifier: "fr"))
        #expect(fallback.content.contains("no new preference or database setting"))
        #expect(fallback.content.contains("not guide-configurable pages"))
    }

    @Test("布局与快捷功能文档说明普通 iPhone 不随系统升级切换导航")
    func documentsDeviceSpecificToolbarBehavior() {
        let chinese = Locale(identifier: "zh-Hans")
        let english = Locale(identifier: "en")
        let chineseDocuments = [
            GuideAdaptiveLayoutKnowledge.document(locale: chinese),
            GuideChatQuickActionsKnowledge.document(locale: chinese)
        ]
        let englishDocuments = [
            GuideAdaptiveLayoutKnowledge.document(locale: english),
            GuideChatQuickActionsKnowledge.document(locale: english)
        ]
        for document in chineseDocuments {
            #expect(document.content.contains("普通 iPhone 无论系统版本都保留原来的顶部导航和快捷菜单"))
            #expect(document.content.contains("iPhone Duo"))
            #expect(document.content.contains("内外屏"))
        }
        for document in englishDocuments {
            #expect(document.content.contains("Other iPhones keep the original top navigation and shortcut menu regardless of iOS version"))
            #expect(document.content.contains("both displays"))
        }
    }
}

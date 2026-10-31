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
}

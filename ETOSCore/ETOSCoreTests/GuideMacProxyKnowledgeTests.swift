import Foundation
import Testing
@testable import ETOSCore

struct GuideMacProxyKnowledgeTests {
    @Test("代理指引明确继承、系统代理、草稿保存与凭据隐私边界")
    func proxyGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans")).content
        #expect(chinese.contains("用户名与密码只写不可读"))
        #expect(chinese.contains("仍可能受系统代理影响"))
        #expect(chinese.contains("密码变化也会拒绝旧草稿覆盖"))
        #expect(chinese.contains("独立代理返回提供商编辑器统一保存"))
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en")).content
        #expect(english.contains("subsequent calls through the shared ChatService request path"))
        #expect(english.contains("resuming never saves automatically"))
        #expect(english.contains("The guide cannot save, reload or test connections"))
    }
}

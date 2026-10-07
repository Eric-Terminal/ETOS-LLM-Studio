import Foundation
import Testing
@testable import ETOSCore

struct GuideMacLinuxKnowledgeTests {
    @Test("Mac Linux 指引区分宿主 MCP、手动执行及向导隐私边界")
    func executionAndPrivacyBoundaries() {
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en"))
        #expect(english.content.contains("native Process separately from the Linux terminal"))
        #expect(english.content.contains("no input, environment values or output"))
        #expect(english.content.contains("Stop failure prevents database replacement"))
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("解锁或恢复不重放命令"))
        #expect(chinese.content.contains("打开空页面不会自动创建进程"))
    }

    @Test("任务与诊断指引说明停止范围、分页和手动复制边界")
    func historyAndDiagnosticGuidance() {
        let document = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(document.content.contains("停止此 Agent"))
        #expect(document.content.contains("64 KB"))
        #expect(document.content.contains("不会自动上报"))
        #expect(document.content.contains("诊断正文"))
    }
}

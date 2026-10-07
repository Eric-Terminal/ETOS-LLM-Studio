import Foundation
import Testing
@testable import ETOSCore

struct GuideMacLinuxKnowledgeTests {
    @Test("配置指引明确值的只写权限、规则优先顺序和快捷栏草稿边界")
    func configurationGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("值只写不可读"))
        #expect(chinese.content.contains("拒绝优先于确认，确认优先于警告"))
        #expect(chinese.content.contains("列表顺序只决定同类命中的先后"))
        #expect(chinese.content.contains("配置不会向终端发送按键"))
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en"))
        #expect(english.content.contains("complete original encoding"))
        #expect(english.content.contains("Modifier-only combinations cannot be saved"))
    }

    @Test("工作区与挂载指引区分草稿、目录授权和删除范围")
    func workspaceAndMountGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("数据库删除失败时恢复原目录"))
        #expect(chinese.content.contains("应用目录权限必须重新选择目录"))
        #expect(chinese.content.contains("目录名、宿主路径和书签"))
        #expect(chinese.content.contains("不是一致性快照"))
    }

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

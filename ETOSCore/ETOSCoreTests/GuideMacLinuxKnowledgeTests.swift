import Foundation
import Testing
@testable import ETOSCore

struct GuideMacLinuxKnowledgeTests {
    @Test("常用环境与合规指引区分一次发送、guest 作用域及随包声明")
    func recipesAndComplianceGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("终端页只附着"))
        #expect(chinese.content.contains("不修改 /etc/apk/repositories"))
        #expect(chinese.content.contains("不会回滚已经安装的包"))
        #expect(chinese.content.contains("不表示页面已重新计算压缩包哈希"))
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en"))
        #expect(english.content.contains("reopening never resends"))
        #expect(english.content.contains("without rolling back installed packages"))
    }

    @Test("文件指引说明预览预算、原件比较、递归删除和向导隐私")
    func fileBrowserGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("文件预览最多 256 KiB"))
        #expect(chinese.content.contains("inode 元数据与原始字节"))
        #expect(chinese.content.contains("递归删除失败也可能已删除部分内容"))
        #expect(chinese.content.contains("不提供路径、文件名或正文"))
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en"))
        #expect(english.content.contains("not a guest file lock"))
        #expect(english.content.contains("Restore never replays saves or deletions"))
    }

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

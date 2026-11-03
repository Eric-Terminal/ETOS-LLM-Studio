import Foundation
import Testing
@testable import ETOSCore

struct GuideMacLinuxKnowledgeTests {
    @Test("Mac 环境指引使用本机进程，不提供移动端 Linux 安装流程")
    func recipesAndComplianceGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("系统 UNIX/POSIX 进程"))
        #expect(chinese.content.contains("不安装 iSH、Linux 或 RootFS"))
        #expect(chinese.content.contains("没有 Linux 安装、重置、挂载或环境准备页面"))
        #expect(chinese.content.contains("依赖程序由用户在 Mac 上安装"))
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en"))
        #expect(english.content.contains("native UNIX/POSIX processes"))
        #expect(english.content.contains("not filesystem isolation"))
    }

    @Test("Mac 文件指引区分 Documents 工具地址与宿主 Shell 路径")
    func fileBrowserGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("相对路径和 app:// 指向 App Documents"))
        #expect(chinese.content.contains("访问其他 Mac 路径使用本机 Shell 命令"))
        #expect(chinese.content.contains("linux:// 和 mount:// 不适用于 Mac"))
        #expect(chinese.content.contains("不能读取正文、运行查询或清理"))
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en"))
        #expect(english.content.contains("Structured file tools accept relative paths and app:// within App Documents"))
        #expect(english.content.contains("linux:// and mount:// are unavailable on Mac"))
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

    @Test("Mac 工作区指引保留任务停止、导出一致性与删除范围边界")
    func workspaceAndMountGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans"))
        #expect(chinese.content.contains("取消并等待相关任务及输出落盘后删除目录和记录"))
        #expect(chinese.content.contains("不删除其他会话和外部文件"))
        #expect(chinese.content.contains("页面及详情向导只读，不能导出或删除"))
        #expect(chinese.content.contains("不保证运行中写入文件的一致性快照"))
    }

    @Test("Mac 本机 Shell 指引区分 MCP、手动执行及向导隐私边界")
    func executionAndPrivacyBoundaries() {
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en"))
        #expect(english.content.contains("stdio uses a native Process with stdin/stdout"))
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

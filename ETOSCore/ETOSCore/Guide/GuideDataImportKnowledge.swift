import Foundation

public enum GuideDataImportKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "data-import",
            title: chinese ? "数据导入" : "Data Import",
            keywords: ["导入", "备份", "ETOS", "Cherry Studio", "RikkaHub", "Kelivo", "ChatGPT", "ChatBox", "OpenMinis", "import", "Mac"],
            content: chinese ? """
            想把以前的备份或其他 AI 客户端里的聊天记录、模型配置搬过来，可以打开“设置 → 数据管理 → 导入数据”（Mac 也可从“拓展功能 → 导入数据”进入）。iOS、watchOS 与 Mac 采用统一的数据结构，支持 7 类数据来源：
            ETOS、Cherry Studio、RikkaHub、Kelivo、ChatGPT、ChatBox、OpenMinis。按界面上的来源提示选择对应的导出文件或解压文件夹即可（其中只有 OpenMinis 支持一次多选多个文件）。

            第一步：选择文件并查看导入预览
            • 选好文件后，App 只会在后台解析内容并预估与本机数据的重复情况，预览阶段绝对不会改动或删除你现有的任何数据。
            • 导入第三方客户端数据时，你可以自由勾选实际识别出来的类别：提供商配置、聊天会话、MCP 服务、Skills 技能（会话关联的标签、语音和图片附件会随对话一起保留；如果取消勾选聊天会话，这些附件和标签也会一并跳过）。OpenMinis 还会额外展示解析出的消息数、附件占位符、兼容降级项与识别到的 Skill 名称。
            • 导入 ETOS 自有文件的区别：旧版 ETOS JSON 导出包会保留导出时的全部同步范围，不支持在本页单独删减；而 `.elsbackup` 快照备份文件则会转入专门的“快照恢复”确认窗口（加密备份需输入密码，恢复后会整体替换当前应用数据，而不是做局部合并）。

            第二步：核对凭据并手动确认导入
            • 来源选择和范围勾选在点击导入前都只是当前页面的草稿，离开页面不会自动导入；如果中途切换了 App 界面语言，需重新选择一次文件以刷新预览。
            • 点击“确认导入”会打开最终范围确认页。如果待导入内容包含服务商 API Key、自定义认证请求头、MCP 服务或应用设置，界面会要求你额外手动勾选敏感凭据确认，防止误导入未知配置。
            • 请只导入你信任的配置来源：合并完成后，已勾选导入的 MCP 服务会自动恢复连接（本地命令型 MCP 服务可能会在 Mac 上启动对应程序），而导入的 Skills 只会保存文件，不会自动运行里面的脚本或安装依赖。完成后页面会展示每个类别实际新增与跳过条数的详细报告。

            页面向导说明与隐私边界：
            • 在数据导入主页，向导经你原生确认后只能帮你切换“数据来源”或勾选当前可选的“导入范围”；介绍页、文件选择器与最终确认页均不支持向导代操作。
            • 向导只能读取各类别的条数统计、是否为固定范围、是否需要凭据确认以及最终的数量汇总报告；绝对看不到文件路径、聊天正文、警告详情、Skill 内容、API Key 或 MCP 参数。向导不能选文件、不能勾选敏感凭据确认、不能点击确认导入或执行快照恢复。
            """ : """
            To bring over backups or migrate your chats and model setups from another AI client, open Settings → Data Management → Import Data (or Extended Features → Import Data on Mac). iOS, watchOS and Mac share the same data format and support seven import sources:
            ETOS, Cherry Studio, RikkaHub, Kelivo, ChatGPT, ChatBox and OpenMinis. Follow the on-screen hint for each source to pick the exported file or extracted folder (only OpenMinis supports selecting multiple files at once).

            Step 1: Preview and choose what to import
            • Picking a file only parses the package and estimates duplicates—previewing never overwrites or deletes your existing local data.
            • For third-party imports, you can check whichever recognized categories you want to bring in: Providers, Sessions, MCP Servers and Skills. Session tags, voice clips and images travel together with Sessions (unchecking Sessions excludes its media and tags too). OpenMinis previews also list message counts, attachment placeholders, degraded items and recognized Skill names.
            • ETOS files work two ways: legacy ETOS JSON packages keep their full exported scope as a unit, while `.elsbackup` files hand off to the dedicated snapshot restore confirmation—which may ask for your backup password and replaces your current database as a whole rather than merging partial categories.

            Step 2: Review credentials and confirm the merge
            • Your chosen source and category checkboxes stay as a local page draft until you confirm; leaving the page imports nothing, and changing the app display language clears the preview so you can reselect the file cleanly.
            • Clicking Confirm Import opens a final review sheet. Whenever the selected scope carries API keys, custom headers, MCP servers or ETOS settings, you must also check a native credential acknowledgement box yourself.
            • Import only configurations you trust: once merged, selected MCP connections reconnect automatically, so local stdio MCP servers may start processes on your Mac. Imported Skills save their files only and never run scripts or install dependencies on their own. When finished, a summary report shows how many items were added or skipped in each category.

            Guide support and privacy boundaries:
            • On the main Import Data page, the guide can propose switching the import source or toggling available category checkboxes after native confirmation. File panels, introductions and the final confirmation sheet are not operable by the guide.
            • The guide sees item counts, fixed-scope flags, whether credential acknowledgement is required and the final count report—never file paths, message text, raw warnings, Skill contents, API keys or MCP arguments. It cannot choose files, acknowledge credentials, confirm an import or restore a snapshot.
            """
        )
    }
}

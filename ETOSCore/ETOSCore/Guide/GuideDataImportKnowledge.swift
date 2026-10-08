import Foundation

public enum GuideDataImportKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "data-import", title: chinese ? "数据导入" : "Data Import",
            keywords: ["导入", "备份", "ETOS", "Cherry Studio", "RikkaHub", "Kelivo", "ChatGPT", "ChatBox", "OpenMinis", "import", "Mac"],
            content: chinese ? """
            Mac 从设置→数据管理→导入数据，或拓展功能→导入数据进入。与 iOS/watchOS 共用 ThirdPartyImportService 和 SyncEngine，不创建另一套数据库格式。支持 ETOS、Cherry Studio、RikkaHub、Kelivo、ChatGPT、ChatBox、OpenMinis 七类来源；按页面来源提示选择文件或解压目录，只有 OpenMinis 支持一次多选。目录选择器属于系统页面，没有自定义向导执行器。

            选择文件只在后台解析和预估冲突。OpenMinis 另外展示消息数、附件占位、降级项、MCP 与 Skill 数及识别的 Skill 名称。第三方数据可勾选实际识别到的提供商、会话、MCP、Skills；会话关联标签和媒体随正文保留。冲突按本地提供商内容签名、会话 ID 或名称/消息数估算，预览不预先删除或覆盖数据，最终以 Core 合并结果为准。旧 ETOS JSON 按导出的完整同步范围合并，不能在本页删减范围；.elsbackup 则转入独立快照恢复确认，可能要求密码并替换数据库，不能当作部分同步包合并。

            来源和范围只是当前页草稿，离开不会自动导入。向导经原生提案确认可修改来源及当前可选范围；只能读取计数、固定范围、是否需要凭据确认和合并报告。不提供文件路径、正文、警告原文、Skill 内容、密钥或 MCP 参数；凭据只写不可读，本页不提供修改已有凭据的接口。向导不能选文件、批准凭据、确认导入、恢复数据库或执行 MCP/快捷指令。介绍页和最终确认页独立只读；切换来源、范围、语言、标签、页面或锁定会使旧提案失效。语言切换清除已本地化的预览，需要重新选择文件。

            点击“确认导入”先打开最终范围确认页。导入提供商密钥、MCP 或包含设置的 ETOS 包时，原生页面还可能要求勾选敏感凭据确认。确认后暂停聊天与其他写入来源，排空已接受写入及仍在读取本地库的冲突预览，取得云同步屏障后合并，刷新会话和配置。已选 MCP 连接会恢复，因此本地 stdin/stdout 服务器可能启动进程；导入不会主动执行 Skill 脚本或安装依赖。已确认的合并由工作区持有，关页不截断，退出应用会等待完成。最终报告展示实际新增/跳过各同步类别；会话项遵循 Core 包含标签的计数口径，字体项包含路由规则，脉冲和用量项目也沿用 Core 汇总单位。当前仅完成源码与静态检查，Mac target、真实文件、恢复、连接与退出行为仍需完整工具链验证。
            """ : """
            On Mac, open Settings → Data Management → Import Data or Extended Features → Import Data. The page shares ThirdPartyImportService, SyncEngine and the database format with iOS/watchOS. Sources are ETOS, Cherry Studio, RikkaHub, Kelivo, ChatGPT, ChatBox and OpenMinis. Follow the source-specific file or extracted-folder instructions. Only OpenMinis permits multiple selections. The native file panel has no custom guide executor.

            Selecting files only parses and estimates conflicts in the background. OpenMinis also shows message, attachment-placeholder, degraded-item, MCP and Skill counts and recognized Skill names. Third-party imports allow the recognized providers, sessions, MCP servers and Skills to be selected. Session tags and media remain with their messages. Conflict estimates use local provider content signatures and session IDs or names/message counts. Preview does not delete or overwrite data; the Core merge result is authoritative. Legacy ETOS JSON retains its entire exported scope. An .elsbackup opens the separate snapshot confirmation, may need a password and replaces the database; it is not a partial merge package.

            Source and scope are page drafts, with no import on departure. After native proposal confirmation, the guide can change source and available scope only. It can read counts, fixed scope, whether credential acknowledgement is required and the merge report. It cannot read paths, bodies, raw warnings, Skill contents, keys or MCP arguments. Credentials are write-only and this page offers no existing-credential editing interface. The guide cannot choose files, acknowledge credentials, confirm an import, restore a database or execute MCP/Shortcuts. Introduction and final confirmation pages are independently read-only. Source, scope, language, tab, page and lock changes invalidate old proposals. Language changes clear localized previews and require file selection again.

            Confirm Import first opens a final scope sheet. Provider keys, MCP configurations or ETOS settings may require a separate native credential acknowledgement. Confirmation pauses chat and other write sources, drains accepted writes and database-reading previews, obtains the cloud-sync barrier, merges data and refreshes sessions and configuration. Selected MCP connections resume, so local stdin/stdout servers may start processes. Import does not proactively execute Skill scripts or install dependencies. The workspace retains an accepted merge across page closure and waits for completion before termination. Reports use actual Core added/skipped counts; session totals include tags, font totals include routing rules, and Daily Pulse and usage retain Core aggregation units. This is source work with static checks only; target integration and real file, restore, connection and termination behavior still need a complete toolchain.
            """)
    }
}

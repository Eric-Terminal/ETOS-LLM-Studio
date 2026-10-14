import Foundation

public enum GuideSlashCommandsKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "slash-commands", title: chinese ? "快速指令与页面跳转" : "Quick Commands and Navigation",
            keywords: ["快速指令", "斜杠", "别名", "提示词", "slash commands", "custom prompt", "Mac"],
            content: chinese ? """
            快速指令默认关闭，开关沿用 chat.slashCommands.enabled，自定义列表沿用 chat.slashCommands.custom 的 JSON；Mac 与 iOS/watchOS 共用数据库格式和 Core 解析器。内建顺序固定为 /new、/model、/sessions、/settings、/tools、/daily、/usage、/memory、/mcp、/skills、/shortcuts、/roleplay、/worldbook、/features、/temporary、/compact、/retry、/stop、/clear，共 19 项。别名包括 history、tool、pulse、stats、skill、extensions、temp、compress，只参与完整识别；建议只按规范名称匹配。内建名称、别名和目标只读。

            只识别以 / 开头、完整且不带参数的命令，大小写不敏感，完整识别允许结尾空白。未知命令、文件路径、带参数的文本和前置空白保持普通消息语义。Mac 输入 / 显示建议，可点击选择、用 ↑↓ 移动、Tab 补全，再用 ⌘Return 提交。自定义命令先把完整提示词填入输入框，下一次提交才发送；即使提示词本身是 /stop 也按文字发送，不递归执行。输入改变、会话切换、关闭开关、锁定及数据恢复会淘汰旧建议，提交重新解析当前草稿。

            Mac /model 打开全局模型选择页，当前会话首选模型仍优先；/sessions 展开历史列并清除旧筛选；/settings 打开原生设置窗口，其他管理命令打开已有的独立页面。/compact 只打开压缩选项，仍需原生确认生成；/retry 按 Core 的最新可重试回复规则执行，/stop 停止当前生成。/temporary 沿用 Core 首次开启、两秒内切换记忆模式、随后关闭并保存有内容临时会话的行为，普通会话已经开始后不能开启。/clear 清空输入及附件并使迟到的附件提取失效。

            Mac 从拓展功能→快速指令配置。开关立即保存；自定义编辑器须点击保存，触发词可省略开头的 /，保存时规范为小写，允许字母、数字、短横线和下划线，不能使用内建名称或别名，也不能重名或保存空提示词。正文保留缩进和换行。删除需要原生确认。编辑与整表替换在后台比较读取时的原始 JSON 并写入同一事务，外部修改后要求重新打开，失败不覆盖原件；旧数据加载沿用无效项过滤，并避免重复标识造成列表身份冲突。

            页面向导可在根页经原生提案确认修改开关，以及批量创建、编辑、删除和排序自定义命令，确认后立即保存。单条编辑器只改 trigger/prompt 草稿，仍须原生保存；模型选择页可确认修改全局模型。介绍与删除确认各自只读。根页提供已经准备的列表与内建目录，不扫描聊天草稿；向导不能执行命令、发送消息、生成回复、切换临时会话或调用 MCP/快捷指令。离页、切标签、语言与配置改变、锁定和恢复使旧提案失效。Mac 保存、解析与准备在后台完成，备份/恢复/退出等待已接受写入与命令操作；当前源码仍需目标接入和完整工具链下的键盘、窗口焦点及真实行为验证。
            """ : """
            Quick commands are off by default. They use chat.slashCommands.enabled and the existing JSON list at chat.slashCommands.custom. Mac, iOS and watchOS share the format and Core parser. The 19 built-ins remain in this order: /new, /model, /sessions, /settings, /tools, /daily, /usage, /memory, /mcp, /skills, /shortcuts, /roleplay, /worldbook, /features, /temporary, /compact, /retry, /stop, /clear. Aliases include history, tool, pulse, stats, skill, extensions, temp and compress. Aliases match complete commands only; suggestions match canonical names. Built-in names, aliases and destinations are read-only.

            Recognition requires an initial slash and a complete command without arguments. It is case-insensitive and permits trailing whitespace. Unknown commands, paths, arguments and leading whitespace remain ordinary messages. On Mac, typing / shows suggestions. Click to choose, use Up/Down to move, Tab to complete, and Command-Return to submit. Custom commands fill the full prompt first and send only on a later submission. A prompt containing /stop is still sent literally, never recursively executed. Input/session changes, disabling, locking and restoration discard old suggestions. Submission reparses the current draft.

            On Mac, /model opens global model selection while a session preference still takes priority. /sessions reveals history and resets filters. /settings opens the native Settings window, and other management commands open their existing pages. /compact opens options and still requires native generation confirmation. /retry uses Core eligibility for the latest response; /stop stops the current request. /temporary keeps Core behavior: enable on first use, switch memory mode within two seconds, then disable and save a nonempty temporary chat. It cannot start after a regular conversation has begun. /clear removes the draft and attachments and invalidates late attachment extraction.

            Configure commands in Extended Features → Quick Commands. The switch saves immediately; a custom editor requires Save. Triggers may start with /, normalize to lowercase and accept letters, digits, hyphens and underscores. Built-ins, aliases, duplicate triggers and empty prompts are rejected. Prompt indentation and newlines are preserved. Deletion requires native confirmation. Background writes compare the original JSON and update it in one transaction. External changes require reopening; failures retain the original. Loading preserves legacy invalid-item filtering and rejects duplicate identities.

            After native proposal confirmation, the root page guide can change the switch or replace the custom list, including creation, editing, deletion and reordering; these changes save immediately. The single editor changes trigger/prompt drafts only and still needs Save. The model picker supports confirmed global model changes. Introduction and deletion confirmation are independently read-only. The root exposes a prepared catalog and does not inspect chat drafts. The guide cannot execute commands, send messages, generate responses, toggle temporary chat or run MCP/Shortcuts. Leaving, tab/language/configuration changes, locking and restoration invalidate old proposals. Mac parsing, preparation and persistence run in the background; backup, restoration and termination drain accepted writes and command operations. Target integration and keyboard, focus and real behavior still need a complete toolchain.
            """)
    }
}

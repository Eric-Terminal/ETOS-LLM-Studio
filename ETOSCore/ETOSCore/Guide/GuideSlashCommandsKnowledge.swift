import Foundation

public enum GuideSlashCommandsKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "slash-commands",
            title: chinese ? "快速指令与页面跳转" : "Quick Commands and Navigation",
            keywords: ["快速指令", "斜杠", "别名", "提示词", "slash commands", "custom prompt", "Mac"],
            content: chinese ? """
            “快速指令”让你在聊天输入框里敲一个斜杠 `/`，就能双手不离键盘快速新建对话、切换模型、打开常用管理页，或者把一段常用的长提示词一键填入输入框。iOS、watchOS 和 Mac 共用同一套指令配置。

            怎么开启与在聊天中使用：
            • 开启位置：该功能默认关闭，前往“设置 → 拓展功能 → 快速指令”打开总开关即可立即生效。
            • 输入与补全：在 Mac 聊天输入框输入 `/` 会自动弹出候选指令列表，支持鼠标点击、`↑` / `↓` 方向键移动、`Tab` 键补全，再按 `⌘Return`（或发送按钮）执行。
            • 防误触规则：只有以 `/` 开头、单独完整输入且后面不带额外参数的指令才会被触发（不区分大小写，末尾允许空格）。如果你输入的是电脑文件路径（如 `/Users/...`）、未定义的词、前面有空格或后面跟了补充文字，都会原封不动当作普通聊天消息发出去，不会误触发。

            内置指令与自定义提示词指令的区别：
            • 内置指令固定共 19 项（名称、别名与跳转目标为系统固定，不可改名）：
              /new（新建会话）、/model（打开全局模型选择页，若当前会话设了专属首选模型仍以其优先）、/sessions（展开会话列表并清空筛选）、/settings（打开设置窗口）、/tools（工具中心）、/daily（每日脉冲）、/usage（用量统计）、/memory（记忆）、/mcp、/skills、/shortcuts（快捷指令）、/roleplay（角色扮演）、/worldbook（世界书）、/features（拓展功能）、/temporary（开启/切换临时对话；普通对话已有消息后不可开启）、/compact（打开压缩续聊选项页，仍需你手动确认创建）、/retry（重新生成最新一条可重试回复）、/stop（停止当前生成）、/clear（清空输入框文字与待发附件）。
              此外还支持输入完整别名触发，例如 history、tool、pulse、stats、skill、extensions、temp、compress（候选列表按标准名称提示）。
            • 自定义提示词指令：触发自定义指令时，系统只会把预设好的整段提示词填进输入框草稿，等你检查或补充后再手动发送；哪怕你的预设文字本身就是 `/stop` 这类以 `/` 开头的内容，下一次点发送时也会当作普通文字发出，绝不会循环套娃执行。

            怎么管理自定义指令与向导边界：
            • 在“快速指令”设置页可以新增、编辑、排序或删除自定义指令。单条编辑窗口修改的是草稿，填好触发词（可省去开头的 `/`，保存时自动转为小写，支持字母、数字、短横线 `-` 与下划线 `_`，不可与内置指令或别名重名）和提示词正文（完整保留缩进与换行，不可为空）后，需点击“保存”才会生效；删除需手动确认。
            • 在快速指令主页，页面向导经你原生确认后可以帮你开关总控，或批量新增、修改、删除和重排自定义指令（主页确认后立即保存；若在单条编辑窗口内，向导只改草稿，仍需你手动点保存）。在 `/model` 打开的模型选择页，向导也可协助提议切换全局模型。
            • 向导不会读取你正在聊天框里写的草稿，向导不能执行命令、不能替你发送消息、停止生成、切换临时对话，也不能运行任何 MCP 或快捷指令。
            """ : """
            Quick Commands let you type a slash (`/`) right in the chat box to start a new chat, switch models, jump straight to settings pages or drop a favorite prompt template into your composer without leaving the keyboard. Mac, iOS and watchOS share the same command setup.

            How to enable and use Quick Commands:
            • Where to enable: Quick Commands are off by default. Turn them on in Settings → Extended Features → Quick Commands; the main switch saves immediately.
            • Typing and completion: on Mac, typing `/` brings up matching suggestions—click an item, use the Up/Down arrow keys to highlight, press Tab to complete and press Command-Return to trigger.
            • Safe matching rules: only a standalone, complete command starting with `/` (case-insensitive, with no extra arguments or leading spaces) triggers an action. File paths like `/Users/...`, unknown words or commands followed by extra text are treated as ordinary chat messages so you never trigger actions by accident.

            Built-in navigation vs. custom prompt templates:
            • Nineteen built-in commands are available in a fixed order (their names, aliases and targets are read-only):
              /new, /model (opens global model selection while keeping any session-preferred model priority), /sessions (opens your chat list and clears active filters), /settings, /tools, /daily, /usage, /memory, /mcp, /skills, /shortcuts, /roleplay, /worldbook, /features, /temporary (starts or switches Temporary Chat before messages begin), /compact (opens compression options—manual creation confirmation is still required), /retry (regenerates the latest eligible reply), /stop (stops active generation) and /clear (clears your draft text and pending attachments).
              Complete aliases such as history, tool, pulse, stats, skill, extensions, temp and compress are also recognized when typed in full.
            • Custom prompt commands: triggering a custom command only fills its prompt text into your composer draft so you can review or edit before sending. Even if a custom prompt itself starts with `/` (such as `/stop`), your next send treats it as plain text—it is never recursively executed as a command.

            Managing custom commands and guide boundaries:
            • Add, edit, reorder or delete custom commands on the Quick Commands settings page. Editing an individual command updates a draft until you click Save: triggers normalize to lowercase letters, digits, hyphens and underscores (the leading `/` is optional, and built-in names, aliases, duplicates and empty prompts are rejected), while prompt bodies preserve all indentation and line breaks. Deleting a command requires native confirmation.
            • On the Quick Commands root page, the guide can toggle the main switch or propose creating, editing, reordering and deleting custom commands—saving immediately once you confirm the native prompt (inside the single-command editor, guide proposals edit the draft only and still require Save). The `/model` picker also supports confirmed global model proposals.
            • The guide never inspects your chat composer draft, and it cannot execute commands, send messages, generate replies, toggle Temporary Chat or invoke MCP tools or Shortcuts.
            """
        )
    }
}

import Foundation

public enum GuideChatQuickActionsKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "chat-quick-actions",
            title: chinese ? "聊天快捷功能" : "Chat Quick Actions",
            keywords: ["快捷功能", "菜单", "入口", "Mac", "临时对话", "quick actions", "menu", "navigation"],
            content: chinese ? """
            iOS 与 Mac 使用相同的 ui.chatQuickActionIDs 数据库配置和 15 个稳定标识：temporaryChat、contextCompression、settings、toolCenter、dailyPulse、usageAnalytics、memory、mcp、agentSkills、shortcuts、roleplay、worldbook、extendedFeatures、browser、localTerminal。显示和保存按此固定顺序，重复值去重，未知值忽略；空值或全部未知时回到全部功能。watchOS 仍使用独立的输入快捷配置，没有改写其设置。

            Mac 在设置→通用→显示设置→聊天快捷功能选择工具栏入口，至少保留一项，修改立即保存；同步或其他窗口的更改会重新准备目录。单选显示该入口，多选显示原生菜单。临时对话保留原生子菜单，可选择允许记忆、隔离记忆或手动保存；设置使用系统 Settings 窗口，脉冲和续聊使用各自工作表。其余入口打开独立导航工作表，不因打开配置而发送消息、执行工具或开始压缩。Linux 终端仅在本地 Linux 已启用时可进入，可先从工具中心或拓展功能配置运行时。浏览器固定打开时的会话与临时状态，切换来源会话后关闭。

            页面向导只能经原生确认修改 actions 这个已选标识数组；数组必须非空、无重复且全部来自目录。确认后立即保存，不需要额外保存按钮。不能通过向导触发快捷功能、改变临时模式、创建压缩会话、打开终端或执行 MCP/快捷指令。介绍页独立只读；离页、锁定、配置或语言变化使旧提案失效，提交前核对当前原始配置，拒绝覆盖外部修改。目录、标签和向导值在后台准备，不在 SwiftUI 渲染中解码 CSV。

            记忆系统入口包含启用记忆、允许写入、异步跨对话记忆，以及记忆库和画像管理。总开关关闭后原偏好与已有记忆保留，页面向导只确认修改开关，具体记录到管理页处理。Mac 拓展功能目前连接本地模型、本地 Linux、快照备份、数据导入、iCloud 同步和应用锁，各目的页保留自身向导与原生确认；根页只声明导航入口，不能代替子页执行配置。数据导入的七类来源、预览与独立确认详见 data-import。移动端拓展功能中的快速指令、反馈、图片相册、远程文件访问、完整存储管理及连接例外管理仍须继续补齐 Mac 源码，不应把这个导航根页视为完整功能对齐。
            """ : """
            iOS and Mac share ui.chatQuickActionIDs and these 15 stable identifiers: temporaryChat, contextCompression, settings, toolCenter, dailyPulse, usageAnalytics, memory, mcp, agentSkills, shortcuts, roleplay, worldbook, extendedFeatures, browser, localTerminal. Display and serialization use this fixed order, deduplicate values and ignore unknown identifiers. Empty or entirely unknown values select all actions. watchOS keeps its separate input shortcut configuration.

            On Mac, choose toolbar entries in Settings → General → Display → Chat Quick Actions. Keep at least one action; changes save immediately and external configuration changes refresh the catalog. A single selection displays that entry directly; multiple selections open a native menu. Temporary Chat keeps its submenu for memory mode and manual saving. Settings opens the system Settings window; Daily Pulse and compression use their existing sheets. Other entries open navigation sheets without sending messages, executing tools or starting compression just to open configuration. Linux Terminal requires enabled local Linux; configure it in Tool Center or Extended Features first. Browser navigation retains the original session and temporary state and closes when that source session changes.

            The page guide can propose only the actions array after native confirmation. It must be nonempty, unique and contain catalog identifiers only. Confirmation saves immediately; there is no extra Save button. The guide cannot launch an action, change temporary mode, create a continuation, open a terminal or execute MCP or Shortcuts. Introductions are independently read-only. Leaving, locking, configuration changes and language changes invalidate old proposals. Submission checks the original configuration to reject overwriting external changes. CSV decoding, labels and guide values are prepared outside SwiftUI rendering.

            Memory System provides enable, write permission and asynchronous cross-conversation memory switches, plus library and profile management. Disabling the main switch retains preferences and stored memories. The guide changes switches only after confirmation; records belong to their management pages. Mac Extended Features currently links local models, local Linux, snapshot backups, data import, iCloud sync and app lock. Each destination retains its own guide and native confirmation; the root exposes navigation only. See data-import for the seven sources, preview and separate import confirmation. Mobile extended features such as slash commands, feedback, image gallery, remote file access, full storage management and connection exception management still require Mac source work. This navigation root does not prove full feature parity.
            """)
    }
}

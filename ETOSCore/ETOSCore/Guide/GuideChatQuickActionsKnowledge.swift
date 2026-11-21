import Foundation

public enum GuideChatQuickActionsKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "chat-quick-actions",
            title: chinese ? "聊天快捷功能" : "Chat Quick Actions",
            keywords: ["快捷功能", "菜单", "入口", "Mac", "临时对话", "quick actions", "menu", "navigation"],
            content: chinese ? """
            “聊天快捷功能”让你自己决定聊天界面周围摆哪些常用入口、哪些收进“更多”菜单、哪些干脆隐藏，让界面既顺手又不拥挤。iOS 与 Mac 共享同一套快捷入口配置（Apple Watch 保留独立的输入快捷设置），共包含 16 个功能项：
            temporaryChat（临时对话）、modelPicker（选择模型）、contextCompression（压缩续聊）、settings（设置）、toolCenter（工具中心）、dailyPulse（每日脉冲）、usageAnalytics（用量统计）、memory（记忆）、mcp、agentSkills（Skills 技能）、shortcuts（快捷指令）、roleplay（角色扮演）、worldbook（世界书）、extendedFeatures（拓展功能）、browser（会话浏览器）、localTerminal（本地终端）。

            去哪里调整、在不同设备上怎么显示：
            • iOS / iPadOS：打开“设置 → 显示设置 → 聊天快捷功能”，为每个入口选择“工具栏”、“更多”或“隐藏”，点右上角“编辑”可拖动调整显示顺序（至少保留开启一项），修改立即保存。
              - 在运行 iOS 27.1 及更高版本的 iPhone Duo 和 iPad 上，标记为“工具栏”的优先项会直接展示在系统工具栏上（iPhone Duo 在内外屏会自动切换横向或侧边工具栏；当窗口较窄放不下时，多余按钮仍会自动收进“更多”）。左侧会话列表按钮始终独立保留。
              - 普通 iPhone 无论系统版本都保留原来的顶部导航和快捷菜单，运行旧版 iOS 的设备也沿用原有导航；它们会按你排好的顺序展示已启用功能，同时把你的工具栏偏好同步给 iPad 或 Mac。图标对应关系：眼睛代表临时对话，芯片（CPU）代表选择模型，柱状图（chart.bar）代表用量统计。
            • Mac：打开“设置 → 通用 → 显示设置 → 聊天快捷功能”（或从“背景与视觉”进入），使用上下箭头调整顺序，修改立即保存。设为优先的功能直接摆在输入框下方的快捷栏，其余已启用项收进“更多”（窗口过窄时会自动收拢为一个菜单）。
              - 点“临时对话”会弹出记忆模式子菜单（允许记忆、隔离记忆或手动保存为正式会话）；点“选择模型”、“每日脉冲”、“压缩续聊”会打开各自面板；点“设置”会打开系统设置窗口；其余入口打开对应的功能管理面板，不会因为点开面板就自动发消息或跑工具。会话浏览器跟随打开时的对话，切换对话后自动关闭；本地终端需先在工具中心或拓展功能中开启本机 Shell（iOS 上为本地 Linux）。

            相关功能延伸导览：
            • 记忆面板：可开关记忆总控、写入权限和跨对话记忆，或进入记忆库与画像管理（关闭总开关不会清空你已经存好的记忆）。
            • 拓展功能面板：集中收录了批量任务、快速指令（详见 slash-commands）、本地模型、本机 Shell / 本地 Linux、快照备份、数据导入（详见 data-import）、存储管理（详见 storage-management）、iCloud 同步、应用锁与连接例外（详见 network-connection-exceptions）等进阶入口。

            页面向导说明与安全边界：
            • 在聊天快捷功能设置页，向导可以帮你草拟有序的已启用列表（actions，不可为空、不可重复）与优先放在工具栏的列表（toolbar_actions，仅对已启用项生效，可留空表示全部放进“更多”）。经你原生确认后立即生效，不需要再点保存按钮；离开页面或外部配置更新后，未确认的旧建议会自动作废。
            • 不能通过向导触发快捷功能，向导也不能替你切换临时对话模式、创建压缩续聊、打开终端或执行任何 MCP 服务与快捷指令。
            """ : """
            Chat Quick Actions lets you customize which shortcuts stay within one-tap reach around the chat view, which move into the More menu and which stay hidden. iOS and Mac share the same configuration and sync your order across devices (watchOS keeps its own compact input shortcut settings). Sixteen built-in entries are available:
            temporaryChat, modelPicker, contextCompression, settings, toolCenter, dailyPulse, usageAnalytics, memory, mcp, agentSkills, shortcuts, roleplay, worldbook, extendedFeatures, browser and localTerminal.

            Where to configure and how each device displays them:
            • iOS and iPadOS: open Settings → Display → Chat Quick Actions to assign each item to Toolbar, More or Hidden, and tap Edit to drag enabled items into your preferred order (keep at least one item enabled). Changes save immediately.
              - On iPhone Duo and iPad running iOS 27.1 and later, Toolbar items appear directly in the native toolbar—iPhone Duo adapts between horizontal and side toolbars across both displays, and items gracefully overflow into More when window space is tight. The conversation list button always stays separate.
              - Other iPhones keep the original top navigation and shortcut menu regardless of iOS version, as do devices on earlier iOS versions; they follow your enabled list order while still syncing your toolbar preferences to iPad and Mac. For icons: the eye is Temporary Chat, the CPU chip is Choose Model and chart.bar is Usage Analytics.
            • Mac: open Settings → General → Display → Chat Quick Actions (also linked under Background & Appearance) and use the up/down arrows to reorder items. Changes save immediately. Preferred items sit right beside the composer while the rest stay in More, collapsing into a single menu in narrow windows.
              - Temporary Chat keeps its submenu for memory modes and manual saving; Choose Model, Daily Pulse and Context Compression open their dedicated sheets; Settings opens the Mac Settings window; and other entries open their management sheets without sending messages or running tools. Browser sheets stay tied to the conversation where you opened them, and Local Terminal requires enabling Local Shell (or Local Linux on iOS) first.

            Related features reachable from Quick Actions:
            • Memory System: toggle memory, write access and cross-conversation memory, or manage your saved memories and profile (turning off the main switch safely keeps existing memories).
            • Extended Features: jump to Batch Tasks, Quick Commands (see slash-commands), Local Models, Local Shell / Local Linux, Snapshot Backups, Data Import (see data-import), Storage Management (see storage-management), iCloud Sync, App Lock and Connection Exceptions (see network-connection-exceptions).

            Guide support and safety boundaries:
            • On the Chat Quick Actions settings page, the guide can propose ordered actions (must include at least one valid, non-duplicate item) and toolbar_actions (may be empty to place everything under More; applies only to enabled items). Changes save immediately once you confirm the native prompt, and stale proposals expire if you leave the page.
            • The guide cannot launch an action, switch temporary chat modes, start compression, open a terminal or run MCP tools or Shortcuts on your behalf.
            """
        )
    }
}

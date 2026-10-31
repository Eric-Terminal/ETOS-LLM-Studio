import Foundation

public enum GuideAdaptiveLayoutKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "adaptive-layout",
            title: chinese ? "窗口与折叠布局" : "Window and Folding Layouts",
            keywords: ["iPhone Duo", "折叠", "侧栏", "分屏", "布局", "窗口", "fold", "sidebar", "resize"],
            content: chinese ? """
            iOS 聊天按当前窗口可用宽度显示会话侧栏，收窄后保留单列聊天。打开键盘不锁定布局，折叠、展开和分屏不会主动切换会话或清空草稿；收起侧栏的选择会保留。iOS 27.1 及以后使用系统聊天工具栏，系统决定横向、侧向与溢出位置。会话入口独立保留；模型、临时对话等快捷功能的启用、顺序和优先位置在聊天快捷功能中配置，优先项空间不足时仍可能进入更多，详见 chat-quick-actions。输入框留在底部并跟随键盘，部分折叠时避开折痕；终端预览、角色脚本和输入区在空间不足时可滚动。

            设置首页根据实际宽度与辅助功能字号调整入口网格；活动竖折痕出现时使用独立原生列表行。这里只改变布局，不新增设置开关，也不修改数据库。页面向导使用当前根页或详情页各自的上下文，不能替用户折叠设备、改变窗口、发送消息或点击快捷功能。系统相机、照片选择器和分享面板由系统管理，不是向导可配置页面。watchOS 保持原生扁平列表，macOS 保持独立桌面布局。
            """ : """
            On iOS, available window width determines whether the conversation sidebar fits. Narrowing the window keeps a single conversation column. Opening the keyboard does not freeze layout; folding, unfolding and multitasking do not intentionally switch sessions or clear drafts. The choice to hide the sidebar is retained. On iOS 27.1 and later, system chat toolbars determine horizontal, vertical and overflow placement. The session entry stays separate. Chat Quick Actions configures enabled entries, order and preferred placement for models, Temporary Chat and other actions. Preferred items may still overflow when space is limited; see chat-quick-actions. The composer stays at the bottom with the keyboard and avoids an active fold. The docked terminal preview, script buttons and composer can scroll when space is limited.

            The settings root adapts its entry grid to actual width and accessibility text sizes, and uses separate native list rows around an active vertical fold. This changes layout only, with no new preference or database setting. The page guide uses each root or detail page's own context; it cannot fold the device, resize the window, send messages or invoke quick actions. System camera, photo and share interfaces are not guide-configurable pages. watchOS keeps its flat native list and macOS keeps its desktop layout.
            """
        )
    }
}

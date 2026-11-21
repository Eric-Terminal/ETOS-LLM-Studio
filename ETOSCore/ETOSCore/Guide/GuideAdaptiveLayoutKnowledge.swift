import Foundation

public enum GuideAdaptiveLayoutKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "adaptive-layout",
            title: chinese ? "窗口与折叠布局" : "Window and Folding Layouts",
            keywords: ["iPhone Duo", "折叠", "侧栏", "分屏", "布局", "窗口", "fold", "sidebar", "resize"],
            content: chinese ? """
            在 iPhone 和 iPad 上，聊天界面会根据当前窗口宽度自动调整布局：空间充裕时展开左侧会话栏，窗口收窄时自动切换为专注的单栏对话。弹出软键盘、开启分屏或展开/合上折叠屏时，你正在撰写的消息草稿和当前选中的会话都会稳妥保留，手动收起侧栏的偏好也会被记住。

            不同机型的工具栏与输入区表现：
            • iPhone Duo（运行 iOS 27.1 及更高版本）采用系统聊天工具栏，内外屏都会根据握持和窗口形态自动安排横向、侧边与“更多”菜单位置；iPad 在同版本下同样使用原生顶部工具栏。
            • 普通 iPhone 无论系统版本都保留原来的顶部导航和快捷菜单，运行旧版 iOS 的设备也沿用原有导航样式。
            • 会话列表入口始终独立保留；至于选择模型、临时对话等常用按钮的显示开关、排列顺序与工具栏优先位置，都可以去“聊天快捷功能”（详见 chat-quick-actions）自由调整。当窗口较窄放不下全部优先按钮时，多余按钮会自动收进“更多”菜单。
            • 聊天输入框始终贴合底部并跟随键盘升起，半折叠状态下会自动避开屏幕折痕；当纵向空间较紧时，终端预览条、角色脚本按钮和输入框内部都可以顺畅滚动。

            设置首页同样会根据屏幕宽度与系统辅助功能字号自动调整卡片网格，遇到竖向折痕时改为清爽的单列列表行。这些自适应效果完全由界面自动完成，不新增设置开关，也不改动你的任何配置数据。

            向导使用说明：页面向导只能结合你当前所在的设置页提供说明或配置建议，不能替用户折叠设备、改变窗口、发送消息或点击快捷功能；系统相机、相册选图和系统分享面板归属操作系统管理，不属于向导可配置的页面。Apple Watch（watchOS）继续保持一滑到底的扁平列表，Mac（macOS）保持独立的双栏桌面布局。
            """ : """
            On iOS and iPadOS, the chat window automatically adapts to its available width: wide windows show the conversation sidebar alongside the chat, while narrow windows switch cleanly to a single conversation column. Opening the keyboard, resizing Split View or folding and unfolding a device preserves your current session, unsent draft and sidebar visibility choice.

            Toolbar and composer layout across devices:
            • On iPhone Duo running iOS 27.1 and later, system chat toolbars automatically manage horizontal, vertical and overflow placement on both displays; iPad uses its native toolbar on those versions as well.
            • Other iPhones keep the original top navigation and shortcut menu regardless of iOS version, as do devices on earlier iOS versions.
            • The conversation list button stays separate. You can customize which shortcuts appear, their order and preferred toolbar placement in Chat Quick Actions (see chat-quick-actions); preferred toolbar buttons gracefully move into More whenever window space gets tight.
            • The message composer stays anchored above the keyboard and steps around an active screen fold. When vertical room is limited, the docked terminal preview, roleplay script buttons and composer remain scrollable.

            The Settings home page also adjusts its grid to match window width and Dynamic Type sizes, switching to clean list rows across a vertical fold. All of this happens automatically—there is no new preference or database setting to toggle.

            Guide boundaries: the page guide works within whichever settings page you currently have open; it cannot fold the device, resize the window, send messages or invoke quick actions. System camera, photo picker and share sheets are managed by the OS and are not guide-configurable pages. watchOS keeps its flat single-column list and macOS keeps its two-column desktop layout.
            """
        )
    }
}

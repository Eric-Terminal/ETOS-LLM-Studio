import Foundation

public enum GuideChatAvatarKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "chat-avatars", title: chinese ? "聊天头像" : "Chat Avatars",
            keywords: ["头像", "间距", "气泡上方", "时间", "提示词", "角色卡", "酒馆", "用户身份", "avatar", "persona", "spacing"], content: chinese ? """
            iOS、watchOS 和 macOS 从设置→提示词→聊天头像进入。显示 AI 头像与显示用户头像是两个独立开关，默认关闭，立即保存到数据库，对所有会话生效。AI 头像在消息左侧，本人头像在右侧；无图片时显示系统符号。头像只用于显示，不加入模型请求。

            头像位置可选气泡侧边（side，默认）或气泡上方（above）。侧边布局与消息顶部对齐；上方布局把头像与名称放在气泡外，不再占用正文横向宽度。左右留白与头像消息间距均为 0–24 点，默认 6 点，仅影响开启头像的消息；间距在侧边布局为横向，在上方布局为纵向。Mac 的留白相对于居中的消息阅读区域。

            多轮工具调用按整轮回复显示一个头像。侧边头像固定在这一轮顶部，后续工具结果与助手续写保留相同缩进；上方布局只在轮首显示一组头像、名称和可选时间，不在每次工具续写时重复。时间使用轮首显示消息的时间，工具详情中的执行时间不变。分组沿用回复组与重试版本边界，新用户消息开始新一轮；旧历史沿用连续助手消息的分组规则。分页或截取导出从半轮开始时，在首条可见消息恢复标题。

            上方布局的 AI 名称使用当前全局提示词名称，酒馆使用首个有效角色卡名称；用户名称普通聊天显示“我”，酒馆使用绑定用户身份名称。名称与图片回退互不影响。名称下方时间默认关闭，仅在上方布局生效；打开后显示消息日期和时间，没有记录时间的旧消息不显示。此开关不改变消息操作栏中的时间。

            通用 AI 头像与用户头像在聊天头像页分别设置。全局提示词列表的“设置头像”进入独立编辑页，iOS/watchOS 可左滑，iOS 和 Mac 也提供菜单操作；选中另一条提示词会切换 AI 头像，复制提示词时保留头像。已有历史消息也跟随当前选择。

            头像优先级：酒馆会话的首个有效角色卡头像优先于当前全局提示词头像，再回退通用 AI 头像。酒馆会话绑定的用户身份头像优先于通用用户头像。只有会话绑定了有效角色卡才启用酒馆覆盖；缺少头像按上述顺序回退。头像显示独立于 HTML 渲染与助手脚本，角色作者无需在内联内容中引用头像。

            角色卡详情→设置头像可以替换角色图片；用户身份中设置酒馆用户头像，手表点击已有身份可更换头像。iPhone 和 Mac 支持照片与文件选择，手表支持 HTTP/HTTPS 图片链接。图片选择和清除立即保存，身份草稿原有的保存按钮仍需手动确认。照片选择器与文件选择器是系统页面，不提供应用向导。清除角色头像不会删除角色卡内的资源文件。

            聊天头像设置、各头像编辑页、全局提示词列表、角色详情与说明页分别声明向导上下文。向导可以提案修改两个显示开关、avatar_position、avatar_edge_inset、avatar_message_spacing 与 avatar_header_timestamp，必须通过原生确认；更改立即保存，不是草稿。头像编辑页只公开是否已有图片和保存状态，不公开图片、路径或下载链接，不能让向导下载、更换或清除图片。切页后旧提案失效，向导不获得普通聊天工具、MCP 或快捷指令权限。
            """ : """
            On iOS, watchOS and macOS, open Settings → Prompts → Chat Avatars. Show AI Avatar and Show User Avatar are independent switches, off by default, saved immediately to the database for all conversations. AI avatars appear on the left and your avatar on the right. A system symbol is used without an image. Avatars are display-only and are not sent to the model.

            Avatar Position supports Beside Bubble (side, default) and Above Bubble (above). Side avatars align with the message top. Above-bubble headers place the avatar and name outside the bubble, freeing horizontal space for content. Side margins and the avatar–message gap each range from 0 to 24 points, defaulting to 6, and affect only messages with visible avatars. The gap is horizontal beside the bubble and vertical above it. On Mac, margins are relative to the centered reading area.

            Multiple tool calls within one reply share one avatar. Beside the bubble, the avatar stays at the top of the turn while tool results and assistant continuations keep the same inset. Above the bubble, the avatar, name and optional time appear once at the turn's start. The time comes from the first displayed message; tool execution times in tool details are unchanged. Grouping follows response groups and retry attempts, with new user messages starting a new turn. Legacy history follows consecutive assistant-turn grouping. A page or partial image export starting mid-turn restores the header at its first visible message.

            Above-bubble AI names follow the selected global prompt or the first valid roleplay character. User names are Me in ordinary chats and the bound persona name in roleplay. Image fallback does not change the name. Show Time Below Name defaults to off and applies only above the bubble. It adds the message date and time; messages without recorded times omit it. The message action bar's time is independent.

            Set default AI and user images here. Set Avatar in the global prompt list opens a separate editor; swipe on iOS/watchOS or use the iOS/Mac menu. Selecting a prompt also changes its AI avatar, including for existing messages. Prompt copies retain their avatar.

            Priority: the first valid character card in an active roleplay conversation, then the selected global prompt, then the default AI avatar. The bound roleplay persona overrides the default user avatar. Roleplay overrides require a valid bound character; missing images fall back. Native avatars work independently of HTML and helper scripts, without author-provided avatar markup.

            Change character images from character details and user images from User Personas. On Apple Watch, select an existing persona to change its avatar. iPhone and Mac support Photos and image files; Apple Watch accepts HTTP/HTTPS image URLs. Image changes and clearing save immediately; existing persona draft editors still require Save. System photo/file pickers do not expose an app guide. Clearing a character avatar preserves embedded assets.

            Settings, image editors, prompt lists, character details and help each declare separate guide contexts. The two visibility switches, avatar_position, avatar_edge_inset, avatar_message_spacing and avatar_header_timestamp accept guide proposals with native confirmation. Changes save immediately, rather than editing a draft. Image editors expose presence and saving status, never image data, paths or download URLs. The guide cannot download, replace or clear images, and gains no chat, MCP or shortcut tools. Navigation invalidates old proposals.
            """)
    }
}

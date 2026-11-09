import Foundation

public enum GuideChatAvatarKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "chat-avatars", title: chinese ? "聊天头像" : "Chat Avatars",
            keywords: ["头像", "提示词", "角色卡", "酒馆", "用户身份", "avatar", "persona"], content: chinese ? """
            iOS、watchOS 和 macOS 从设置→提示词→聊天头像进入。显示 AI 头像与显示用户头像是两个独立开关，默认关闭，立即保存到数据库，对所有会话生效。AI 头像在消息左侧，本人头像在右侧；无图片时显示系统符号。头像只用于显示，不加入模型请求。

            通用 AI 头像与用户头像在聊天头像页分别设置。全局提示词列表的“设置头像”进入独立编辑页，iOS/watchOS 可左滑，iOS 和 Mac 也提供菜单操作；选中另一条提示词会切换 AI 头像，复制提示词时保留头像。已有历史消息也跟随当前选择。

            头像优先级：酒馆会话的首个有效角色卡头像优先于当前全局提示词头像，再回退通用 AI 头像。酒馆会话绑定的用户身份头像优先于通用用户头像。只有会话绑定了有效角色卡才启用酒馆覆盖；缺少头像按上述顺序回退。头像显示独立于 HTML 渲染与助手脚本，角色作者无需在内联内容中引用头像。

            角色卡详情→设置头像可以替换角色图片；用户身份中设置酒馆用户头像，手表点击已有身份可更换头像。iPhone 和 Mac 支持照片与文件选择，手表支持 HTTP/HTTPS 图片链接。图片选择和清除立即保存，身份草稿原有的保存按钮仍需手动确认。照片选择器与文件选择器是系统页面，不提供应用向导。清除角色头像不会删除角色卡内的资源文件。

            聊天头像设置、各头像编辑页、全局提示词列表、角色详情与说明页分别声明向导上下文。向导可以提案修改两个显示开关，必须通过原生确认；头像编辑页只公开是否已有图片和保存状态，不公开图片、路径或下载链接，不能让向导下载、更换或清除图片。切页后旧提案失效，向导不获得普通聊天工具、MCP 或快捷指令权限。
            """ : """
            On iOS, watchOS and macOS, open Settings → Prompts → Chat Avatars. Show AI Avatar and Show User Avatar are independent switches, off by default, saved immediately to the database for all conversations. AI avatars appear on the left and your avatar on the right. A system symbol is used without an image. Avatars are display-only and are not sent to the model.

            Set default AI and user images here. Set Avatar in the global prompt list opens a separate editor; swipe on iOS/watchOS or use the iOS/Mac menu. Selecting a prompt also changes its AI avatar, including for existing messages. Prompt copies retain their avatar.

            Priority: the first valid character card in an active roleplay conversation, then the selected global prompt, then the default AI avatar. The bound roleplay persona overrides the default user avatar. Roleplay overrides require a valid bound character; missing images fall back. Native avatars work independently of HTML and helper scripts, without author-provided avatar markup.

            Change character images from character details and user images from User Personas. On Apple Watch, select an existing persona to change its avatar. iPhone and Mac support Photos and image files; Apple Watch accepts HTTP/HTTPS image URLs. Image changes and clearing save immediately; existing persona draft editors still require Save. System photo/file pickers do not expose an app guide. Clearing a character avatar preserves embedded assets.

            Settings, image editors, prompt lists, character details and help each declare separate guide contexts. Only the two visibility switches accept guide proposals with native confirmation. Image editors expose presence and saving status, never image data, paths or download URLs. The guide cannot download, replace or clear images, and gains no chat, MCP or shortcut tools. Navigation invalidates old proposals.
            """)
    }
}

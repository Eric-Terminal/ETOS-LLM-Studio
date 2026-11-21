import Foundation

public enum GuideChatAvatarKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "chat-avatars",
            title: chinese ? "聊天头像" : "Chat Avatars",
            keywords: ["头像", "间距", "气泡上方", "时间", "提示词", "角色卡", "酒馆", "用户身份", "avatar", "persona", "spacing"],
            content: chinese ? """
            想让对话界面更有陪伴感或更容易区分不同助手身份，可以在 iOS、watchOS 和 macOS 上打开“设置 → 提示词 → 聊天头像”。“显示 AI 头像”与“显示用户头像”是两个彼此独立的开关，默认关闭，切换后立即对所有对话生效（无需额外点保存）。AI 头像显示在消息左侧，你的头像显示在右侧；还没上传图片时会显示简洁的系统默认图标。所有头像仅用于界面展示，不会发送给大模型。

            布局位置、间距与名称时间：
            • 头像位置：支持“气泡侧边”（side，默认，与消息顶部对齐）和“气泡上方”（above，把头像与名称放到消息气泡上方，不再挤占正文的横向阅读宽度）。
            • 边距与间距：左右边缘留白和头像与消息之间的距离都可以在 0–24 点之间自由调节（默认 6 点，仅对开启了头像的一侧生效；Mac 上的边缘留白以居中阅读区为基准）。
            • 多轮工具调用合并展示：多轮工具调用按整轮回复显示一个头像。选“气泡侧边”时，头像固定在这一轮回复开头，后续工具结果和续写正文保持整齐缩进；选“气泡上方”时，整轮回复只在开头显示一次头像、名称和可选时间，不会每次调用工具都重复刷出一行头像。
            • 名称与时间（仅“气泡上方”生效）：普通对话中 AI 显示当前选中的全局提示词标题，你显示“我”；角色扮演（酒馆）对话中则分别显示首个有效角色卡名称与绑定的用户身份名称。“名称下方显示时间”默认关闭，开启后会展示该条消息的日期和时间（不影响消息底部操作栏里的时间项）。

            怎么设置专属头像及显示优先级：
            • 默认头像：直接在“聊天头像”页面分别上传通用 AI 头像和通用用户头像。
            • 提示词专属头像：在“全局系统提示词”列表中，对任意提示词点“设置头像”（iOS / watchOS 支持左滑，iOS / Mac 也支持菜单操作），切换提示词时聊天里的 AI 头像就会自动跟着切换，复制提示词时也会保留头像。
            • 酒馆角色与身份头像：在角色卡详情页点“设置头像”更换角色头像，在“用户身份”页更换酒馆玩家头像（Apple Watch 点击已有身份即可更换）。iPhone 和 Mac 支持从系统相册或本地文件选图，Apple Watch 支持输入 HTTP/HTTPS 图片链接。选好或清除图片都是立即保存生效（若同时在编辑用户身份的文字资料，文字草稿本身仍需点保存）。清除角色的自定义头像不会删掉角色卡内置的原始图片素材。
            • 覆盖优先级：如果当前会话绑定了有效的酒馆角色卡，AI 头像优先显示首个有效角色卡头像 → 没有则看当前全局提示词头像 → 最后回退到通用 AI 头像；用户头像优先显示绑定的酒馆用户身份头像 → 没有则回退到通用用户头像。这套原生头像完全独立于角色 HTML 渲染与助手脚本，无需在卡片代码里手写头像标签。

            向导使用与隐私边界：
            • 在聊天头像设置页，页面向导可以帮你生成修改两个显示开关以及 avatar_position（位置）、avatar_edge_inset（边缘留白）、avatar_message_spacing（头像消息间距）、avatar_header_timestamp（名称下方时间）的提案，经你原生确认后立即生效。
            • 头像上传页只向向导说明当前是否已设置图片，不公开图片、路径或下载链接；向导不能替你下载、更换或清除图片，系统相册和文件选择器内也不提供向导操作。离开当前页面后，未确认的旧提案会自动失效。
            """ : """
            To personalize your conversations or tell different assistants apart at a glance, open Settings → Prompts → Chat Avatars on iOS, watchOS and macOS. Show AI Avatar and Show User Avatar are independent switches, off by default, and take effect immediately across all conversations as soon as you toggle them. AI avatars appear on the left and yours on the right, falling back to a clean system symbol until you pick an image. Avatars are purely visual and are never sent to the model.

            Placement, spacing, names and timestamps:
            • Avatar Position: choose Beside Bubble (side, the default, aligned with the top of the message) or Above Bubble (above, placing the avatar and name above the bubble so the message keeps full horizontal width).
            • Margins and spacing: both edge margins and the avatar-to-message gap adjust from 0 to 24 points (6 by default) for whichever side has avatars enabled. On Mac, margins are measured from the centered reading column.
            • Clean tool-call grouping: Multiple tool calls within one reply share one avatar. Beside the bubble, the avatar stays anchored at the start of the reply while tool results and follow-up text keep a matching indent; above the bubble, the avatar, name and optional timestamp appear once at the top of the turn instead of repeating after every tool step.
            • Names and timestamps (Above Bubble only): AI names follow the active global prompt, or the first valid character in a roleplay chat; your name shows as Me in regular chats or your bound persona name in roleplay. Show Time Below Name is off by default and displays the message date and time independently of the bottom message action bar.

            Customizing avatars and fallback priority:
            • Default avatars: set your general AI and user images right on the Chat Avatars page.
            • Per-prompt AI avatars: choose Set Avatar on any entry in Global System Prompts (swipe on iOS/watchOS or use the menu on iOS/Mac). Switching prompts switches the AI avatar automatically, and duplicating a prompt keeps its avatar.
            • Roleplay character and persona avatars: update character portraits from Character Details and player portraits from User Personas (on Apple Watch, tap an existing persona to change its avatar). iPhone and Mac pick from Photos or image files, while watchOS accepts HTTP/HTTPS image links. Choosing or clearing an image saves right away, though text edits inside a persona editor still need manual Save. Clearing a custom character avatar never deletes assets bundled inside the card.
            • Priority order: in an active roleplay chat, AI avatars prefer the first valid character card → active global prompt → default AI avatar; user avatars prefer the bound persona → default user avatar. Missing images fall back smoothly, and native avatars work independently of HTML cards and helper scripts.

            Guide support and privacy:
            • On the Chat Avatars settings page, the guide can propose updates to the two visibility switches, avatar_position, avatar_edge_inset, avatar_message_spacing and avatar_header_timestamp; changes save immediately after native confirmation.
            • Image editors only tell the guide whether an image is set—never image data, local paths or download URLs. The guide cannot download, replace or clear images, and old proposals expire when you leave the page.
            """
        )
    }
}

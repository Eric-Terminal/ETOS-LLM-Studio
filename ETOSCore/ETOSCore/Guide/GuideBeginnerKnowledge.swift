import Foundation

enum GuideBeginnerKnowledge {
    static let documents: [GuideDocument] = [
        GuideDocument(
            id: "getting-started-guide",
            title: "新手起步：三步配好 API 模型开始聊天",
            keywords: ["新手", "入门", "怎么用", "不会用", "配API", "配置模型", "API Key", "接口地址", "Base URL", "不能聊天", "发不出消息", "中转", "协议", "怎么配API", "quick start", "setup"],
            content: """
            1. 填地址和 Key。打开「设置 → 模型管理 → 添加提供商」，起一个自己认得的名字。协议照提供商的说明选；如果说明写着「兼容 OpenAI 聊天接口」，就选 OpenAI 兼容。把提供商给你的基础地址（Base URL）填到 API 地址栏，例如 https://api.example.com/v1。兼容接口通常填到 /v1 就够了，软件会再加上具体接口路径。把 /chat/completions 或 /messages 也粘进来，路径就可能重复，发送时会报 404。把自己的 API Key 填在密钥栏，然后保存。

            2. 加一个能聊天的模型。点开刚保存的提供商，进入模型列表，点「从云端获取」（手表上叫「在线获取模型列表」）。如果列表里没有你要的模型，点「添加模型」，照提供商给出的模型 ID 填写，连字符和大小写也要一致。找到要用的聊天模型，勾选启用；如果页面有「保存」，点一下再离开。

            3. 选中它，发第一条消息。回到主聊天，点顶部的模型选择器，选中刚启用的模型。手表上也可以从「设置 → 当前模型」选择。回到输入框发一句「你好」。如果找不到模型，先回到第 2 步确认它已启用。

            Quick Start: In Settings → Model Management, add a provider, choose the API format in its instructions, enter its base URL and API key, then save. Leave off /chat/completions or /messages. Fetch the model list or add the exact model ID yourself, enable a chat model, then select it in chat and send a message. On Apple Watch you can also use Settings → Current Model.
            """
        ),
        GuideDocument(
            id: "app-features-tour",
            title: "软件功能全览：这软件都能玩什么、在哪里找",
            keywords: ["功能", "有什么功能", "能干嘛", "好玩", "介绍", "目录", "导航", "在哪里", "设置在哪", "说明书", "全览", "这软件有什么功能", "features", "app tour"],
            content: """
            1. 想连上自己的模型？「设置 → 模型管理」可以接入 API。手里有同一提供商的多个 Key，可以在提供商里开启多 Key 轮换。要在设备上跑 GGUF 模型，到「设置 → 拓展功能 → 本地模型」导入权重并启用。回复断在半句时，远端模型支持续写的话，打开这条回复的更多菜单，点「预填充续写」。想让软件在网络波动时自动重试，到「设置 → 输出」调整。

            2. 想和角色聊天？「设置 → 角色扮演与酒馆兼容」可以导入 PNG、JSON 或 CHARX 酒馆角色卡，也能在「用户身份」（Persona）里设定你在故事里是谁。地点、人物关系之类的背景可以放进「世界书」（Lorebook），绑定到要用的会话。有些卡片还自带 HTML 状态栏或互动小剧场，会显示在聊天气泡里。手表上的角色和世界书入口都在「设置 → 拓展功能」。

            3. 想换个聊天界面？打开「设置 → 背景与视觉」，手表上叫「显示与外观」。可以把图片或视频设为壁纸，调整模糊和透明度，或试试液态玻璃、关闭助手气泡的排版。自定义字体可以从文件导入，文字和气泡也能换配色。要换自己或 AI 的头像，单独到「设置 → 提示词 → 聊天头像」。

            4. 想让回答更合心意，聊久了也接得上？在「设置 → 提示词」写全局系统提示词，例如让回答短一些。提示词里的 {{user}}、{{char}}、{{cur_time}} 会在发送时换成你的名字、角色名和当前时间。当前对话太长，到「设置 → 会话」查看上下文窗口和压缩续聊。想让下一段新对话也记得你的偏好，再去「记忆系统」看长期记忆（手表从「拓展功能」进入）。

            5. 想让模型用工具，或换设备接着聊？「设置 → 工具中心」能管理聊天可使用的 MCP 工具、系统快捷指令和 Agent Skills。受控浏览器有自己的「Browser Agent」入口，手表上也在「拓展功能」里。「设置 → 同步与备份」可以开启 iCloud 同步；如果想留一份能恢复的备份文件，创建快照时选加密，并记好密码。

            Connect an API in Model Management or import a local GGUF model under Extensions. Roleplay and Worldbook hold your characters and story background. Display settings control wallpaper, fonts and bubbles. Chat avatars are under Prompts. For long chats, open Sessions to set up compression or Memory to keep preferences across chats. Tool Center manages tools, Browser Agent handles web tasks, and Sync & Backup offers iCloud sync and encrypted snapshots.
            """
        ),
        GuideDocument(
            id: "roleplay-beginner-guide",
            title: "酒馆角色卡、世界书与小剧场新手指南",
            keywords: ["酒馆", "SillyTavern", "角色卡", "导卡", "怎么导卡", "PNG", "CHARX", "人设", "用户身份", "开场白", "世界书绑定", "小剧场", "状态栏", "预设", "character card", "roleplay"],
            content: """
            1. 导入角色，再设定你是谁。打开「设置 → 角色扮演与酒馆兼容 → 导入角色卡」，选择带角色资料的 PNG、JSON 或 CHARX 文件。手表从「设置 → 拓展功能 → 角色扮演与酒馆兼容」进入，可用角色卡的下载链接导入。到「用户身份」新增自己的名字和头像。绑定后，卡片里的 {{user}} 会换成你选的身份名，{{char}} 会换成角色名。

            2. 给这段聊天选角色。先打开想玩的会话，再到角色扮演页的「当前会话」选角色和用户身份；Mac 从聊天工具栏打开「会话角色绑定」。卡片有多个开场白时，可以挑一句用在新对话里。单独下载的世界书要先在「设置 → 世界书」导入（手表在「拓展功能 → 世界书」），再把它绑定到这段会话。这样聊到相关话题时，角色才用得上里面的背景设定。

            3. 打开卡片自带的小剧场。在会话绑定里打开「自动渲染 HTML」。如果卡片带有需要运行的互动脚本，而且你信任它，再打开「启用助手脚本」。同时检查「背景与视觉」（手表是「显示与外观」）里的 Markdown 渲染。卡片带的状态栏或互动按钮就能跟着回复显示。想保存时，长按带卡片的消息，进「更多 → 内联内容」选择那张卡片，可以导出 PNG、保存 HTML 或查看源码。Mac 可从网页卡片的操作菜单进入。

            4. 想让不同角色都遵循同一个习惯？去「设置 → 提示词」选用全局系统提示词。例如写「用简短的对话推进故事」，角色卡继续提供各自的人设和开场白。

            To start roleplaying, import a PNG, JSON or CHARX character card under Roleplay & Tavern Compatibility, then create your persona. Bind the character, persona and greeting to the chat you want. Import a separate lorebook in Worldbook and bind it to that chat. For cards with interactive scenes, enable Markdown and HTML rendering, and enable helper scripts only for cards you trust. The inline content menu can export an image or HTML. Global instructions are in Settings → Prompts.
            """
        ),
        GuideDocument(
            id: "troubleshooting-faq",
            title: "常见报错与“为什么发不出消息”排查手册",
            keywords: ["报错", "错误", "失败", "用不了", "没反应", "401", "402", "403", "404", "429", "500", "502", "503", "超时", "证书", "连不上", "504", "troubleshooting", "timeout"],
            content: """
            没有可选模型，或者消息发不出去？按顺序看四处：①「设置 → 模型管理」里有没有你的提供商；② 提供商的密钥栏是否已经填好 API Key 并保存；③ 该提供商的模型列表里有没有聊天模型，而且已经勾选启用；④ 回到主聊天，顶部的模型选择器里是否选中了它。手表也可以去「设置 → 当前模型」检查。如果屏幕上有数字报错，直接看对应的一条：

            401：服务商没认出这把 Key。回提供商后台确认密钥还有效，把有效的 Key 完整复制到 App 的密钥栏，保存后再试。
            402 或提示余额不足：去服务商后台查看余额和可用额度。确认用完后可以充值，或换一把有额度的 Key。
            403：服务商收到了请求，但不允许这次访问。先看这个账号能否使用所选模型，再核对服务商允许的网络地区。如果开了代理，到「全局代理设置」及提供商的独立代理设置检查连接。
            404：先核对地址，再核对模型名。基础地址按服务商说明填，例如 https://api.example.com/v1。如果末尾多粘了 /chat/completions 或 /messages，把多出的部分去掉并保存。如果地址正确，检查模型 ID，尤其是大小写和连字符。
            429：请求太密或碰到了服务商的用量限制。先停一会儿再发；如果你有同一提供商的多把可用 Key，可以在提供商设置里开启多 Key 轮换。如果限额属于整个账号，还需要等额度恢复。
            500、502、503、504：常见原因是上游服务繁忙、临时中断或等待超时。稍等再试，也可以看看服务商的状态说明。只有“超时”或“连不上”时，先检查设备能否联网；使用自建服务的，还要确认设备能访问那台服务器。
            HTTP 或 SSL 证书提示：如果是自己的局域网服务，先核对服务器地址和证书信息，确认是你信任的设备后再按提示允许。在「设置 → 拓展功能 → 连接例外」可以查看或移除已有规则，Mac 也可以从「设置 → 安全 → 连接例外」进入。遇到陌生服务器或意外变更的证书，请先向服务提供方核实。

            都检查过，问题仍能重复出现？到「设置 → 拓展功能 → 反馈助手 → 新建反馈」，写下刚才点了哪里、看到了什么提示和报错编号。描述里请勿附上 API Key、密码或私人地址。

            First check the provider, API key, enabled chat model and current selection. A 401 usually points to the key, a 402 to billing, and a 403 to model permissions or network restrictions. For 404 check the base URL and model ID. For 429 wait before retrying. For 500/502/503/504 check the provider's status. Verify your own server before accepting a certificate exception. If the app still fails, use Feedback and include the error code without credentials.
            """
        )
    ]
}

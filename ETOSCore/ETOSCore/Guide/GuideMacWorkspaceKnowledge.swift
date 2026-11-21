import Foundation

public enum GuideMacWorkspaceKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "macos-workspace",
            title: chinese ? "Mac 桌面端使用与设置指南" : "Mac Desktop Workspace and Settings Guide",
            keywords: ["macOS", "Mac", "桌面", "stdio", "数据库", "草稿", "快捷键", "文件夹", "标签", "GGUF", "下载", "LoRA", "内置工具", "自动批准", "倒计时", "Skills", "技能", "快捷指令", "清单", "描述生成", "浏览器", "接管", "登录", "draft", "database", "folder", "tag", "approval", "countdown", "Shortcuts", "manifest", "browser", "WebKit"],
            content: chinese ? """
            一、主窗口布局、会话管理与日常聊天
            • 双栏主界面：Mac 主窗口分为左侧“会话侧栏”和右侧“聊天区”两栏。侧栏顶部提供新建会话（⌘N）、搜索与按文件夹/标签/系统颜色筛选菜单，点“会话管理”可打开独立的分类整理页（支持新建多级文件夹与标签、右键会话移动分类或打多个标签；删除文件夹会把里面的对话移回未分类，删除标签不会删聊天内容；系统自带颜色不可改名或删除）；“设置”入口固定在侧栏最下方。
            • 聊天区与发送：顶部工具栏显示当前模型、导出按钮与会话菜单（内含会话专属设置、酒馆角色绑定、世界书、会话统计与创建分支；若当前对话绑定了专属首选模型，顶部会直接显示该模型名称）。消息与输入框保持舒适的居中阅读宽度，按 ⌘Return 发送消息。模型回复期间你可以自由切换到别的会话继续浏览或提问。
            • 导入文件与拖放：点击回形针、从 Finder 打开或直接把文件拖进聊天窗口都能添加文件。如果拖入的是本地大模型 GGUF 权重文件，会自动导入模型库（同一批拖入的首个 mmproj 视觉投影文件会自动关联给第一个模型，不会当成普通聊天附件）；普通文件放入输入框后仍需你手动点击发送。
            • 消息右键与改写、分支、导出：
              - 右键任意消息可复制、编辑（支持修改正文、AI 思考过程与工具调用 JSON 草稿，点保存后仅更新聊天记录、不会重新执行工具；点“提取正文图片”可下载在线图片存为本地展示附件）、删除（多版本回复可选择只删当前版本或删掉所有版本）、重新生成，或在模型支持预填充时接着助手回复往后续写。
              - 右键助手回复点“重写回复”，可输入修改要求并勾选旧版本作参考（不会把整段长历史重复发给模型）；开启“选区重写”后，直接在原文预览里框选一小段话，就能只让模型改写选中的那几句并保留新旧版本切换。
              - 工具栏或右键某条消息均可“建立分支”（可选带全部历史提示词或只复制提示词设置），方便从半途尝试不同聊法。
              - 会话导出：工具栏可导出整段对话，右键某条消息可导出截至该处的对话，也支持勾选指定消息导出为 PDF、Markdown、TXT 或 PNG 长图（PNG 不包含系统提示词）。
            • 临时对话与会话专属设置：工具栏“临时对话”菜单可直接选“允许使用记忆”或“隔离记忆”（对话开始前开启；未点击“保存为会话”前不会写入本地历史，关掉应用即消失）。“会话设置”可为当前对话单独配置系统提示词、主题提示、增强提示词、上下文隔离开关和专属首选模型（修改均为草稿，点保存才生效，不会改动全局提示词）。

            二、设置窗口与“立即生效 vs 手动保存草稿”总原则
            • 设置窗口采用左侧边栏导航，分类顺序与手机端保持一致：核心设置（模型管理、会话、提示词、输出、背景与视觉、同步与备份）、拓展能力（工具、每日脉冲、用量统计、记忆、MCP、Skills、快捷指令、角色扮演、世界书、语音、浏览器），以及通用（语言与网络代理）、安全、页面向导和关于（检查更新、公告与日志）。
            • 什么时候立即生效、什么时候要手动点保存：
              - 常规开关与偏好（如流式输出、温度/Top P、显示设置、快捷栏顺序等）修改或经向导原生确认后立即保存生效。
              - 复杂配置窗口（如服务商与模型、会话设置、MCP 服务器、配色方案、字体规则、角色卡、自定义指令等）采用安全的**草稿模式**：向导确认建议也只会填入当前窗口草稿，必须由你亲自点击页面上的“保存”才算正式生效；嵌套子窗口（比如在模型里改价格或自定义 Body）点“完成”只会回到上一级服务商草稿，最后还需点服务商的“保存”。切换页面、关闭窗口或锁屏后，未确认的向导提案会自动作废；如果同一份配置已在其他窗口或同步中被更新，旧草稿会提醒你重新加载，避免误覆盖新内容。
              - 隐私底线：所有已保存的 API Key、密码、令牌、自定义请求头及聊天消息正文对页面向导均不可读；系统文件面板、相册选择器与权限弹窗归系统管理，向导无法替你点击。

            三、模型管理、价格、自定义 Body 与本地模型
            • 模型测试与价格估算：在远端服务商编辑页点“模型测试”，可一键验证当前草稿中已启用的聊天（依次测非流式、流式与工具声明，不会真执行工具）、嵌入与生图模型是否连通，测试不会污染聊天记录。模型编辑页支持设置接口协议覆盖，以及按 Token、按次、阶梯和分星期/时段的峰谷价格（子页点完成只更新模型草稿，记得最后保存服务商）。
            • 自定义 Body 与聊天控制：在模型配置的“自定义 Body”中可编辑基础参数与结构化控制（开关、多档选项、滑块），并提供只读的“聊天请求体示例”；聊天输入框旁的“聊天控制”按钮则用来实时切换当前对话的档位与滑块（详见 model-request-body）。
            • 本地模型：在“模型管理 → 本地模型”中可导入 GGUF 权重，关联 mmproj、LoRA、语音解码器与 VAD，调整运行参数、CLI 参数预览和采样器链；也可在“下载权重”页填入 HTTP/HTTPS 直链手动下载。详情页各项参数均为草稿，点保存生效；使用本地模型聊天时，前台可实时查看 CPU、内存与 Metal 显存占用（向导不能替你下载、导入、删除或运行模型）。

            四、视觉外观、高级渲染、动画、功能栏与字体
            • 显示设置与高级渲染：“背景与视觉 → 显示设置”控制 Markdown 排版、工具结果增强、长消息折叠字数上限和思考过程预览（修改立即保存）。折叠长消息只影响屏幕高度，复制、编辑、发给模型与导出始终保留完整原文；正在生成时的思考预览以纯文本展示，正文出来后自动收起，生成结束后可点开看完整排版。
              - 开启 Markdown 后可打开“高级渲染”，在独立安全视图中展示数学公式与 Mermaid 流程图（按需从 jsDelivr 联网加载固定版本前端资源，断网或加载超时会自动做原文回退并支持手动重试；模型输出的原始 HTML 只当普通文本展示，不会执行脚本）。
              - 流式显示的“即时 / 柔和”只调节屏幕上新字浮现的平滑度，不会改变发送请求时的流式开关。
            • 消息翻页导航与聊天动画：开启四键导航后，聊天底部会出现首条、上一页、下一页、最新消息按钮；点击消息滚动区获得焦点后，可直接用键盘 Home/End/Page Up/Page Down 翻页（不会抢占输入框按键），上翻看历史时新回复不会把你强行拉回底部。聊天动画页可调节弹性滚动波浪与新消息飞入参数（立即保存），开启系统“减少动态效果”时会自动关闭波浪与位移动画；向导不能替你滚动页面或发送消息。
            • 消息功能栏：分别定制 AI 回复与用户消息下方显示的按钮（复制、朗读、快速重试、版本切换、请求时间、输入/输出 Token、费用等）、排列顺序、靠左/靠右对齐、外框与 50%–200% 字号比例，调整后需点击手动保存才生效。其中费用优先显示回复生成时记录的费用快照，没有快照时再按模型当前价格估算；隐藏功能栏按钮不影响右键菜单里的操作。
            • 沉浸背景、气泡玻璃与定时配色：
              - 沉浸背景支持从文件或系统相册导入图片（PNG/JPEG/WebP）与静音循环视频（MP4/MOV/M4V），“图片裁切”支持桌面 16:10、手机 9:16、手表与正方形比例及缩放位置草稿（向导可协助改裁切参数草稿，仍需手动点“保存为新背景”）。
              - 聊天气泡开关与液态玻璃效果立即保存。在“颜色配置”子页可创建多套气泡与深浅色文字规则，并设置每日自动切换时间段：所有配色和时间段编辑都是草稿，需在配置窗口点保存才生效；向导经原生确认只能帮你调当前草稿，不能保存、新增、排序、删除配色或操作系统的取色面板。
            • 字体库与排版规则：在“字体设置”中可开启自定义字体、调节 50%–200% 全局字号比例与正文行距（立即保存），并从本地导入 TTF/OTF/TTC/WOFF/WOFF2 字体文件，为正文、斜体、粗体、代码分别排定回退优先级或添加按文字/正则匹配的专属字体规则。优先级与规则编辑均为草稿——规则窗口的完成只返回父草稿，必须在父窗口点保存才正式生效；向导不能导入或删除字体文件，也不能增删规则或代点保存。
            • 快捷栏与快速指令：输入框下方的快捷功能按钮详见 chat-quick-actions；输入 `/` 触发的 19 项快速指令与自定义提示词详见 slash-commands。

            五、每日脉冲、用量统计、上下文压缩、记忆与酒馆角色
            • 每日脉冲：从设置侧栏或聊天快捷功能打开，按“今日卡片、任务、反馈历史、外部信号、设置”分标签管理，只展示当天的卡片（提前准备好的明日卡片不会剧透）。点开卡片可点喜欢、减少此类推荐、隐藏、加入待办任务、归档为正式会话或点击“继续聊”——继续聊只填入草稿，不自动发送。脉冲开关、专用模型与侧重点等设置修改立即保存，而送达时间编辑器修改的是草稿，需手动点保存；向导在卡片与其他管理标签均为只读，不能生成、归档、继续聊、反馈、删除记录或运行外部工具。
            • 用量统计与会话分析：设置侧栏的“用量统计”通过热力图、月历以及日/周/月/全部范围展示请求次数、Token 趋势（思考与缓存 Token 不会重复累加进总量）、模型占比与来源排行；费用按请求发生记录与当前价格估算（未记录的早期聊天不会按条数倒推），页面向导为只读，不能刷数据或删记录。此外，在聊天顶部菜单或右键任意会话点“分析统计”，还能在不切走当前对话的情况下单独查看某个会话的统计。
            • 上下文压缩、记忆与世界书：长对话“压缩为续聊”与长度提醒详见 context-compression。记忆页可搜索管理记忆条目、切换嵌入模型、重试失败嵌入、导出可读 Markdown 或 `.etosmemory` 归档包，以及配置“跨对话记忆与画像”（编辑器改草稿，删除或清空需手动确认）。世界书支持新建、导入 JSON/PNG/链接、导出、拖动调注入优先级及绑定到指定会话（绑定页需手动保存）。
            • 角色扮演与酒馆兼容：支持新建或导入 JSON/PNG/CHARX 角色卡、管理多段开场白、内嵌世界书与玩家用户身份；在聊天顶部可为当前会话绑定角色卡并开关 HTML 卡片渲染与助手脚本（还提供七种作用域的宏与变量编辑器，以及角色专属查找替换正则和脚本列表）。除列表拖拽排序与确认删除立即生效外，其余资料、变量、正则和脚本编辑均为草稿，需手动点保存，编辑过程中绝不会自动运行脚本代码。

            六、工具中心、Mac 本机 Shell、MCP 与会话浏览器
            • 工具中心：集中管理内置工具开关（区分全局开启与当前会话是否可用）、工具审批自动化（可设 1–30 秒倒计时自动放行普通工具，高风险强制确认工具仍需本人点击；聊天中的工具审批弹窗对向导只读，向导不能批准调用）、输入区工具问答卡片、系统快捷指令（支持剪贴板/清单导入与 AI 生成描述预览，需在 Mac 系统“快捷指令”App 中装好同名指令）以及 Skills 技能包（支持粘贴 SKILL.md 或从本地文件/ZIP/GitHub 导入，开关与脚本策略确认后直接保存，编辑正文仍为草稿）与 Agent 操作提示词。
            • Mac 本机 Shell 与终端（与移动端的重要区别）：
              - macOS 的本机 Shell 直接使用系统 UNIX/POSIX 进程、你的 Mac 本地路径及电脑上已安装的命令行程序，不安装 iSH、Linux 或 RootFS，也没有 Linux 安装、重置、挂载或环境准备页面；Python、Node、Git 等依赖程序由用户在 Mac 上安装即可。
              - 命令规则与环境变量：进程以当前登录用户的权限运行；命令安全规则只是执行前的审批提醒策略，不是沙盒隔离——匹配优先级固定为：拒绝优先于确认，确认优先于警告，列表顺序只决定同类命中的先后。环境变量仅在新建进程时注入，编辑器里变量的值只写不可读。终端快捷栏可自定义常用按键组合（单按修饰键无法保存，且配置不会向终端发送按键）。
              - 终端与任务诊断：支持在聊天窗口旁开启“Agent 工具”或“用户终端”实时输出小窗预览，也可打开独立终端自由输入（打开空页面不会自动创建进程，离开页面保留已开终端，解锁或恢复不重放命令）。在“任务与终端”页可按会话查看运行记录、点击“停止此 Agent”终止整条任务链、按 64 KB 分页翻看原始输出；诊断记录支持手动复制排查，不会自动上报，且向导看不到命令参数、环境变量、终端输出或诊断正文。
            • 文件路径与本地 MCP 服务：
              - 在内置结构化文件工具中，相对路径和 app:// 指向 App Documents 目录；访问其他 Mac 路径使用本机 Shell 命令即可，linux:// 和 mount:// 不适用于 Mac。
              - Mac 上的本地 MCP stdio 服务同样直接调用系统进程的标准输入输出通信（command 填可执行程序，args 填参数列表，不自动做 shell 通配展开；移动端默认的 `/home/etos` 工作目录在 Mac 运行时会自动对应到你的个人主目录）。MCP 详情页还可手动查看测试资源、资源模板与提示词。
            • 本机会话浏览器：从输入框快捷栏或工具中心打开，标签页按会话相互隔离。当 AI 正在浏览网页时，你可以随时点击“接管”亲自操作（如完成登录验证），交还控制权后不会擅自发新消息；开启“保留登录状态”后，新标签会复用本应用在 Mac 上独立的网站登录数据（与系统 Safari 互不干扰）。向导看不到网址、网页正文或 Cookie，也不能操控网页。

            七、语音朗读（TTS）与语音输入
            • 语音输出（TTS）：支持系统自带音色与 12 种云端协议。朗读模式、回复后自动朗读、系统语速/音调/音色、云端倍速等参数修改后需点保存生效；后台继续播放、音频缓存、正文过滤与切换当前服务则立即保存。自动朗读只针对当前会话刚刚生成完毕的新回复，不因打开历史、取消或失败而播放。服务编辑页可拿未保存草稿试听，也可将已缓存的云端语音导出为音频文件；已有密钥在向导中只写不可读，向导不能试听、播放、导出、保存或删除服务。
            • 语音输入：在设置中选好模式（转文字或直接发原始音频）、格式（AAC/WAV）与转写模型后，点聊天框旁的麦克风打开录音窗口——只有点击“开始”才会申请麦克风权限并开始录音（若系统权限弹窗出现较晚，迟到授权不会重新录音；取消识别也不会自动换其他语言重试）。录完可试听重录：选文字模式时需你点击“转写”（转写前核对模型配置，若中途改过设置重开录音窗即可），结果可修改后再插入输入框；选原始音频模式时会将录音挂为待发附件（未发出的录音只留在内存中），两种模式的最终发送仍手动进行。录音窗口对向导不包含录音、路径或识别正文，向导也不能替你录音、转写、播放、插入、发送或授予权限。

            八、网络代理、连接例外与数据存储管理
            • 网络代理：“设置 → 通用 → 全局代理”与各远端服务商里的“独立代理”均支持 HTTP/HTTPS 与 SOCKS5。两处修改的都是草稿：全局代理在本页点保存，服务商的独立代理返回提供商编辑器统一保存。未开启独立代理的服务商默认继承全局代理；开启独立配置但关掉代理开关时，会绕过 App 全局代理，但仍可能受系统代理影响。保存后不会打断正在进行的请求，之后的聊天请求即走新代理（不自动注入给本地 MCP 子进程或本机 Shell）。代理的用户名与密码只写不可读（若别处改过密码，密码变化也会拒绝旧草稿覆盖），向导不能保存、重载或测试连接。
            • 连接例外：在“设置 → 安全 → 连接例外”或拓展功能中，管理当前设备已记住的明文 HTTP 与自定义证书连接例外。信任开关与移除地址必须由你本人点击，且只影响 App 自身的网络请求——本地 MCP 启动的原生 stdio 子进程、本机 Shell 以及 Safari 浏览器不受此页控制（详见 network-connection-exceptions）。
            • 备份同步、导入、远程访问与存储工作区：
              - 数据管理支持导出/恢复与移动端通用的 `.elsbackup` 备份包、配置 S3/R2 云端备份以及开启 iCloud 同步（首次全量覆盖需手动输入确认词）；七来源数据导入详见 data-import，局域网远程文件访问详见 remote-file-access。
              - 存储管理（详见 storage-management）可查看 10 类空间占用、浏览文件并清理缓存或孤立数据，向导只能看统计或协助草拟 SQL，不能读取正文、运行查询或清理。存储管理内的“工作区管理”支持将当前可读文件打包导出为 ZIP（若后台仍有程序正在写文件，不保证运行中写入文件的一致性快照）；确认删除工作区时，系统会先取消并等待相关任务及输出落盘后删除目录和记录，不删除其他会话和外部文件，工作区页面及详情向导只读，不能导出或删除。
              - Mac 端应用数据统一存放在系统 `Application Support/ETOS LLM Studio` 目录下，备份与同步格式和 iOS、watchOS 完全通用。
            """ : """
            1. Main Window, Conversation Organization and Everyday Chat
            • Two-column workspace: the Mac window pairs a Conversation Sidebar on the left with your active chat on the right. Above the list sit New Chat (Command-N), Search and a filter menu for folders, tags and system colors, plus a dedicated Classification Management window (create nested folders and tags, or right-click chats to move them and toggle multiple tags; deleting a folder moves its chats back to Uncategorized, deleting a tag keeps all messages, and built-in system colors cannot be renamed or deleted). Settings stays anchored at the bottom of the sidebar.
            • Chat header and sending: the top bar displays your active model, Export and a Conversation menu (Session Settings, Roleplay Binding, Worldbooks, Conversation Analytics and Branching; when a chat uses its own preferred model, the header shows that effective model name directly). Messages and the composer share a comfortable centered width—press Command-Return to send, and feel free to switch chats while a reply is still generating.
            • Files and drag-and-drop: attach files via the picker, Finder Open With or by dragging them straight into the chat. Dropping local `.gguf` model weights imports them into your Local Models library (attaching the first `.mmproj` in the batch to the first weight rather than treating it as a chat attachment); regular files land in the composer and wait for you to click Send.
            • Right-click message actions, rewrites, branches and exports:
              - Right-click any message to Copy, Edit (adjust message text, assistant reasoning or tool-call JSON as a draft—saving updates history without re-running tools, and Extract Inline Images saves linked images locally for display), Delete (remove just the active reply version or all versions), Regenerate or Continue assistant text via prefill on supported models.
              - Choose Rewrite Reply on an assistant message to give rewrite instructions with optional reference to earlier versions (without resending the entire conversation history), or turn on Selection Rewrite and highlight a specific passage to rewrite just those lines while keeping both versions.
              - Branch from the toolbar or from any specific message—copying either full history + prompts or prompts alone.
              - Export a whole chat from the toolbar, up to a specific message from its menu, or hand-picked messages as PDF, Markdown, TXT or PNG (PNG omits system prompts).
            • Temporary Chat and Session Settings: the Temporary Chat toolbar menu lets you choose Allow Memory or Isolate Memory cleanly (start it before sending messages; nothing is saved to disk unless you click Save as Conversation). Session Settings lets you customize per-chat system, topic and enhancement prompts, context isolation switches and a preferred model—kept as a draft until you click Save, without altering global prompts.

            2. Settings Navigation and “Saves Immediately vs. Manual Drafts”
            • Sidebar layout: Settings mirrors mobile categories in a familiar sidebar—Core sections (Models, Conversation, Prompts, Output, Background & Appearance, Sync & Backup), Extensions (Tools, Daily Pulse, Usage Analytics, Memory, MCP, Skills, Shortcuts, Roleplay, Worldbooks, Speech, Browser), plus General (Language & Proxy), Security, Page Guide and About (updates, announcements and logs).
            • Immediate switches vs. draft editors:
              - Everyday toggles and display preferences (streaming, temperature/Top P, Markdown rendering, quick action order) save right away upon toggling or confirming a guide prompt.
              - Multi-field editors (Providers & Models, Session Settings, MCP servers, Color Profiles, Font Rules, Roleplay cards, custom commands) work as **drafts**: confirming a guide proposal updates only the open draft, and you must click Save yourself to apply it. Nested child sheets (like Model Pricing or Custom Body) return to their parent draft when you click Done, so remember to click Save on the provider afterward. Leaving a page, switching windows or locking expires unconfirmed guide proposals, and stale drafts warn you instead of silently overwriting newer changes made elsewhere.
              - Privacy baseline: existing API keys, passwords, tokens, custom headers and conversation messages are never readable by the guide, and OS file/photo pickers and permission dialogs are never operable by the guide.

            3. Models, Pricing, Custom Body and Local Models
            • Model Test and Pricing: inside a remote provider editor, Model Test checks enabled chat (non-streaming, streaming and tool declaration without executing tools), embedding and image models from your current draft without cluttering chat history. Model editors also support API format overrides plus token, per-request, tiered and scheduled weekday/time pricing (clicking Done updates the model draft; save the provider to finish).
            • Custom Body and Chat Controls: configure base request fields, reusable switches, option groups and sliders under Model Configuration → Custom Body, inspect the read-only Sample Chat Request Body, or adjust live per-chat controls from Chat Controls beside the composer (see model-request-body).
            • Local Models: import `.gguf` weights, link `.mmproj`, LoRA adapters, speech decoders and VAD, preview CLI arguments, customize sampler chains or download weights manually from a direct HTTP/HTTPS URL. Detail edits stay in a draft until Save; active local-model chats can display live CPU, memory and Metal usage in the foreground, and the guide cannot download, import, delete or run models.

            4. Appearance, Advanced Rendering, Motion, Action Bar and Fonts
            • Display Settings and Advanced Rendering: under General / Background & Appearance, Display Settings manages Markdown formatting, enhanced tool results, long-message folding limits and live reasoning previews (all saved immediately after native confirmation). Folding long user messages only shortens the on-screen row—copying, editing, model input and exports always keep the full original text. Live reasoning previews stay plain text while streaming and collapse once the reply body arrives.
              - With Markdown enabled, turning on Advanced Rendering renders math formulas and Mermaid diagrams inside an isolated view using pinned frontend libraries loaded on demand from jsDelivr (falling back cleanly to source text with a retry button if offline or timed out; raw model HTML stays plain text and never runs scripts).
              - Immediate vs. Gentle streaming adjusts only on-screen text pacing and fade-in—it never changes request streaming sent to the API.
            • Four-button navigation and Chat Animations: optional bottom buttons jump to the first message, previous page, next page or latest message, and Home/End/Page Up/Page Down work whenever the message scroll area has focus without hijacking composer keys; reading older messages pauses auto-scroll so new replies never yank your view away. Chat Animations tunes elastic scroll waves and message send-in motion (saved immediately), while macOS Reduce Motion automatically disables waves and animated jumps. The guide can propose display or animation settings, but cannot scroll or send messages.
            • Message Action Bar: customize separate ordered items, left/right alignment, border and 50%–200% font scale for assistant and user messages; edits stay in a draft and require manual Save. For message cost, the action bar prefers the saved cost snapshot recorded when the reply was generated, estimating from current model pricing only when no snapshot exists. Hiding action bar buttons leaves right-click menu actions intact.
            • Backgrounds, Glass and Color Profiles:
              - Import PNG/JPEG/WebP images or silent looping MP4/MOV/M4V videos from files or Photos, and adjust aspect ratios (original, desktop 16:10, phone 9:16, watch 0.82, square) and zoom/pan in the crop editor (guide proposals edit crop drafts only; click Save as New Background manually).
              - Bubble visibility and Liquid Glass switches save immediately. Inside Color Profiles, you can create custom light/dark bubble and text-rule themes with daily schedules: color and schedule edits remain drafts until you click Save in the profile window, and while guide proposals can adjust the active draft after confirmation, they cannot save, add, reorder, delete profiles or operate the macOS color panel.
            • Fonts and text rules: Font Settings toggles custom fonts, 50%–200% font scaling and line spacing (saved immediately), and imports TTF/OTF/TTC/WOFF/WOFF2 files into fallback chains for body, italic, bold and code or targeted text/regex rules. Priority chains and text rules edit drafts—Done returns a rule to the parent draft, and clicking Save in the parent window persists it. The guide cannot import or delete font files, add/remove rules or save drafts for you.
            • Quick Actions and Quick Commands: see chat-quick-actions for composer toolbar shortcuts and slash-commands for `/` commands.

            5. Daily Pulse, Usage Analytics, Compression, Memory and Roleplay
            • Daily Pulse: open from Settings or Quick Actions with dedicated tabs for Today's Cards, Tasks, Feedback History, External Signals and Settings (only today's cards are shown; pre-generated tomorrow cards stay tucked away until tomorrow). From any card you can like, downrank, hide, add to Tasks, archive as a chat or click Continue Chat—which fills a draft without sending automatically. Main Pulse preferences save right away, while the delivery time editor edits a draft that requires manual Save; card and history tabs are read-only to the guide.
            • Usage Analytics and Conversation Analytics: Mac usage analytics visualizes requests, token trends (without double-counting thinking or cached tokens), top models and sources across a heatmap, monthly calendar and day/week/month/all-time scopes. Cost totals are estimated from recorded usage and current pricing, and all analytics guide contexts are strictly read-only. You can also inspect any single chat's recorded stats via Conversation Analytics in the chat header or sidebar right-click menu without switching your active conversation.
            • Compression, Memory and Worldbooks: see context-compression for continuation summaries and token reminders. Memory lets you search active/archived memories, pick an embedding model, retry failed embeddings, import/export Markdown or `.etosmemory` archives, and configure Cross-Session Memory & Profile. Worldbooks supports creating, importing (JSON/PNG/URL), exporting, drag-reordering injection priority and binding books to specific chats (bindings require manual Save).
            • Roleplay and Tavern compatibility: create or import JSON/PNG/CHARX character cards, manage greetings, embedded worldbooks and user personas, bind characters to a chat with optional HTML card rendering and helper scripts, and edit seven macro/variable scopes plus character regex rules and scripts. Apart from list reordering and confirmed deletions, profile, variable, regex and script editors all edit drafts until you click Save—and editing a script never executes its code.

            6. Tool Center, Native Mac Local Shell, MCP and Session Browser
            • Tool Center: manage Built-in Tools, Approval Automation (1–30s countdown for standard tools while high-impact confirmations always stay manual; live approval prompts are read-only to the guide), composer questionnaires, Apple Shortcuts (import from clipboard/manifests with optional AI description previews; matching Shortcuts must be installed in macOS Shortcuts), Skills (`SKILL.md`, folder, ZIP or GitHub imports) and Agent Prompts.
            • Local Shell on macOS (how Mac differs from mobile):
              - Local Shell on macOS runs native UNIX/POSIX processes using your Mac's own paths and installed command-line tools—it does not install iSH, Linux or a RootFS, and has no Linux setup, reset or mount pages. Install tools like Python, Node or Git directly on your Mac.
              - Command rules and environment variables: processes run with your user permissions, so command rules act as an approval policy, not filesystem isolation (deny overrides confirm, which overrides warn, with list order breaking ties). Environment variable values are write-only in the editor and apply to newly started processes. Terminal shortcut bars reject modifier-only keys (Modifier-only combinations cannot be saved) and configuration never sends keys to the terminal.
              - Terminals, jobs and diagnostics: preview Agent Tools or an existing User Terminal right beside the chat, or open the standalone Terminal to run commands interactively—opening an empty page starts no process, leaving keeps terminals alive, and commands are never replayed after unlock or restore. Under Tasks & Terminals you can inspect runs, click Stop This Agent, browse raw output in 64 KB pages and copy diagnostic records manually (never uploaded automatically). The terminal and job guides expose only IDs, counts and status—no input, environment values or output.
            • File tool paths and native MCP servers:
              - Structured file tools accept relative paths and app:// within App Documents; use native Shell commands for other folders on your Mac, as linux:// and mount:// are unavailable on Mac.
              - On macOS, stdio uses a native Process with stdin/stdout (`command` is the executable and `args` are literal arguments without implicit shell expansion; the mobile default `/home/etos` maps cleanly to your Mac home folder at runtime). MCP server details also let you manually inspect resources, templates and prompts.
            • Session Browser: open from Quick Actions or Tool Center with tabs isolated per conversation. Click Take Control anytime to interact with a page yourself (for example to sign in), and optionally enable Keep Login State so new tabs share persistent app-local website data separate from Safari. The guide never reads URLs, page content or Cookies and cannot drive the browser.

            7. Text to Speech (TTS) and Speech Input
            • Text to Speech: supports macOS system voices and all 12 cloud TTS protocols. Mode, autoplay after replies, system rate/pitch/voice and cloud speed stay in a draft until Save, while background playback, caching, text filtering and active service selection save immediately. Reply autoplay triggers only when a live request finishes in the current chat—never when opening history or after a cancelled/failed request. Existing API keys are write-only, and the guide cannot preview, play, export, save or delete TTS services.
            • Speech Input: configure transcription vs. raw-audio mode, AAC/WAV format and your speech model in Settings, then click the chat microphone to open the recording window. Only clicking Start requests microphone permission and begins recording (late permission approval never starts recording on its own, and cancellation does not retry other locales). After stopping, click Transcribe to review and insert text into your draft (reopen the window if you changed speech model settings meanwhile), or attach raw audio—Unsent audio stays in memory until you manually send the message. Recording state never exposes audio, file paths or transcript text to the guide, and the guide cannot record, transcribe, play, insert, send or grant permission.

            8. Network Proxy, Connection Exceptions and Data & Storage
            • Network Proxy: Global Proxy (under General) and per-provider Independent Proxy both support HTTP/HTTPS and SOCKS5 as drafts—click Save on Global Proxy, or save a provider's proxy from its parent provider editor (resuming never saves automatically). Turning off an enabled provider override skips the app's Global Proxy while system proxy settings may still apply. Saving does not interrupt active requests; subsequent chat requests use the new proxy settings (without injecting proxy variables into native MCP child processes or Local Shell). Usernames and passwords are write-only, stale drafts cannot overwrite changed credentials, and The guide cannot save, reload or test connections.
            • Connection Exceptions: under Settings → Security (or Extended Features), review or revoke remembered HTTP and certificate exceptions using native controls; these rules govern the app's own network requests and do not affect native stdio child processes, Local Shell or Safari (see network-connection-exceptions).
            • Backups, Sync, Import, Remote Access and Storage Workspaces:
              - Export or restore mobile-compatible `.elsbackup` snapshots, connect S3/R2 cloud backups, or enable iCloud Sync (initial full replacement requires typing a confirmation phrase); see data-import for seven-source imports and remote-file-access for LAN debugging.
              - Storage Management (see storage-management) breaks down ten space categories, previews local files and cleans cache/orphans; its workspace list can zip readable workspace files or delete a workspace after cancelling active jobs and flushing output, while keeping other chats and external files untouched. All workspace and analytics guides remain read-only, and Mac stores its app data under `Application Support/ETOS LLM Studio` using the exact same backup and sync format as iOS and watchOS.
            """
        )
    }
}

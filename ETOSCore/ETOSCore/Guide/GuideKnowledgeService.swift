// ============================================================================
// GuideKnowledgeService.swift
// ============================================================================
// ETOS LLM Studio
//
// 小而稳定的内置文档索引。全文搜索在 actor 中执行，不进入 SwiftUI 渲染链路。
// ============================================================================

import Foundation

public struct GuideDocument: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let keywords: [String]
    public let content: String

    public init(id: String, title: String, keywords: [String], content: String) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.content = content
    }
}

public actor GuideKnowledgeService {
    public static let shared = GuideKnowledgeService()

    private let documents: [GuideDocument]
    private let documentsByID: [String: GuideDocument]

    public init(documents: [GuideDocument] = GuideDocumentCatalog.documents) {
        self.documents = documents
        self.documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
    }

    public func search(_ query: String, limit: Int = 6) -> [GuideDocumentReference] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        return documents
            .compactMap { document -> (GuideDocument, Int)? in
                let title = document.title.lowercased()
                let keywords = document.keywords.joined(separator: " ").lowercased()
                let body = document.content.lowercased()
                let score = terms.reduce(into: 0) { result, term in
                    if title.contains(term) { result += 8 }
                    if keywords.contains(term) { result += 4 }
                    if body.contains(term) { result += 1 }
                }
                return score > 0 ? (document, score) : nil
            }
            .sorted {
                if $0.1 == $1.1 { return $0.0.id < $1.0.id }
                return $0.1 > $1.1
            }
            .prefix(max(1, limit))
            .map { GuideDocumentReference(id: $0.0.id, title: $0.0.title) }
    }

    public func document(id: String) -> GuideDocument? {
        documentsByID[id]
    }
}

public enum GuideDocumentCatalog {
    public static let documents: [GuideDocument] = [
        GuideDocument(
            id: "guide-overview",
            title: "页面向导与隐私边界",
            keywords: ["向导", "浮球", "隐私", "上下文", "清空", "API Key"],
            content: """
            页面向导只在设置与配置页面工作。iPhone 上开启“在设置中显示页面向导”后会出现可拖动的向导按钮；Apple Watch 从设置列表进入向导页面。向导对话只保存在内存中，退出进程后自动消失，也可以随时一键清空。

            每次发送问题时，当前页面会显式提供页面标识、相关文档、允许读取的配置快照和本页专属工具。已有 API Key、密码与令牌永远不会发给模型，只显示为隐藏状态；模型可以提出写入新值的方案，但任何持久化修改都必须先经过原生确认预览。

            内置免费向导始终可用；用户也可以选择自己已配置且支持工具调用的聊天模型。两条线路不会静默切换，用户模型失败时会明确提供使用内置向导重试的操作。
            """
        ),
        GuideDocument(
            id: "provider-model-basics",
            title: "提供商、API 凭据与聊天模型",
            keywords: ["提供商", "模型", "API", "Key", "激活", "选择", "Base URL"],
            content: """
            可聊天状态需要同时满足：存在提供商；需要凭据的远程提供商已经填写 API Key；提供商下存在聊天模型；模型已经激活；最后有一个可运行聊天模型被选中。向导根据真实状态显示缺少哪一步，不保存“已经看过欢迎页”之类的标记。

            提供商负责 Base URL、API 格式、请求路径、凭据和独立代理；模型负责模型名、显示名、能力、激活状态及请求体覆盖。只有模型明确启用了“工具调用”能力时，才可被选作用户自有向导模型。

            在提供商的“模型配置”页面，向导可以按模型 ID 提交结构化 JSON，新增模型或只更新指定字段。模型 ID 是合并键；省略的字段会保留原值，新增或更新的模型会加入“已添加”列表。删除必须由用户明确提出，并且所有变更都会先显示原生确认预览，确认后才保存。

            测试连接不会替代保存。编辑完成后先执行原生连接测试，再在最终预览中确认提供商与模型配置，最后一次性保存并选中，避免产生半配置状态。
            """
        ),
        GuideDocument(
            id: "model-request-body",
            title: "模型请求体与结构化控制",
            keywords: ["请求体", "JSON", "结构化", "覆盖", "temperature", "参数", "control"],
            content: """
            模型的请求体配置分为键值控制与原始 JSON 两种方式。键值控制适合把常用参数公开成开关、输入框、枚举或滑块；原始 JSON 适合上游需要复杂嵌套结构时整体覆盖。

            模型级覆盖优先于全局 temperature、top_p 等默认参数。切换模式前应确认另一种模式中的草稿是否仍需保留。向导提出结构化修改时会展示字段路径、原值与新值；确认前不会写入模型配置。
            """
        ),
        GuideDocument(
            id: "network-proxy",
            title: "全局代理与提供商独立代理",
            keywords: ["代理", "HTTP", "SOCKS5", "网络", "密码", "端口"],
            content: """
            提供商独立代理优先于全局代理；没有独立配置时才使用全局代理。HTTP 与 SOCKS5 都需要有效主机和 1 到 65535 的端口。代理用户名与密码属于敏感字段，向导只能知道是否已填写，不能读取已有内容。

            修改代理后应使用对应模型的连接测试验证。关闭代理不会删除已填写的主机与凭据，重新开启时可以继续使用。
            """
        ),
        GuideDocument(
            id: "mcp-tools",
            title: "MCP 工具接入与聊天工具开关",
            keywords: ["MCP", "工具", "服务器", "stdio", "HTTP", "审批"],
            content: """
            MCP 服务器配置与“加入聊天工具”是两件事：服务器可以已经保存但尚未连接，也可以已连接但没有加入普通聊天。页面向导可以在工具箱根页面创建 HTTP、SSE 或本地 stdio MCP Server；进入单个服务器后，可以读取其连接类型、非敏感配置、连接状态、能力、工具与资源摘要，并提出修改显示名称、备注、聊天选择和连接配置。它会先生成原生配置预览，只有用户确认后才保存。认证头、OAuth 秘密和环境变量会在预览中脱敏；修改其他字段时，省略的已有秘密会继续保留。

            进入单个 MCP 工具的设置页后，向导可以修改启用状态与审批策略。原生敏感能力的审批策略固定为“每次询问”，不能由向导放宽。服务器的连接、断开、删除以及工具的实际调用不会作为配置提案自动执行。

            页面向导的专属工具与 MCP 完全隔离，不会出现在 MCP 列表或普通聊天的工具定义中。页面还可以显式声明自己的只读或变更工具，由所属页面负责校验和执行；服务端不会用固定工具名单阻止这些自定义能力。

            本地 stdio 需要本地 Linux 运行环境；远程服务器按其传输协议填写地址与认证信息。涉及副作用的工具仍受工具审批策略控制。
            """
        ),
        GuideDocument(
            id: "shortcut-tools",
            title: "快捷指令工具导入与运行设置",
            keywords: ["快捷指令", "Shortcuts", "工具", "导入", "桥接", "直连", "审批"],
            content: """
            快捷指令工具箱把已经导入的系统快捷指令包装为普通聊天可以选择的工具。总开关关闭后，工具及其设置仍会保留，但不会再暴露给聊天模型。官方导入快捷指令名称必须与“快捷指令”App 中的实际名称一致；桥接名称用于无法直接运行或明确选择桥接优先的工具。

            页面向导可以修改工具箱总开关、官方导入名称和桥接名称。进入单个快捷指令工具后，可以修改该工具是否启用、使用直连优先还是桥接优先，以及提供给模型的自定义描述。所有修改都先显示原生确认预览；向导不会替用户运行快捷指令、读取剪贴板或触发导入。

            直连优先会先尝试按快捷指令名称运行，失败后再尝试桥接；桥接优先则反过来。自定义描述为空时，App 会回退到导入时生成的描述。工具审批倒计时属于全局审批设置，当前页面只向向导公开其状态，不允许在解释快捷指令时顺便放宽审批。
            """
        ),
        GuideDocument(
            id: "first-model-setup",
            title: "首次配置模型的状态式引导",
            keywords: ["首次", "初始化", "云端", "自定义", "本地", "导入", "配置"],
            content: """
            没有可运行聊天模型时，聊天页、模型选择器和模型管理页会显示同一套状态式引导。用户可以选择云端模板、自定义 OpenAI 兼容服务、本地模型或导入配置；第一屏只解释选择，不立即请求模型。

            配置草稿仅保存在内存中。API Key 通过原生安全输入框直接交给凭据存储，不进入向导上下文。完成原生连接测试后，最终确认会原子地保存提供商、模型、激活状态和当前选择。
            """
        ),
        GuideDocument(
            id: "settings-core",
            title: "会话、提示词与输出设置",
            keywords: ["会话", "提示词", "输出", "流式", "上下文", "Temperature", "正则"],
            content: """
            核心设置按会话、提示词和输出分组。会话设置控制启动方式、发送延迟、协作执行预算、历史窗口、压缩提醒、视频解析与消息正则替换；提示词设置控制全局系统提示词、当前话题提示词、增强提示词和时间注入；输出设置控制采样参数、流式输出、思考回传、测速与语音朗读。

            页面向导只修改当前页声明的字段。提示词列表、正则规则等有独立二级页面；编辑器中的草稿经向导修改后，仍需按页面提示点击保存。删除规则或提示词等破坏性操作必须由用户在页面发起，或者在完整列表提案中明确确认。
            """
        ),
        GuideDocument(
            id: "settings-display",
            title: "显示、背景与聊天外观",
            keywords: ["显示", "背景", "Markdown", "字体", "颜色", "功能栏", "快捷入口", "动画"],
            content: """
            显示设置包括背景图片与填充方式、模糊和透明度、Markdown 与高级渲染器、思考预览、流式显示、聊天气泡、字体路由、颜色配置、消息功能栏、输入快捷功能和动画。iPhone 与 Apple Watch 提供相同的配置能力，但二级页面和控件布局会按屏幕调整。

            颜色配置可以分别定义用户和助手的气泡、明暗模式文字、强调/粗体/代码颜色及指定内容着色规则，也可以按每日时间段自动切换配置。背景选择与颜色、字体的各级编辑页都有独立上下文；向导只能选择已经存在的背景，导入或删除媒体仍由用户操作。
            """
        ),
        GuideDocument(
            id: "settings-extended",
            title: "拓展功能入口",
            keywords: ["拓展", "本地模型", "导入", "远程文件", "反馈", "图片相册"],
            content: """
            拓展功能页汇总快速指令、后台生成、应用锁、本地模型、图片相册、远程文件访问、存储管理和数据导入。该页本身是入口索引；进入具体功能后，向导使用对应页面的文档、快照和工具，不会把其他功能的设置混入当前提案。

            图片相册、反馈记录和数据导入等页面包含文件或网络副作用。向导可以解释当前页面和可见状态，但下载、导入、删除、提交等操作仍使用原生按钮及其确认流程。
            """
        ),
        GuideDocument(
            id: "settings-tools",
            title: "工具中心与工具审批",
            keywords: ["工具", "审批", "内置工具", "超时", "启用", "权限"],
            content: """
            工具中心管理普通聊天可见的内置工具、MCP 工具和快捷指令工具。工具是否存在、是否加入聊天、是否启用以及审批策略是不同层级；关闭某个工具不会自动删除其配置。

            页面向导使用的读源码和设置提案工具属于独立内部能力，不会出现在普通聊天工具列表，也不会载入用户自定义 MCP 工具。具有敏感副作用的工具保持强制审批；向导不能借修改其他设置放宽这些边界。
            """
        ),
        GuideDocument(
            id: "settings-sync",
            title: "设备同步设置",
            keywords: ["同步", "iCloud", "设备", "数据库", "冲突", "导入"],
            content: """
            设备同步设置控制可同步数据类别和同步行为。同步状态、最近结果与错误只用于诊断；修改类别不会立即替用户执行导入、覆盖或冲突处理。

            API Key、密码和令牌不作为普通配置快照发送给向导。涉及以另一台设备数据覆盖本机、清空同步记录或重新导入的操作必须在原生界面确认。
            """
        ),
        GuideDocument(
            id: "settings-memory",
            title: "记忆系统与跨对话画像",
            keywords: ["记忆", "画像", "事实", "嵌入", "检索", "跨对话"],
            content: """
            记忆系统可以分别控制检索、写入和异步跨对话画像。记忆库页面管理已有条目、嵌入模型和维护状态；画像页面管理模型、提示词、并发与用户画像事实。

            向导可以修改页面显式公开的开关、模型选择、画像草稿和记忆内容。重新嵌入、批量删除等高成本或破坏性维护操作不会由向导直接执行，必须由用户点击页面按钮确认。
            """
        ),
        GuideDocument(
            id: "agent-skills",
            title: "Agent Skills 管理",
            keywords: ["Agent Skills", "Skill", "技能", "目录", "文档", "启用"],
            content: """
            Agent Skills 由技能目录及其中的说明文件组成。根页面管理扫描位置、启用状态和技能列表；技能详情页公开名称、说明、文件摘要及可编辑内容。启用 Skill 只会让普通聊天在需要时读取对应说明，不会把它变成 MCP 工具。

            向导可以按当前页面声明修改技能元数据、启用状态与文本内容，所有写入先显示确认预览。路径必须落在技能管理允许的目录内；向导不会执行技能说明中提到的外部命令。
            """
        ),
        GuideDocument(
            id: "app-lock",
            title: "应用锁与数据库保护",
            keywords: ["应用锁", "Face ID", "Touch ID", "密码", "数据库", "自动锁定"],
            content: """
            应用锁可以在 App 回到前台时要求系统生物识别或设备密码，并可设置离开后的自动锁定时间。数据库保护与界面锁定是两个相关但不同的机制，页面会显示当前可用能力和状态。

            向导可以提出修改开关和自动锁定时间，但不能读取设备密码、生物识别信息或数据库密钥，也不能替用户完成系统认证。
            """
        ),
        GuideDocument(
            id: "background-generation",
            title: "后台生成设置",
            keywords: ["后台生成", "切换应用", "后台任务", "通知", "流式"],
            content: """
            后台生成用于降低切换 App 后长回复被系统暂停的概率。可用方式受平台后台执行规则、网络连接和模型流式响应影响，不能保证无限期运行。

            向导可以修改当前页公开的后台行为与通知设置。系统权限仍需用户在原生授权界面处理；关闭功能不会删除已有会话或生成内容。
            """
        ),
        GuideDocument(
            id: "browser-agent",
            title: "Browser Agent 设置",
            keywords: ["Browser Agent", "浏览器", "网页", "会话", "调试", "代理"],
            content: """
            Browser Agent 为当前会话提供受控网页浏览能力。功能页显示运行状态和当前会话关联，设置页管理允许的行为、模型及浏览配置。它与普通网络搜索、全局代理和 MCP 浏览器服务器不是同一项功能。

            向导可以修改页面声明的浏览设置，但不会替用户启动浏览任务、提交网页表单或确认网站上的外部操作。
            """
        ),
        GuideDocument(
            id: "built-in-prompts",
            title: "内置提示词模板",
            keywords: ["内置提示词", "模板", "分类", "系统提示词", "覆盖"],
            content: """
            内置提示词按分类提供 App 各功能使用的默认模板。概览页显示分类与条目，分类页选择具体模板，编辑页修改当前草稿。空白自定义值通常表示继续使用内置默认内容。

            向导可以读取和修改当前条目的草稿，但编辑页仍遵循原生保存按钮；恢复默认和覆盖现有内容前应确认当前自定义内容是否仍需保留。
            """
        ),
        GuideDocument(
            id: "local-linux",
            title: "本地 Linux 环境与终端快捷项",
            keywords: ["Linux", "iSH", "终端", "环境变量", "命令规则", "快捷键", "安全"],
            content: """
            本地 Linux 是 App 内嵌的隔离运行环境，可供终端和受支持工具使用。配置包括环境实例、启动参数、环境变量、命令规则、安全限制以及终端快捷输入。不同环境的配置相互独立。

            向导可以在对应页面修改环境草稿、变量、规则和快捷项；需要保存的编辑器会明确保留原生保存步骤。启动、停止、重建环境和执行命令属于运行操作，不会因为一项设置提案而自动发生。
            """
        ),
        GuideDocument(
            id: "local-models",
            title: "本地模型管理与采样链",
            keywords: ["本地模型", "GGUF", "导入", "CLI", "采样", "Sampler", "上下文"],
            content: """
            本地模型页管理已经导入的 GGUF 权重、运行开关、上下文参数和采样链。CLI 导入页把命令参数解析为表单草稿；解析不会自动下载或保存模型，用户仍需检查结果并应用。

            向导可以修改现有模型配置、导入参数草稿和采样链实验值。模型文件导入、删除和高占用加载必须由用户通过原生操作确认；采样链实验修改后仍需保存到目标模型。
            """
        ),
        GuideDocument(
            id: "model-pricing",
            title: "模型价格与峰谷时段",
            keywords: ["价格", "计费", "Token", "缓存", "峰谷", "工作日"],
            content: """
            模型价格用于本地估算输入、输出及缓存 Token 成本，不会改变上游服务商实际账单。可以设置基础价格、分层价格和按星期生效的峰谷时间段；空值表示该项未配置。

            向导可以修改当前价格层级、时段列表和工作日选择。时段使用一天内分钟数表示，页面会负责格式化显示并校验范围。
            """
        ),
        GuideDocument(
            id: "roleplay",
            title: "角色扮演、角色卡与变量",
            keywords: ["角色扮演", "角色卡", "Persona", "酒馆", "变量", "宏", "会话"],
            content: """
            角色扮演配置包括角色卡、用户 Persona、会话绑定、提示词位置、正则规则、宏和不同作用域的变量。导入酒馆卡片后仍可在详情页检查并编辑解析出的字段。

            向导可以修改当前页公开的角色、Persona、会话映射、宏和变量草稿。宏与变量分属不同保存区，向导修改后仍需分别点击页面上的保存按钮；删除角色或覆盖导入数据继续使用原生确认流程。
            """
        ),
        GuideDocument(
            id: "slash-commands",
            title: "快速指令与页面跳转",
            keywords: ["快速指令", "Slash Command", "命令", "别名", "页面跳转"],
            content: """
            快速指令是在聊天输入框中使用的短命令，可触发 App 内置操作或跳转到指定设置页。命令名称、别名、说明、目标和启用状态由快速指令列表管理。

            向导可以在根页批量创建、编辑、删除和排序自定义命令，也可以在单条编辑器中修改草稿。草稿页需要用户保存；向导不会直接执行命令或代替用户发送聊天消息。
            """
        ),
        GuideDocument(
            id: "speech-input",
            title: "语音输入与转写模型",
            keywords: ["语音输入", "录音", "转写", "音频", "模型", "格式"],
            content: """
            语音输入设置控制录音入口、音频格式、发送原始音频还是先转写，以及用于转写的模型。选择转写模式时需要一个可运行且能力匹配的模型。

            向导可以修改开关、格式和模型选择，但不能读取录音内容，也不能替用户授予麦克风权限或开始录音。
            """
        ),
        GuideDocument(
            id: "storage-management",
            title: "存储占用与缓存管理",
            keywords: ["存储", "缓存", "模型文件", "附件", "清理", "占用"],
            content: """
            存储管理按本地模型、会话附件、生成文件和可重建缓存统计占用。统计可能需要后台扫描；页面显示的扫描状态和分类大小可供向导解释。

            清理、删除或迁移文件属于破坏性操作，必须由用户在原生界面选择目标并确认。向导不会把“释放空间”的一般问题直接转换成删除操作。
            """
        ),
        GuideDocument(
            id: "tts",
            title: "语音朗读服务",
            keywords: ["TTS", "语音朗读", "声音", "服务", "API", "自动播放"],
            content: """
            TTS 设置控制朗读开关、自动播放、默认服务、声音及服务端参数。不同服务可能使用本地系统语音或远程 API；模型聊天与 TTS 服务的凭据彼此独立。

            向导可以修改服务列表和当前服务的非敏感配置。已有密钥只显示为隐藏状态，但可以通过写入字段替换；测试播放和系统语音下载仍由用户操作。
            """
        ),
        GuideDocument(
            id: "worldbooks",
            title: "世界书与条目触发",
            keywords: ["世界书", "Lorebook", "条目", "关键词", "触发", "递归", "注入"],
            content: """
            世界书由一个或多个有序条目组成。条目可以按关键词、常驻或其他规则触发，并把内容注入指定提示词位置；顺序、深度和启用状态会影响最终上下文。

            向导可以在世界书根页、详情页和条目编辑器中修改元数据、完整条目列表及当前草稿。编辑器页面仍需用户保存；导入覆盖和删除世界书使用原生确认流程。
            """
        ),
        GuideDocument(
            id: "daily-pulse",
            title: "每日脉冲生成与送达",
            keywords: ["每日脉冲", "Pulse", "卡片", "定时送达", "关注焦点", "策展"],
            content: """
            每日脉冲会根据近期会话、关注焦点、未完成任务以及用户允许纳入的外部能力生成主动情报卡片。启用功能、首次打开自动补生成与定时送达分别控制是否生成、何时补生成和是否安排本地通知。

            向导可以修改卡片数量、关注焦点、明日策展、外部上下文开关和各张卡片的送达时间。送达时间使用 24 小时制；立即生成、删除任务、清理反馈或外部信号仍由用户点击原生按钮执行。
            """
        ),
        GuideDocument(
            id: "usage-analytics",
            title: "用量统计口径",
            keywords: ["用量", "统计", "Token", "费用", "请求", "缓存", "趋势"],
            content: """
            用量统计根据 App 本地记录的模型请求汇总 Token、请求数、错误、缓存命中和估算费用。模型价格来自本地价格设置，因此费用仅用于参考，不代表上游服务商的最终账单。

            向导可以读取当前页面选择范围的总览与详情，帮助解释数字和定位异常；统计页没有可由向导修改的设置。日期、月份和统计范围继续由页面控件切换。
            """
        )
    ]
}

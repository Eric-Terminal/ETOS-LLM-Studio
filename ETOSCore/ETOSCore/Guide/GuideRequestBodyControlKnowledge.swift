import Foundation

/// 同时供免费线路的页面上下文与用户模型使用，避免功能知识只进入其中一条线路的系统提示词。
public enum GuideRequestBodyControlKnowledge {
    public static func orientation(for page: GuidePageDescriptor, locale: Locale) -> String {
        // 详细知识跟随编辑页主动声明的文档，不在普通设置页面增加参数规则和示例。
        guard page.documents.contains(where: { $0.id == "model-request-body" }) else {
            return locale.language.languageCode?.identifier == "zh"
                ? "ELS 提供名为“结构化控制”的能力，可以帮助用户自定义请求 Body；需要配置时，引导用户进入模型编辑页面。"
                : "ELS provides Structured Controls to help users customize request bodies. Guide users to the model editor when they need to configure them."
        }
        if page.id.rawValue.hasPrefix("mac-request-runtime") {
            return locale.language.languageCode?.identifier == "zh" ? """
            Mac 聊天控制位于输入区的“聊天控制”按钮，作用于当前会话实际使用的模型。propose_mac_runtime_control 接受 control_id 及且仅及 active、option_id、position 中的一项；active 仅用于开关，option_id 为已声明的选项 ID，空字符串清除当前覆盖并跟随默认，position 为启用滑块的 0–1 有限位置，核心会吸附离散档位或邻近锚点。用户原生确认后直接保存为后续请求的运行态，不修改模型配置默认值。参数正文与预览不向向导公开。切换模型/会话、修改选择或恢复数据使旧提案失效。Mac 原生滑块按位置使用已保存端点配色，最高档开启彩虹时数值显示流动颜色；减弱动态效果时静止，窗口非活跃时暂停。思考扫光来自每次请求的消息快照，不随之后调整档位改变。当前页面只能修改已声明的选择，不可调用配置编辑工具或外部工具。关闭控制只跳过叠加，不发送 false。
            """ : """
            Mac Chat Controls opens from the composer and targets the model used by this conversation. propose_mac_runtime_control accepts control_id and exactly one of active, option_id or position. active is for switches; option_id must be declared, and an empty string clears the override to follow defaults. position is a finite 0–1 value for an enabled slider; Core snaps discrete values and nearby anchors. Native confirmation saves runtime choices for future requests without changing model configuration defaults. Parameter payloads and the preview are hidden from the guide. Model/session changes, changed selections or data restoration invalidate old proposals. Mac native sliders use saved endpoint colors along their position; the value flows with rainbow colors at maximum when enabled. Reduce Motion makes it static and inactive windows pause animation. Thinking sweeps use the per-request message snapshot, not later control changes. Change only this page's declared selections, without configuration-editor or external tools. Disabling a switch skips its overlay without sending false.
            """
        }
        if page.id.rawValue.hasPrefix("mac-") {
            return locale.language.languageCode?.identifier == "zh" ? """
            空选项可沿用前一选项的参数结构，但不会复制标量值。suggestion_visible 表示参数页仍显示未编辑建议，suggestion_available 表示选项页仍可使用建议，均为只读。未编辑完成或仅切换方式不保存建议；键值表中未改的建议行也不保存。编辑 JSON 后保留的 null 会作为实际参数保存。参数或选项页取消会丢弃该层修改；已消费的建议清空后不会恢复。不要将建议模板说成已生效的参数。
            Mac 入口为模型管理 → 提供商 → 模型配置 → 自定义 Body。根页是只读目录，新增、复制、导入、排序和拆分通过原生按钮完成；控制、选项和参数编辑器各自声明字段。参数页的 propose_mac_request_parameters 可替换用户提供的 parameters 对象，或设置 edit_mode 为 keyValue、expression、rawJSON；已有参数只写不可读，不得凭空补写未知秘密。该工具只改草稿，不发送请求。完成子页后仍需完成模型并保存提供商。当前有效参数预览使用控制默认值，不是包含消息和工具的完整请求，也不改变数据库中的当前聊天选择。实际可用工具和字段以当前页面声明为准；更改默认值不等于清除运行状态。上游参数仍需确认协议支持，关闭控制仅跳过叠加，不发送 false。
            """ : """
            Empty options can reuse the preceding option's parameter structure without copying scalar values. Read-only suggestion_visible indicates an untouched template in the parameter editor; suggestion_available indicates one is available to the option editor. Finishing without edits or only switching modes saves no suggested parameters; untouched suggested key/value rows are omitted too. After editing JSON, retained nulls are actual values. Cancelling a parameter or option editor discards that level's changes. Clearing a consumed suggestion does not restore it. Templates are not active parameters.
            On Mac, open Model Management → Provider → Model Configuration → Custom Body. The root is a read-only catalog for the guide; use native actions to create, copy, import, reorder or split controls. Control, option and parameter editors declare their own fields. propose_mac_request_parameters replaces a user-supplied parameters object or sets edit_mode to keyValue, expression or rawJSON. Existing parameters are write-only; never invent unknown credentials. It only changes a draft and sends no request. Finish child and model editors, then save the provider. The effective-parameter preview uses defaults, excludes messages/tools and does not change saved chat selections. Use only this page's declared tools and fields. Changing defaults does not clear runtime state. Check upstream support; disabling a control only skips its overlay and does not send false.
            """
        }
        if locale.language.languageCode?.identifier == "zh" {
            return """
            当用户问“调整/关闭思考、推理强度、预算、温度、联网搜索、响应格式或其他 API 请求参数”，先区分模型请求参数与显示设置。请求参数的可复用开关、档位和滑块属于“结构化控制”，入口为模型管理 → 提供商 → 模型信息 → 结构化控制。不要臆造独立的“思考开关”。先读 model-request-body；模型信息页可用 propose_model_request_body_controls 新增和修改，控制详情页则使用当前声明的字段工具。以本次工具列表为准，不在对应页面时引导用户进入，不要声称所有页面都能写。
            例：用户要“关闭思考”→确认当前提供商与 effective_api_format、该上游确实支持的关闭参数，再提交具有明确关闭 payload 的选项；关闭一个控制只是不再叠加它，并不发送 false。
            例：用户要“低/中/高随时切换”→创建 optionGroup，每个选项写完整参数；default_option_id 是默认值，current_option_id 才修改已有当前选择。
            例：用户要“别显示思考过程”→应查显示设置，不能擅自改模型的推理参数。
            上游参数名和可用值不能仅凭模型名字猜测；App 的映射、合并和滑块行为不清楚时，使用 search_source_code 定位 ModelRequestBodyControlCompiler 或 ModelRequestBodyControlSliderDescriptor，再用 read_source_file 按行读取当前构建源码。源码能说明客户端行为，不代表上游接受该参数。
            """
        }
        return """
        When users ask about reasoning effort/budget, disabling thinking, temperature, web search, response formats or other API request parameters, distinguish model parameters from display preferences. Reusable switches, presets and sliders are Structured Controls: Model Management → Provider → Model Information → Structured Controls. Do not invent a separate thinking switch. Read model-request-body first. The model page exposes propose_model_request_body_controls; a control editor exposes its own field tool. Use only the current tool list; otherwise guide the user to the correct page.
        Example: “disable thinking” → check provider, effective_api_format and a documented upstream disabling value, then propose an option with an explicit disabling payload. Turning a control off only stops its overlay; it does not send false.
        Example: “switch low/medium/high easily” → create an optionGroup with complete payloads per option. default_option_id changes a default; current_option_id changes an existing current selection.
        Example: “hide the thinking text” → use display settings, not reasoning request parameters.
        Do not guess upstream parameters from model names. For unclear app behavior, search_source_code for ModelRequestBodyControlCompiler or ModelRequestBodyControlSliderDescriptor, then read_source_file in line ranges at this build’s commit. Client source does not prove upstream API support.
        """
    }

    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "model-request-body",
            title: chinese ? "模型请求体与结构化控制" : "Model Request Body and Structured Controls",
            keywords: ["结构化控制", "请求体", "JSON", "思考", "推理", "关闭思考", "调整思考", "思考预算", "推理强度", "隐藏思考", "联网搜索", "温度", "参数", "滑块", "彩虹", "扫光", "reasoning", "thinking", "budget", "temperature", "response_format", "controls", "rainbow", "shimmer"],
            content: chinese ? chineseDocument : englishDocument
        )
    }

    // 这些 JSON 也是回归用例输入；占位参数仅用于说明控件，不宣称所有模型都支持。
    public static let reasoningExample = #"{"controls":[{"title":"推理强度","kind":"optionGroup","options":[{"id":"low","title":"低","payload":{"reasoning_effort":"low"}},{"id":"medium","title":"中","payload":{"reasoning_effort":"medium"}},{"id":"high","title":"高","payload":{"reasoning_effort":"high"}}],"default_option_id":"medium","current_option_id":"medium"}]}"#
    public static let thinkingOffExample = #"{"controls":[{"title":"思考模式","kind":"optionGroup","options":[{"id":"off","title":"关闭","payload":{"thinking":{"type":"disabled"}}},{"id":"on","title":"开启","payload":{"thinking":{"type":"enabled","budget_tokens":4096}}}],"default_option_id":"off","current_option_id":"off"}]}"#
    public static let sliderExample = #"{"controls":[{"title":"温度","kind":"optionGroup","options":[{"id":"zero","title":"0","payload":{"temperature":0}},{"id":"one","title":"1","payload":{"temperature":1}}],"slider_enabled":true,"slider_granularity":0.1,"current_slider_position":0.5}]}"#
    public static let customExample = #"{"controls":[{"title":"自定义请求预设","kind":"toggle","default_active":true,"payload":{"vendor_config":{"search":{"enabled":true},"response":{"format":"json"}}}}]}"#

    private static let chineseDocument = """
    结构化控制不是仅用于思考的特殊功能，而是把任意 API 请求 JSON 包装成聊天时可快速切换的开关、选项组或滑块。路径：模型管理 → 提供商 → 模型信息 → 结构化控制。不要把“键值对/表达式/原始 JSON”三种自定义 Body 编辑方式与结构化控制混为一谈；它们是基础参数的编辑方式，控制项则在发送时叠加到基础参数上。

    Mac 的空选项可建议沿用前一项的字段结构，标量清空，JSON 模板以 null 表示待填位置。未编辑建议或仅切换编辑方式不生成参数；键值表里仍与建议相同的行，即使其他行已修改，也不会保存。编辑 JSON 后留下的 null 按实际值保存。完成接受当前草稿，取消参数页或选项页丢弃该层修改。已消费的建议清空后不再出现。向导只看到只读的建议状态，不能读取原值。

    Mac 在模型配置的“自定义 Body”中编辑基础参数及控制定义。参数、控制、选项、导入目录和说明页各有向导上下文，所有完成按钮仅返回父级草稿，最终保存提供商才持久化。参数页的 propose_mac_request_parameters 只接受 parameters 对象和/或 edit_mode（keyValue、expression、rawJSON）；替换对象是完整替换，不是补丁。已有参数不可读，新提案预览脱敏，手动修改使旧版本提案失效。切换编辑方式先验证原稿，不能通过切换丢弃无效输入；表单不能表示的外部键会保留为 JSON。控制列表支持原生新增、复制、导入、上下移动和删除，详情可编辑默认值、选项、滑块粒度、端点颜色及最高档效果，可按数值排序或按嵌套路径拆分。导入与复制重新分配控制/选项 ID；拆分保留核心合并语义。Mac 默认参数预览不是完整请求，不读取消息、不调用网络、不写聊天运行状态。输入区的“聊天控制”使用另一个独立页面，直接保存当前运行态；propose_mac_runtime_control 每次修改一个已有控制，参数与秘密不可读。选项 ID 为空表示跟随默认，滑块范围为 0–1。界面与向导共享来源版本检查，切换模型或会话会使旧操作失效。发送、重试、重写、HTML 发送及工具补充消息等待已接受的写入；备份、恢复和退出也等待该队列。Mac 滑块使用共享配色并保留系统操作，最高档数值使用彩虹；思考/等待/重试提示使用当前真实请求 ID 和每次请求的样式快照，历史及结束消息不播放活动动画。减弱动态效果与非活跃窗口会停止动态效果。

    优先级：全局默认参数 → 模型自定义 Body → 按列表顺序启用的结构化控制。同名对象递归合并，数组和标量由后者替换；后面的控制覆盖前面的同名参数。这里的 effective_request_body_overrides 是自定义 Body 与当前控制合成的覆盖参数，不是包括消息、工具等字段的整个 HTTP 请求。pending 的编辑草稿不一定等于已保存参数。

    toggle 的 enabled 决定控制是否参与处理，default_active 是无当前选择时的默认开关值。开关为关时只是跳过 payload，不会发送 false，也不会删除基础 Body 中的同名参数。若上游需要明确的禁用值，使用“开启/关闭”两个选项，各自写实际 payload。隐藏思考过程是显示设置；回传思考是历史传输设置；它们都不等同于让上游停止推理。

    optionGroup 的每个选项包含 id、title 和 payload。default_option_id 是默认档位，已有运行态选择优先；想“现在改成高”需提交 current_option_id，想“现在开启开关”需 current_active。current_option_id 空字符串清除当前覆盖、回到默认，并非禁用该组。default_option_id 为空且没有当前选择时普通组选项不叠加；滑块则回退到首个锚点。slider_enabled 要求至少两个选项：兼容的单个数值路径会插值，其他 JSON 组合只切换离散档位；slider_granularity 控制数值粒度，current_slider_position 为 0–1 的位置。选档位会清除旧滑块位置，两种 current 选择不要同时提交。

    模型页工具 propose_model_request_body_controls 的 controls 是增量列表：新增控制省略 id，更新沿用快照 ID；未提及的控制保持不变，新项追加在列表末尾。省略字段保留原值；提交 payload 会替换该字段，提交 options 会替换完整选项列表，修改或保留选项要沿用原 ID。已有隐藏认证字段省略或回传 <hidden> 时会保留；用户主动给出新秘密可以覆写，预览脱敏。remove_control_ids 必须显式列出要删除的控制。类型转换请明确删除旧控制并新增新类型，不要顺便改其他控制。用户确认后模型页保存配置及当前选择；控制详情页仍是模型编辑草稿，按该页 requires_save 说明完成保存。

    “最高档彩虹效果”（rainbow_at_maximum）只在启用的滑块控制到达当前最后一档时生效。普通思考提示使用单色扫光；若发起请求时至少一个控制满足上述条件且已开启彩虹，该次请求的思考提示使用彩虹扫光。判断以滑块实际端点为准，接近最高档但未到达时仍是单色；新增或重排选项后，最高档跟随最后一项。请求中的样式不随之后切换模型或档位而改变，也不写入聊天历史。系统“减弱动态效果”开启时不播放扫光。

    少样本（必须先确认真实上游协议；以下参数不保证适用于所有提供商或所有同名模型）：
    1. 用户：“我想低中高切换思考强度。”已确认此服务的 OpenAI 兼容接口支持 reasoning_effort 的 low/medium/high → 可提交：
    \(reasoningExample)
    2. 用户：“彻底关闭模型思考，不是隐藏文字。”已确认此接口支持 thinking.type=disabled，以及 enabled + budget_tokens → 可提交：
    \(thinkingOffExample)
    3. 用户：“温度做一个 0 到 1 的滑块，当前先用 0.5。”已确认此模型支持该范围的 temperature → 可提交：
    \(sliderExample)
    4. 用户提供自定义接口文档，确认 vendor_config 中搜索和响应格式的结构 → 可以创建任意嵌套预设，不限于思考参数；下例 vendor_config 是演示字段，不能套用到未声明支持它的服务：
    \(customExample)

    不确定 App 怎么合并或生成请求时，先 search_source_code 查询 ModelRequestBodyControlCompiler、ModelRequestBodyControlSliderDescriptor 或适配器，再 read_source_file(path,start_line,end_line) 分段读取；单次最多 240 行，按返回总行数继续。源码工具只在存在当前构建完整 SHA 时提供，若未提供应说明当前版本无法定位源码，不要假装已读。客户端源码用于理解 ELS，不足以证明某个远程服务当前支持什么参数。
    """

    private static let englishDocument = """
    Structured Controls wrap arbitrary API request JSON into reusable chat switches, option groups or sliders, not just reasoning settings. Path: Model Management → Provider → Model Information → Structured Controls. Key/value, expression and raw JSON are three editors for the base custom Body, not structured controls themselves.

    Mac empty options can suggest the preceding option's field structure, with scalar values removed and JSON placeholders represented as null. Untouched templates, including mode-only changes, do not become parameters. Key/value rows still matching their suggested structure are omitted even when another row is edited; edited JSON retains explicit nulls. Done accepts the current draft; cancelling a parameter or option editor discards that editor's changes. Consumed suggestions do not reappear after clearing. The guide sees only read-only availability flags, never the original values.

    On Mac, Model Configuration → Custom Body edits base parameters and control definitions. Parameters, controls, options, import catalogs and introduction pages have separate guide contexts. Done returns to the parent draft; saving the provider persists changes. propose_mac_request_parameters accepts a parameters object and/or edit_mode (keyValue, expression, rawJSON). Object replacement is complete, not a patch. Existing parameters are unreadable, new proposal previews are redacted, and manual changes invalidate stale proposals. Switching modes validates the draft first; unsupported form keys retain their JSON representation. Native actions create, copy, import, move and delete controls. Details edit defaults, options, slider granularity, endpoint colors and maximum effects; numeric sorting and nested-path splitting reuse core behavior. Copy/import regenerate control and option IDs. The default-parameter preview excludes messages and performs no network or runtime-state writes. The composer has a separate Chat Controls page that saves runtime selections directly. propose_mac_runtime_control changes one existing control at a time; payloads and secrets are hidden. An empty option ID follows defaults, and slider positions range from 0 to 1. Native and guide actions check their source revision; switching model or session invalidates old actions. Sending, retrying, rewriting, HTML sends and tool supplements wait for accepted writes, as do backup, restore and termination. Mac sliders use shared colors with native interaction and rainbow values at maximum. Thinking, waiting and retry indicators use the actual active request ID and per-request appearance; history and completed messages do not animate. Reduce Motion and inactive windows stop motion.

    Precedence: global defaults → model custom Body → enabled controls in list order. Objects merge recursively; later arrays/scalars replace earlier values. effective_request_body_overrides combines the saved custom Body and current control state, not the entire HTTP request with messages/tools. Unsaved editor drafts may differ.

    A toggle overlays its payload only when enabled and currently active (otherwise default_active applies). Switching it off merely skips that overlay: it sends no false and removes no base parameter. To explicitly disable upstream thinking, use separate On/Off options with documented payloads. Hiding reasoning text is a display preference; sending reasoning history is a transport preference. Neither disables upstream reasoning.

    optionGroup options contain id, title and payload. Existing runtime choices override default_option_id. Use current_option_id or current_active to change the current selection as well. An empty current_option_id clears the override and returns to defaults, rather than disabling the group; it also clears the old slider position. Ordinary groups without a current/default option contribute nothing. Sliders with no selection use the first anchor. slider_enabled requires two options: compatible single numeric paths interpolate, while other payloads use discrete presets. slider_granularity is the numeric step, and current_slider_position is a position from 0 to 1. Do not send current_option_id and current_slider_position together.

    propose_model_request_body_controls accepts an incremental controls list. Omit id when creating a control; use snapshot IDs to update existing ones. Untargeted controls remain unchanged; new ones append. Omitted fields remain unchanged; supplied payload replaces that field, and options replaces the complete option list (retain stable IDs). Omitted or <hidden> existing credential values are preserved. User-supplied new credentials can be written but previews are redacted. Delete only explicit remove_control_ids. Change kind by explicitly deleting and creating. After native confirmation the model page saves controls and current choices. Individual control editors update a model draft: follow requires_save to finish saving.

    Rainbow at Maximum (rainbow_at_maximum) applies only when an enabled slider control reaches its current last option. Thinking indicators normally use a monochrome sweep. A request uses a rainbow sweep if at least one enabled slider has this effect enabled and is at its actual maximum endpoint when the request starts. Being near the last option is insufficient; adding or reordering options changes which option is highest. Later model or level changes do not alter an ongoing request's appearance, and the appearance is not saved in chat history. Reduce Motion disables the sweep animation.

    Few-shot examples, ONLY after checking the actual upstream API. These parameters are not universal:
    1. “Let me switch reasoning low/medium/high.” The selected OpenAI-compatible service explicitly supports these reasoning_effort values:
    \(reasoningExample)
    2. “Disable model thinking, not just its display.” The selected API explicitly supports thinking.type=disabled and enabled with budget_tokens:
    \(thinkingOffExample)
    3. “Give me a temperature slider from 0 to 1, currently at 0.5.” The selected model supports this range:
    \(sliderExample)
    4. A user supplies API documentation defining nested search/response settings. Arbitrary JSON presets are supported; vendor_config below is an illustrative field, not a real universal API:
    \(customExample)

    If ELS merging/request behavior is unclear, search_source_code for ModelRequestBodyControlCompiler, ModelRequestBodyControlSliderDescriptor or the adapter, then read_source_file(path,start_line,end_line), at most 240 lines per call. Continue using returned line counts. Source tools exist only when this build has a complete commit SHA; if absent, explain that limitation and do not pretend to have read source. Client implementation does not prove current upstream parameter support.
    """
}

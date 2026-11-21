import Foundation

/// 同时供免费线路的页面上下文与用户模型使用，避免功能知识只进入其中一条线路的系统提示词。
public enum GuideRequestBodyControlKnowledge {
    public static func orientation(for page: GuidePageDescriptor, locale: Locale) -> String {
        // 详细知识跟随编辑页主动声明的文档，不在普通设置页面增加参数规则和示例。
        guard page.documents.contains(where: { $0.id == "model-request-body" }) else {
            return locale.language.languageCode?.identifier == "zh"
                ? "ELS 提供名为“结构化控制”的能力，可以帮助用户把自定义请求 Body 参数做成快捷开关、档位或滑块；需要配置时，请引导用户进入对应模型的编辑页面。"
                : "ELS provides Structured Controls so users can turn custom request body parameters into quick switches, presets or sliders. Guide users to the model editor when they want to configure them."
        }
        if page.id.rawValue.hasPrefix("mac-request-preview") {
            return locale.language.languageCode?.identifier == "zh" ? """
            当前页面是只读的“聊天请求体示例”。它根据当前模型草稿、控制项默认值和一条 <message> 占位消息，按所选接口协议展示组装后的参数样式；不会联网发送请求，不会读取真实 API Key，也不会包含当前聊天记录、附件、全局采样设置或已启用的工具。已知敏感字段在界面上会自动脱敏，且向导不能读取正文、不能复制或修改示例，也不能用它代表上游服务一定支持某个参数。如需调整，请引导用户返回参数或控制编辑页修改，完成后记得逐级点“完成”并保存提供商。
            """ : """
            This page is a read-only sample chat request body built from the current model draft, control defaults and a <message> placeholder. It sends no network request, reads no real provider credentials and omits your active conversation, attachments, global sampling settings and enabled tools. Sensitive fields are redacted on screen, and the guide cannot read the body, copy it, send it or edit it—nor does this preview prove upstream API support. Guide the user back to the parameter or control editor to make changes, then finish parent drafts and save the provider.
            """
        }
        if page.id.rawValue.hasPrefix("mac-request-runtime") {
            return locale.language.languageCode?.identifier == "zh" ? """
            当前是聊天输入区打开的 Mac“聊天控制”面板，专门调整当前会话所用模型的实时档位，不会改动模型配置里的默认值。使用 propose_mac_runtime_control 时，每次传入 control_id 以及 active、option_id、position 三者中的唯一一项：active 用于开关；option_id 填已定义的选项 ID（传空字符串 "" 表示恢复跟随默认）；position 用于已开启滑块的控制项（0–1 之间的小数，会自动吸附有效档位）。经用户原生确认后直接生效，用于后续聊天请求；把开关关掉只是不再叠加该组参数，不会向服务端发送 false。参数具体内容对向导隐藏，切换模型或会话后旧提案自动失效。滑块若开启了最高档彩虹效果，拉满时数值和该次请求的思考提示会显示彩色流动效果（开启减弱动态效果或窗口失焦时保持静止）。
            """ : """
            This is Mac Chat Controls opened from the message composer. It adjusts live control choices for the current conversation's model without changing the model's saved defaults. propose_mac_runtime_control takes control_id plus exactly one of active, option_id or position: active toggles a switch; option_id selects a declared option (an empty string "" clears the override back to defaults); position sets an enabled slider between 0 and 1. Native confirmation applies the choice immediately for future requests—turning a switch off simply skips its parameters rather than sending false. Parameter payloads stay hidden from the guide, and switching models or sessions invalidates older proposals. When Rainbow at Maximum is enabled on a slider, reaching the top endpoint gives the value and that request's thinking indicator a flowing rainbow tint (paused in inactive windows or with Reduce Motion).
            """
        }
        if page.id.rawValue.hasPrefix("mac-") {
            return locale.language.languageCode?.identifier == "zh" ? """
            Mac 自定义请求参数路径：模型管理 → 提供商 → 模型配置 → 自定义 Body。主页目录对向导只读，新增、复制、导入、排序或拆分控制项请由用户在界面上点击；点进具体控制、选项或参数子页后，向导可协助修改当前页声明的草稿字段。
            • 参数编辑页可用 propose_mac_request_parameters 完整替换用户给出的 parameters 对象，或将 edit_mode 切换为 keyValue（键值对）、expression（表达式）、rawJSON（原始 JSON）；已有参数值对向导只写不可读，切勿编造未知凭据。
            • 空白选项支持沿用上一选项的字段结构作为填写建议（suggestion_visible 与 suggestion_available 为只读提示）：没改动过的建议行不会保存成实际参数，只有真正编辑过的内容（包括在 JSON 里显式保留的 null）才会进入草稿。
            • 所有子页点“完成”只会回到上一级草稿，最终必须完成模型编辑并点击提供商的“保存”才会正式生效；修改默认值不会清空聊天里已选的实时档位，关闭控制也只是跳过叠加而非发送 false。
            """ : """
            On Mac, open Model Management → Provider → Model Configuration → Custom Body. The root catalog is read-only to the guide—use native buttons to create, duplicate, import, reorder or split controls—while individual control, option and parameter editors expose their own draft fields.
            • In a parameter editor, propose_mac_request_parameters can replace the parameters object with one supplied by the user or switch edit_mode between keyValue, expression and rawJSON; existing parameter values are write-only, so never invent credentials.
            • Empty options may show a structure template based on the preceding option (read-only suggestion_visible and suggestion_available): untouched template rows are omitted on save, whereas explicitly edited JSON values (including retained nulls) are kept.
            • Clicking Done in a child editor only updates its parent draft—finish the model editor and click Save on the provider to persist changes. Updating defaults does not clear live chat overrides, and turning a control off only skips its overlay without sending false.
            """
        }
        if locale.language.languageCode?.identifier == "zh" {
            return """
            当用户询问“怎么调节或关闭思考、推理强度、思考预算、温度、联网搜索、JSON 输出格式或其他 API 请求参数”时，请先帮用户分清“向模型发送的请求参数”和“本地界面显示设置”：
            • 想做在聊天时随时切换的开关、多档选项或滑块 → 属于“结构化控制”（路径：模型管理 → 提供商 → 模型信息 → 结构化控制），请先查阅 model-request-body 文档，不要凭空编造根本不存在的“思考开关”。在模型信息页可用 propose_model_request_body_controls 新增或修改，在单个控制详情页则使用当前页面提供的字段工具；不在对应页面时请先引导用户打开。
            • 例 1（彻底关闭模型思考）：先确认当前提供商、effective_api_format 以及该服务商接口文档真正支持的关闭字段，再创建带明确关闭 payload 的选项；单纯把一个控制开关关掉只是不再附加参数，并不会发送 false。
            • 例 2（低 / 中 / 高随时切换）：创建 optionGroup，每个选项写清完整参数；default_option_id 只改默认档位，想把当前正在用的档位一并改掉需同时指定 current_option_id。
            • 例 3（只是不想在聊天气泡里看到长串思考过程）：去改“显示设置”里的思考预览即可，不要乱动模型的推理参数。
            切勿仅凭模型名字猜测服务商支持什么字段；若不确定 App 本身的合并或滑块插值规则，可用 search_source_code 查找 ModelRequestBodyControlCompiler 或 ModelRequestBodyControlSliderDescriptor，再用 read_source_file 按行读取当前版本源码（客户端源码仅说明 App 行为，不代表远端接口一定接受该参数）。
            """
        }
        return """
        When users ask how to adjust or disable thinking, reasoning effort/budget, temperature, web search, response format or other API request parameters, first distinguish upstream request parameters from local display settings:
        • Reusable chat switches, presets and sliders belong to Structured Controls (Model Management → Provider → Model Information → Structured Controls). Read model-request-body first and never invent a nonexistent thinking toggle. Use propose_model_request_body_controls on the model page or the declared field tool inside a control editor; if the user is elsewhere, guide them to the right page first.
        • Example 1 (“turn off model thinking”): verify the provider, effective_api_format and the upstream API's actual disabling payload, then propose an option carrying that explicit payload. Turning a control switch off merely stops overlaying its payload—it never sends false.
        • Example 2 (“switch low / medium / high easily”): create an optionGroup with complete payloads for each option; default_option_id sets the default, while current_option_id updates the active selection right now.
        • Example 3 (“just hide the thinking text on screen”): point the user to Display Settings instead of altering model reasoning parameters.
        Never guess upstream parameter names from a model's name alone. If client-side merging or slider behavior is unclear, use search_source_code for ModelRequestBodyControlCompiler or ModelRequestBodyControlSliderDescriptor and read_source_file by line range (client code explains app behavior only, not upstream API support).
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
    什么是“自定义请求体”与“结构化控制”：
    许多大模型接口支持在请求里附带额外 JSON 参数（例如调整思考强度、推理预算、温度、联网搜索、JSON 输出格式等）。
    • 基础自定义 Body（支持“键值对”、“表达式”、“原始 JSON”三种编辑方式）：用来填写该模型每次请求固定带上的基础参数。
    • 结构化控制（入口：模型管理 → 提供商 → 模型信息 → 结构化控制；Mac 位于模型配置的“自定义 Body”中）：不局限于思考参数，它可以把任意自定义 JSON 包装成聊天时随手可点的**开关（toggle）、多档选项组（optionGroup）或连续滑块**，不用每次跑回设置里手改代码。

    参数生效顺序与常见误区：
    1. 覆盖优先级：全局默认参数 → 模型基础自定义 Body → 按列表从上到下叠加已启用的结构化控制（同名嵌套对象会自动合并，标量和数组由排在后面的控制项覆盖前面的）。页面快照中的 effective_request_body_overrides 展示的是合成后的覆盖参数，不包含聊天消息和工具列表。
    2. 关闭控制 ≠ 发送 false：开关（toggle）处于关闭状态时，只是本次请求不再附带它的 payload，既不会发送 false，也不会删掉基础 Body 里的同名字段。如果服务商要求必须传明确参数才能关闭思考（如 thinking.type=disabled），请创建一个包含“关闭 / 开启”两档的选项组（optionGroup），在各自 payload 里写明完整参数。
    3. 区分显示、回传与停止推理：“隐藏思考过程”是本地界面显示设置，“回传思考内容”是多轮历史传输设置，两者都不会让云端模型停止推理。注意：Gemini Interactions（gemini-interactions）多轮对话必须原样保留模型步骤与签名，不受通用回传开关裁剪；该协议使用 generation_config.thinking_level（可选 minimal、low、medium、high，其中 minimal 并非彻底关闭）和 generation_config.thinking_summaries=none（隐藏摘要），不支持旧版 generationConfig.thinkingConfig，也不接受 temperature、top_p、top_k（新建开关默认示例为 generation_config.max_output_tokens=8192，切换协议后需手动更新旧参数）。

    选项组、滑块与最高档彩虹效果：
    • 选项组（optionGroup）：每个选项包含 id、title 和 payload。default_option_id 是默认档位，而聊天中已选的实时档位优先级更高——因此想“现在立刻切到某档”时，需同时设置 current_option_id（开关同理用 current_active）。将 current_option_id 设为空字符串 "" 会清除实时覆盖、恢复跟随默认档位，而不是禁用整组。
    • 滑块模式（slider_enabled）：至少需要两个选项锚点。若各选项修改的是同一个数值字段，滑块会按 slider_granularity（步进粒度）在 0–1 的 current_slider_position 上平滑计算数值；若是复杂组合参数则按档位切换。请勿在同一提案里同时传 current_option_id 和 current_slider_position。
    • 最高档彩虹效果（rainbow_at_maximum）：开启后，只有当已启用的滑块真正拉到最后一档端点时（接近但未到端点仍为单色；重排选项后以最新末尾项为准），滑块数值以及该次请求流式思考时的标题扫光才会呈现彩色流动效果。开启系统“减弱动态效果”或窗口处于后台时会自动停止动画。

    Mac 端编辑、预览与实时控制说明：
    • 草稿与保存边界：在 Mac“自定义 Body”下编辑参数、控制或选项时，点子页“完成”只会更新上一级草稿，最终必须完成模型编辑并点击提供商的“保存”才会正式保存。参数页工具 propose_mac_request_parameters 支持完整替换用户提供的 parameters 对象或切换 edit_mode（keyValue / expression / rawJSON）；已有参数与凭据只写不可读。空白新选项会贴心提示上一选项的字段骨架（未改动的模板行不会写入，编辑 JSON 后显式保留的 null 会按实际值保存）。
    • 聊天请求体示例页：仅远程聊天模型提供，使用当前草稿、控制默认值和 <message> 占位消息在本地生成只读示例，不联网、不读真实密钥，向导也不可读取其正文。
    • 输入框“聊天控制”：点击输入框旁的按钮即可直接切换当前对话模型的实时开关、档位或滑块（工具为 propose_mac_runtime_control，经原生确认后立即生效，不会改动模型默认配置）。

    向导提案规则与常用配置示例（提交前务必确认服务商接口文档实际支持该字段，切勿对所有模型生搬硬套）：
    • 在移动端或模型信息页使用 propose_model_request_body_controls 时，controls 为增量更新列表：新建控制省略 id（追加到末尾），修改已有控制沿用快照中的 id（未提到的控制和省略的字段保持原样；传入 payload 或 options 会整体替换对应字段，保留的选项请沿用原 id）。已有敏感字段省略或回传 <hidden> 会安全保留原秘密；删除控制必须在 remove_control_ids 中显式列出。模型信息页经用户原生确认后直接保存，单个控制详情页则按页面 requires_save 提示保存上级草稿。
    1. 用户想“低 / 中 / 高切换思考强度”（已确认当前 OpenAI 兼容服务支持 reasoning_effort）：
    \(reasoningExample)
    2. 用户想“彻底关闭模型思考，而不是只隐藏文字”（已确认接口支持 thinking.type=disabled 与 enabled + budget_tokens）：
    \(thinkingOffExample)
    3. 用户想“做一个 0 到 1 的温度滑块，当前先停在 0.5”（已确认当前模型协议支持 temperature）：
    \(sliderExample)
    4. 用户给出了服务商文档，想把嵌套的搜索与输出格式做成一键预设开关（vendor_config 仅为演示占位名）：
    \(customExample)

    查阅当前版本客户端源码说明：
    如果向导不确定 App 内部如何合并控制参数或插值滑块，可先调用 search_source_code 搜索 ModelRequestBodyControlCompiler、ModelRequestBodyControlSliderDescriptor 或对应协议适配器，再用 read_source_file(path,start_line,end_line) 按行分段读取（单次最多读取 240 行，可根据返回总行数继续往下读）。源码工具仅在正式构建包含完整提交号时可用；若当前环境未提供该工具，请如实说明，不要假装读过源码。客户端源码只能解释 App 自身行为，不能证明某个远端服务商一定支持某项参数。
    """

    private static let englishDocument = """
    What Custom Body and Structured Controls do:
    Many model APIs accept extra JSON fields in requests—such as reasoning effort, thinking token budgets, temperature, web search or JSON output formats.
    • Base Custom Body (editable via Key/Value, Expression or Raw JSON): sets baseline parameters sent every time you use that model.
    • Structured Controls (Model Management → Provider → Model Information → Structured Controls, or under Model Configuration → Custom Body on Mac): turns any custom JSON—not just thinking parameters—into one-tap chat toggles, multi-option presets (optionGroup) or smooth sliders, so you can adjust behavior mid-chat without editing JSON by hand.

    Merge order and common pitfalls:
    1. Precedence: global defaults → model base Custom Body → enabled Structured Controls from top to bottom (nested objects merge recursively, while later scalars and arrays override earlier ones). effective_request_body_overrides shows the merged parameter overrides rather than the full HTTP payload with messages and tools.
    2. Turning a toggle off ≠ sending false: an inactive switch simply skips overlaying its payload; it sends no false and removes nothing from the base Custom Body. When an upstream API needs an explicit payload to turn off reasoning (for example thinking.type=disabled), build an optionGroup with explicit On and Off options instead.
    3. Display vs. history echo vs. upstream reasoning: hiding thinking text on screen is a Display Setting, and echoing reasoning in multi-turn history is a transport setting—neither tells the remote model to stop reasoning. Note that Gemini Interactions (gemini-interactions) always preserves model steps and signatures intact for continuations, uses generation_config.thinking_level (minimal, low, medium, high—minimal does not disable reasoning) plus generation_config.thinking_summaries=none, and rejects legacy generationConfig.thinkingConfig as well as temperature, top_p and top_k (new toggles illustrate generation_config.max_output_tokens=8192; update fields manually after switching protocols).

    Option groups, sliders and Rainbow at Maximum:
    • optionGroup: each option defines id, title and payload. Live chat selections take priority over default_option_id—pass current_option_id (or current_active for a toggle) when the user wants to switch the active setting right now. Passing an empty current_option_id ("") clears the live override back to defaults rather than disabling the group.
    • Sliders (slider_enabled): require at least two options. Compatible single numeric paths interpolate smoothly across current_slider_position (0 to 1) using slider_granularity, while complex payloads snap between discrete options. Never submit current_option_id and current_slider_position in the same update.
    • Rainbow at Maximum (rainbow_at_maximum): takes effect only when an enabled slider sits right at its last option endpoint (reordering options updates which endpoint is highest). When active at request start, both the slider readout and that reply's streaming thinking shimmer use a flowing rainbow sweep; Reduce Motion and inactive windows keep visuals static.

    Mac editors, sample preview and live Chat Controls:
    • Drafts vs. saving: inside Mac Custom Body editors, clicking Done returns changes to the parent draft—finish the model editor and click Save on the provider to persist everything. propose_mac_request_parameters replaces the full parameters object supplied by the user or switches edit_mode (keyValue, expression, rawJSON), keeping existing values write-only. Blank options offer the preceding option's structure as a starter template (untouched rows are omitted, while explicit nulls kept in edited JSON are saved).
    • Sample Chat Request Body: available on remote chat models as a read-only local preview built with a <message> placeholder; it makes no network calls, reads no real API keys and hides its body from the guide.
    • Composer Chat Controls: opens right beside the Mac input box to save live switch, preset or slider choices immediately via propose_mac_runtime_control after native confirmation, leaving saved model defaults untouched.

    Guide proposal rules and practical examples (always verify upstream API support first—these fields are not universal):
    • propose_model_request_body_controls takes an incremental controls array: omit id to append a new control, or pass an existing snapshot id to update only the supplied fields (supplying payload or options replaces that field as a whole; keep stable option IDs). Omitted or <hidden> secrets stay intact, and deletions require explicit remove_control_ids. Confirming on the model page saves immediately, whereas standalone control detail pages update a draft according to requires_save.
    1. “Let me switch reasoning effort between low, medium and high” (for an OpenAI-compatible service that supports reasoning_effort):
    \(reasoningExample)
    2. “Turn off model thinking completely, not just the UI text” (for an API supporting thinking.type=disabled and enabled + budget_tokens):
    \(thinkingOffExample)
    3. “Give me a temperature slider from 0 to 1, set to 0.5 right now” (when supported by the model protocol):
    \(sliderExample)
    4. Turning user-provided nested vendor documentation into a reusable toggle preset (vendor_config is illustrative only):
    \(customExample)

    Inspecting exact-version client source code:
    When client-side merging or slider interpolation is unclear, call search_source_code for ModelRequestBodyControlCompiler, ModelRequestBodyControlSliderDescriptor or the protocol adapter, then read_source_file(path,start_line,end_line) in chunks of at most 240 lines per call using the returned line count to continue. Source tools are available only when the build embeds a full commit SHA—if unavailable, say so plainly and never pretend to have read source. Client source explains how ELS builds requests, not what a remote provider accepts.
    """
}

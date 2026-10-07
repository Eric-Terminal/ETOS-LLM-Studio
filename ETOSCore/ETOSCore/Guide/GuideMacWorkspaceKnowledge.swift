import Foundation

public enum GuideMacWorkspaceKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "macos-workspace",
            title: chinese ? "Mac 聊天与配置草稿" : "Mac Chat and Configuration Drafts",
            keywords: ["macOS", "Mac", "桌面", "stdio", "数据库", "草稿", "快捷键", "draft", "database"],
            content: chinese ? """
            Mac 聊天窗口左侧选择会话，右侧选择模型并输入消息；⌘N 新建会话，⌘Return 发送。附件通过系统文件选择器导入，正文与 Markdown 在后台准备。生成期间可以切换会话，工具调用继续使用 ETOSCore 的原生审批。右键消息可以复制、编辑或删除；编辑消息只修改历史，不执行其中的工具调用。消息正文不向页面向导公开。系统文件选择器属于系统页面，不提供配置向导。

            “设置”窗口按通用、模型管理、MCP 工具、上下文、数据管理和安全分组。提供商、模型、会话和 MCP 编辑器都保留草稿；向导确认仅更新这些编辑器的草稿，需要点击页面保存。模型编辑器的完成先返回提供商草稿，还需保存提供商。JSON 子页面返回时不直接保存；已有请求头、请求体与密钥对向导不可读，可以通过提案替换用户主动提供的新 JSON 对象。数据库配置在其他页面或同步中变化后，旧 MCP 草稿会拒绝覆盖，需重新打开。MCP 详情及单个工具设置则在确认后直接保存。切换前台窗口、页面、协议或锁定应用后，旧页面提案不再可执行。

            上下文中的记忆页可搜索激活或归档条目、选择嵌入模型并调整检索设置。记忆编辑器保存内容、分类、重要度、置信度、实体及归档草稿；已有条目在其他位置变化或被删除后，旧草稿不能覆盖。原文保存成功与嵌入生成成功分别处理，嵌入失败可以从数据维护页重试。全部重新嵌入必须由用户确认；向导仅能修改并发配置或编辑草稿。

            记忆的“导入与导出”可生成 Markdown 目录供阅读，或生成保留稳定 ID 与元数据的 .etosmemory 归档。导出后可分享或在 Finder 中显示；归档导入先预览新增、更新和冲突数量，用户手动确认才写入。核心会重新核对归档内容及本机条目，保留本机较新或同时间的冲突版本。传输页与确认页只向向导公开状态，不允许向导触发文件操作。

            “跨对话记忆与画像”管理启用条件、摘要专用模型、触发轮次、最小间隔、注入摘要数及画像日更。可查看摘要全文、删除单条或清空摘要，并编辑画像和查看结构化事实。编辑器的向导提案只改变草稿，保存时保留事实；画像在后台更新或被清空后，旧草稿需要重新打开。向导不能执行删除或清空；这些操作通过原生确认。

            数据管理可以保存与移动端兼容的 .elsbackup 数据库或完整快照，也可以配置 S3/R2 上传、浏览远端快照并下载后手动恢复。密码和对象存储凭据只写不可读。恢复前会结束聊天请求并暂停 MCP 连接，恢复不能与云同步或备份任务交错。iCloud 首次同步由用户选择数据来源，输入确认词后才进行完整覆盖，并沿用核心的覆盖前安全快照；过期确认不能用于新的同步裁决。向导可提议修改开关和导出草稿，不能上传、下载、运行同步或确认覆盖。

            工具问答显示在来源会话的输入区，侧栏问号表示有待回答的问题。单选的自由文本替代已有选项，多选可以同时保留选项和补充文字；必答项完成后才可提交。切换会话保留本次已填内容，答案和取消通知排队返回原会话，不覆盖普通输入草稿。工具审批可拒绝、补充提示、允许一次或设置持续允许；强制审批不提供持续允许。已完成的 Widget 结果使用独立网页显示，内联内容菜单可复制代码或当前页面文字、保存 PNG 或 HTML；导出操作仍需用户手动发起。

            macOS 的 stdio 使用本机 Process 的 stdin/stdout，command 是可执行文件，args 是逐项参数，不经 shell 展开。使用 node、uvx 等命令前自行安装相应依赖；需要 shell 语法时必须明确以 shell 作为 command。stdout 只用于逐行 JSON-RPC，诊断输出应写 stderr。cwd 为本机绝对路径；移动端默认 /home/etos 在 Mac 运行时映射到用户主目录，数据库值不改变。其他 Linux 路径不能自动变成 Mac 路径。连接 JSON 使用 kind=stdio、command、args、env、cwd；Streamable HTTP 使用 kind=streamable_http 与 endpoint；SSE 使用 kind=sse、messageEndpoint、sseEndpoint；OAuth 保留对应的认证字段。已有 environmentVariableIDs 保持引用，新 env 值保存为配置数据库中的环境变量记录。工作区和挂载字段属于移动端 Linux 配置，不能用来限制本机进程的文件访问。

            Mac 与 iOS/watchOS 复用数据库结构、配置编码和附件相对路径；Mac 数据目录为 Application Support/ETOS LLM Studio，不直接读写移动设备的沙盒。平台路径和本地执行环境需要分别配置。页面向导只能使用当前页面声明的工具，不能执行用户 MCP、系统命令或快捷指令，也不会从 JSON 编辑器读取已有秘密。
            """ : """
            Select a session in the Mac sidebar, choose a model and compose on the right. Command-N creates a session and Command-Return sends. Import attachments with the system file picker. Message and Markdown preparation runs in the background. Sessions can be switched during generation; ETOSCore still controls native tool approval. Right-click a message to copy, edit or delete it. Editing changes history without executing tool calls. Message content is hidden from the page guide. The system file picker has no app configuration guide.

            Settings contains General, Model Management, MCP Tools, Context, Data Management and Security. Provider, model, session and MCP editors keep drafts: confirming a guide proposal changes the draft, and Save commits it. Completing a model editor returns to the provider draft, which must also be saved. Returning from a JSON subpage does not save. Existing headers, request bodies and keys are unreadable to the guide; proposals may replace them with JSON objects the user supplies. A stale MCP draft cannot overwrite a configuration changed elsewhere. MCP detail and tool settings save directly after confirmation. Switching the foreground window, page or protocol, or locking the app invalidates old page proposals.

            Memory under Context searches active or archived items, selects an embedding model and configures retrieval. The editor saves drafts of content, kind, importance, confidence, entities and archive status. Stale drafts cannot overwrite changed or deleted items. Saving text and generating embeddings have separate outcomes; failed embeddings can be retried from Data Maintenance. Rebuilding all embeddings requires manual confirmation. The guide can only adjust concurrency or edit drafts.

            Memory Import and Export generates a readable Markdown directory or an .etosmemory archive preserving stable IDs and metadata. Share the result or reveal it in Finder. Import previews additions, updates and conflicts before manual confirmation. The core rechecks the archive and local items, retaining local versions with newer or equal timestamps. Transfer and confirmation pages expose read-only status to the guide, which cannot initiate file operations.

            Cross-Session Memory and Profile controls activation, the summary model, round threshold, minimum interval, injected summary count and daily profile updates. Read full summaries, delete one or clear all, edit the profile and inspect structured facts. Editor proposals only change the draft; saving preserves facts. Drafts opened before a background profile update or deletion must be reopened. The guide cannot delete or clear data; these actions require native confirmation.

            Data Management saves mobile-compatible .elsbackup database or full snapshots. Configure S3/R2 uploads, browse remote snapshots, then download and manually restore. Passwords and storage credentials are write-only. Restore ends chat requests and suspends MCP connections; it cannot overlap cloud sync or backup tasks. Initial iCloud sync requires choosing a source and typing the confirmation phrase before replacement, with a safety snapshot created by the core. An old confirmation cannot resolve a newer conflict. The guide may propose switch or export-draft changes but cannot upload, download, run sync or confirm replacement.

            Tool questionnaires appear in the originating session's composer; a question-mark icon identifies sessions awaiting an answer. Custom text replaces single-choice options and can accompany multiple selections. Required questions need an answer before submission. Switching sessions retains answers in progress. Answers and cancellations are queued for the source session without overwriting the ordinary composer draft. Tool approval offers rejection, an additional prompt, one-time approval and continuing approval; forced prompts do not offer continuing approval. Completed Widget results render in a separate web view. Inline content actions copy source code or current page text and save PNG or HTML, with exports initiated manually.

            On macOS, stdio uses a native Process with stdin/stdout. command is an executable and args contains literal arguments; no implicit shell expansion occurs. Install dependencies such as node or uvx yourself. Shell syntax requires an explicit shell command. stdout carries newline-delimited JSON-RPC; diagnostics belong on stderr. cwd must be an absolute Mac path. The mobile default /home/etos maps to the user home at runtime without rewriting the stored value; other Linux paths require manual adjustment. Connection JSON uses kind=stdio, command, args, env and cwd; Streamable HTTP uses kind=streamable_http and endpoint; SSE uses kind=sse, messageEndpoint and sseEndpoint. OAuth retains its authentication fields. Existing environmentVariableIDs remain references; new env values become database environment records. Mobile Linux workspace and mount fields do not restrict native process access.

            Mac reuses the mobile database schema, configuration encodings and relative attachment paths. Its data root is Application Support/ETOS LLM Studio; it does not directly access mobile sandboxes. Configure platform paths and local runtimes separately. The page guide uses only declared page tools and cannot run user MCP tools, shell commands or Shortcuts, or read existing secrets from JSON editors.
            """
        )
    }
}

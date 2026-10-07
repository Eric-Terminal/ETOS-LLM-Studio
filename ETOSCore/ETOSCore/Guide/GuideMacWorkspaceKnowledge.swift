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

            “设置”窗口按通用、模型管理、MCP 工具和安全分组。提供商、模型、会话和 MCP 编辑器都保留草稿；向导确认仅更新这些编辑器的草稿，需要点击页面保存。模型编辑器的完成先返回提供商草稿，还需保存提供商。JSON 子页面返回时不直接保存；已有请求头、请求体与密钥对向导不可读，可以通过提案替换用户主动提供的新 JSON 对象。数据库配置在其他页面或同步中变化后，旧 MCP 草稿会拒绝覆盖，需重新打开。MCP 详情及单个工具设置则在确认后直接保存。切换前台窗口、页面、协议或锁定应用后，旧页面提案不再可执行。

            macOS 的 stdio 使用本机 Process 的 stdin/stdout，command 是可执行文件，args 是逐项参数，不经 shell 展开。使用 node、uvx 等命令前自行安装相应依赖；需要 shell 语法时必须明确以 shell 作为 command。stdout 只用于逐行 JSON-RPC，诊断输出应写 stderr。cwd 为本机绝对路径；移动端默认 /home/etos 在 Mac 运行时映射到用户主目录，数据库值不改变。其他 Linux 路径不能自动变成 Mac 路径。连接 JSON 使用 kind=stdio、command、args、env、cwd；Streamable HTTP 使用 kind=streamable_http 与 endpoint；SSE 使用 kind=sse、messageEndpoint、sseEndpoint；OAuth 保留对应的认证字段。已有 environmentVariableIDs 保持引用，新 env 值保存为配置数据库中的环境变量记录。工作区和挂载字段属于移动端 Linux 配置，不能用来限制本机进程的文件访问。

            Mac 与 iOS/watchOS 复用数据库结构、配置编码和附件相对路径；Mac 数据目录为 Application Support/ETOS LLM Studio，不直接读写移动设备的沙盒。平台路径和本地执行环境需要分别配置。页面向导只能使用当前页面声明的工具，不能执行用户 MCP、系统命令或快捷指令，也不会从 JSON 编辑器读取已有秘密。
            """ : """
            Select a session in the Mac sidebar, choose a model and compose on the right. Command-N creates a session and Command-Return sends. Import attachments with the system file picker. Message and Markdown preparation runs in the background. Sessions can be switched during generation; ETOSCore still controls native tool approval. Right-click a message to copy, edit or delete it. Editing changes history without executing tool calls. Message content is hidden from the page guide. The system file picker has no app configuration guide.

            Settings contains General, Model Management, MCP Tools and Security. Provider, model, session and MCP editors keep drafts: confirming a guide proposal changes the draft, and Save commits it. Completing a model editor returns to the provider draft, which must also be saved. Returning from a JSON subpage does not save. Existing headers, request bodies and keys are unreadable to the guide; proposals may replace them with JSON objects the user supplies. A stale MCP draft cannot overwrite a configuration changed elsewhere. MCP detail and tool settings save directly after confirmation. Switching the foreground window, page or protocol, or locking the app invalidates old page proposals.

            On macOS, stdio uses a native Process with stdin/stdout. command is an executable and args contains literal arguments; no implicit shell expansion occurs. Install dependencies such as node or uvx yourself. Shell syntax requires an explicit shell command. stdout carries newline-delimited JSON-RPC; diagnostics belong on stderr. cwd must be an absolute Mac path. The mobile default /home/etos maps to the user home at runtime without rewriting the stored value; other Linux paths require manual adjustment. Connection JSON uses kind=stdio, command, args, env and cwd; Streamable HTTP uses kind=streamable_http and endpoint; SSE uses kind=sse, messageEndpoint and sseEndpoint. OAuth retains its authentication fields. Existing environmentVariableIDs remain references; new env values become database environment records. Mobile Linux workspace and mount fields do not restrict native process access.

            Mac reuses the mobile database schema, configuration encodings and relative attachment paths. Its data root is Application Support/ETOS LLM Studio; it does not directly access mobile sandboxes. Configure platform paths and local runtimes separately. The page guide uses only declared page tools and cannot run user MCP tools, shell commands or Shortcuts, or read existing secrets from JSON editors.
            """
        )
    }
}

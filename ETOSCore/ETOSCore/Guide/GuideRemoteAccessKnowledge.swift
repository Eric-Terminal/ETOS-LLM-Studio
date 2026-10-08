import Foundation

public enum GuideRemoteAccessKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "remote-file-access", title: chinese ? "远程文件访问与流量捕获" : "Remote File Access and Capture",
            keywords: ["远程", "调试", "捕获", "Bonjour", "HTTP", "WebSocket", "remote", "capture", "Mac"],
            content: chinese ? """
            Mac 的设置→拓展功能→远程文件访问会主动连接用户运行的电脑端调试服务。先在受信任的局域网启动配套服务，再从自动发现列表填入地址，或手动填写主机与端口；默认端口 7654。HTTP 轮询为默认模式，关闭后使用 WebSocket，失败时 Core 会回退 HTTP。选择发现结果只填写草稿，编辑地址或模式不会连接；原生“连接”按钮先保存地址再发起连接。连接失败可能按 Core 规则重试，需要停止时使用“断开”。HTTP 网络信任确认沿用现有原生流程。

            电脑端连接具有读取与修改应用数据的能力，仅连接自己信任的服务。Mac 使用 Application Support 下的应用数据目录，与 iOS/watchOS 的 Documents 根目录不同，但数据库格式相同。离开页面保留已请求的连接并停止服务发现；锁定、备份、其他数据维护及退出会断开并等待已接受操作收尾，恢复后不会自动重新连接。远程全量上传先接收至暂存目录，再进入工作区维护流程；提交开始后断开仍等待提交或回滚结束，不能用断开撤销已完成的修改。失败回滚保留的恢复目录需要人工处理，当前没有进程中断后的自动恢复。

            日志页显示本机内存中的连接记录，清空只清除这些日志。API 流量分析显示待处理捕获请求的模型、消息数量和时间；保存与忽略分别打开原生确认页。保存把捕获内容归档为聊天会话，不调用模型；忽略从队列移除该记录。确认绑定当时的请求标识和页面代次，断开或请求变化后不能作用于另一条记录。日志和捕获内容可能包含隐私，不属于向导可读数据。

            Mac 根页、日志页、捕获确认和独立介绍页分别声明向导。根页只暴露连接/处理状态与日志、队列数量；地址为不可读的连接草稿，协议开关可通过原生确认的提案修改。提案不会保存地址、连接服务器或执行远端命令，最终仍需用户点击连接；连接期间不提供草稿修改字段。向导不能扫描网络、连接、断开、读取日志、保存或忽略捕获，也不会获得普通聊天 MCP、快捷指令或远端文件操作能力。离页、切换模式、锁定和恢复使旧提案失效。

            普通上传、删除和新建目录不能修改聊天、配置、记忆与向量数据库及其 WAL/SHM/journal 文件，也不能删除包含它们的父目录。数据库内容修改使用 SQLite 调试工具，整体替换使用全量恢复；不要先清空再逐个上传数据库。下载受管理数据库会先在后台生成独立副本，保留现有加密格式和已提交的 WAL 数据；直接下载侧文件会被拒绝，完整下载清单会跳过它们。每个数据库分别导出，整目录下载不保证跨库和附件来自同一时刻。并发路径替换、业务迁移失败恢复和进程中断恢复仍需完善与运行验证，不能把文件传输当作已验证的完整备份恢复。
            """ : """
            On Mac, Settings → Extended Features → Remote File Access connects out to a companion debugging service you run. Start the service on a trusted local network, then fill the address from discovery or enter a host and port; the default port is 7654. HTTP polling is the default. Turning it off selects WebSocket, with Core falling back to HTTP on failure. Selecting a discovered service only edits the draft. The native Connect button saves the address and initiates the connection. Core may retry failed connections; use Disconnect to stop. HTTP trust approval uses the existing native flow.

            A connected debugging service can read and modify application data. Connect only to a service you trust. Mac uses the application's Application Support directory while iOS/watchOS use Documents, with the same database format. Leaving the page preserves a requested connection and stops discovery. Locking, backup, other data maintenance and quitting disconnect and wait for accepted work to finish; resuming does not reconnect automatically. Full uploads are staged before entering workspace maintenance. Once replacement begins, disconnect still waits for completion or rollback and cannot undo an already committed change. Retained recovery directories require manual handling; there is no automatic recovery after process interruption.

            The log page shows this client's in-memory connection records; clearing removes only those logs. API capture shows the model, message count and time of a pending request. Save and Ignore each open a native confirmation. Saving archives the captured content as a chat session without calling a model; ignoring removes it from the queue. Confirmation is bound to the request ID and page revision, so disconnecting or a changed request cannot affect another capture. Logs and captures may contain private content and are not readable by the guide.

            The Mac root, log, capture confirmation and introduction pages each declare guide context. The root exposes connection/processing status and log/queue counts. Its address draft is write-only and its protocol switch can be changed by a natively confirmed proposal. Proposals do not save the address, connect or execute remote commands: the user must still click Connect. Draft fields are unavailable while a connection is requested. The guide cannot scan, connect, disconnect, read logs, save or ignore captures, or gain ordinary chat MCP, Shortcut or remote file tools. Leaving, changing mode, locking and restoring invalidate stale proposals.

            Ordinary upload, delete and directory creation cannot modify the chat, configuration, memory or vector databases or their WAL/SHM/journal files, and cannot delete parent folders containing them. Use SQLite debugging tools to change database records and a full restore to replace databases; do not clear the directory and then upload databases individually. Downloading a managed database first creates an independent copy in the background, preserving its encryption format and committed WAL data. Direct sidecar downloads are rejected and full download lists skip them. Each database is exported separately, so a directory download does not provide one shared point in time across databases and attachments. Concurrent path replacement, recovery from business-schema migration failure and recovery after process interruption still need implementation and runtime validation. File transfer is not yet a verified full backup and restore workflow.
            """)
    }
}

import Foundation

public enum GuideRemoteAccessKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "remote-file-access",
            title: chinese ? "远程文件访问与流量捕获" : "Remote File Access and Capture",
            keywords: ["远程", "调试", "捕获", "Bonjour", "HTTP", "WebSocket", "remote", "capture", "Mac"],
            content: chinese ? """
            “远程文件访问”供进阶用户与开发者在受信任的局域网中，让 App 主动连接自己电脑上运行的配套调试服务，用于管理应用目录文件或排查 API 请求流量。在 Mac 上从“设置 → 拓展功能 → 远程文件访问”进入。

            怎么连接与断开：
            1. 先在同一局域网的受信任电脑上启动配套调试服务（默认端口 7654）。
            2. 在页面中从局域网自动发现（Bonjour）列表点选填入，或手动输入主机地址与端口。传输模式默认开启兼容性更好的 HTTP 模式，关闭后改用 WebSocket（连接受阻时会自动回退到 HTTP）。
            3. 点选发现结果、输入地址或切换模式都只是修改草稿，不会立即联网；只有亲自点击“连接”按钮，才会保存地址并发起连接（若使用明文 HTTP，会按常规流程弹出网络信任确认）。需要停止时随时点“断开”。
            4. 离开当前设置页不会挂断已经建立的连接；但锁屏、执行备份恢复或退出应用时会自动断开连接，恢复后不会自动重连。

            数据安全提醒与文件保护规则：
            • 请务必只连接你自己运行、完全信任的电脑服务！一旦连上，电脑端服务即可读取和修改应用数据目录（Mac 数据位于系统的 Application Support 应用目录下，iOS / watchOS 位于 Documents 目录下）。
            • 核心数据防误删保护：普通的单文件上传、删除和新建文件夹不允许直接覆盖或删改正在使用的聊天、配置、记忆、向量等核心数据文件及其所在上级目录。如需查看或导出这些数据，下载时会自动生成安全副本；如需整体替换应用数据，请使用专门的完整恢复功能（替换前会自动检查数据格式是否兼容，不兼容会自动退回原状），切勿尝试手动清空目录后再逐个上传文件，日常重要备份仍建议使用标准的 `.elsbackup` 快照备份。

            连接日志与 API 流量捕获：
            • 日志页：展示本次运行期间的连接状态记录，点“清空”只会清除这些内存日志。
            • API 流量分析：列出捕获到的待处理请求（包含模型名称、消息条数和时间）。点击“保存”经确认后可将该次捕获内容归档为一条本地聊天会话方便查阅（不会重新请求大模型）；点击“忽略”经确认后从待处理列表中移除。

            页面向导说明与隐私边界：
            • 在远程文件访问主页，向导只能看到当前的连接状态以及日志、待处理捕获的条数统计；连接地址为不可读草稿，日志详情与捕获到的对话内容均涉及隐私，绝不对向导公开。
            • 向导可以帮你提议填入新地址草稿或切换协议开关（需经你原生确认，且连接进行中不可修改草稿），但提案不会保存地址，也不会发起网络连接，最终仍需你手动点击“连接”。向导不能扫描局域网、连接、断开、查看日志，也不能替你保存或忽略流量捕获记录。
            """ : """
            Remote File Access lets power users and developers connect the app to a companion debugging service running on a trusted computer on your local network, making it easy to inspect app files or review captured API traffic. On Mac, open it from Settings → Extended Features → Remote File Access.

            How to connect and disconnect:
            1. Start the companion debugging service on a computer you trust on your local network (default port 7654).
            2. Pick a discovered local service (Bonjour) to fill in the draft, or type the host and port yourself. HTTP mode is enabled by default; turning it off uses WebSocket and falls back to HTTP automatically if needed.
            3. Picking a discovered entry or editing the address/protocol only updates the page draft—nothing connects until you click the native Connect button, which saves the address and starts the session (prompting for standard HTTP trust approval when applicable). Click Disconnect anytime to stop.
            4. Navigating away from the page keeps an active connection alive, while locking the app, running backup/restore maintenance or quitting disconnects cleanly and will not reconnect on its own afterward.

            Data safety and protected core files:
            • Connect only to a debugging service you run and trust, because an active session can read and modify files inside the app's data folder (`Application Support` on Mac, `Documents` on iOS and watchOS).
            • Active database protection: ordinary file uploads, deletions and folder actions are blocked from overwriting or deleting the live chat, configuration, memory and vector databases or their parent folders. Downloading a managed database safely exports a clean standalone copy in the background. To replace databases as a whole, use the full restore workflow (which checks compatibility first and rolls back on failure) rather than trying to clear folders and upload database files one by one; for everyday backups, prefer standard `.elsbackup` snapshots.

            Connection logs and API traffic capture:
            • Logs: shows in-memory connection events from the current session; Clear removes only those log entries.
            • API Traffic Capture: lists pending captured requests with their model name, message count and timestamp. Save (after native confirmation) archives the captured exchange as a local chat session without calling any model; Ignore removes it from the queue.

            Guide support and privacy boundaries:
            • On the Remote File Access root page, the guide sees only connection status plus log and capture queue counts. Your server address draft is write-only, and connection logs and captured payloads stay completely private.
            • While disconnected, a natively confirmed guide proposal can fill the address draft or toggle the protocol switch, but proposals never save the address or connect—you must still click Connect yourself. The guide cannot scan, connect, disconnect, read logs, save or ignore captures, or run remote file commands.
            """
        )
    }
}

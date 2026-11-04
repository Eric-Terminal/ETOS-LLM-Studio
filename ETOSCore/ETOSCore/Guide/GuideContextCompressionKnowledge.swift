import Foundation

public enum GuideContextCompressionKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "context-compression",
            title: chinese ? "上下文压缩与续聊" : "Context Compression and Continuations",
            keywords: ["压缩", "续聊", "摘要", "Token", "保留原文", "Mac", "compression", "continuation", "summary"],
            content: chinese ? """
            上下文压缩从完整当前分支与已有续聊交接中生成独立的新会话，不删除或改写原会话。最近轮次保留原文，其余内容一次生成摘要；音频、图片、视频和文件沿用 Core 的转写、视觉与内容提取能力，无法完整读取时应报错，不假装已处理。新会话的交接上下文独立保存并由 Core 注入后续请求，不受普通历史消息上限裁剪，备份与同步继续使用原数据库格式。

            三端摘要请求都严格使用手动选中的提供商和模型；选择失效或模型停用时明确报错，不自动改用其他账户。只有“自动选择”才依次尝试来源会话的首选模型、全局主聊天模型、第一个可用聊天模型。iPhone 与 Apple Watch 返回模型选择器或向导时保留已修改的选择，手表同时显示模型名与提供商以区分同名模型。开始压缩后选项锁定，避免显示的选择与正在执行的请求不一致。附件识别仍可能使用独立的视觉、语音或视频模型，其请求不等于最终摘要模型。

            iPhone 与 Apple Watch 的压缩选项页也独立接入向导，提供保留轮次、压缩模型和额外侧重点三个草稿字段，以及只读的来源会话、可用模型和选择规则。向导不能读取 API Key、开始压缩或代替用户创建会话；确认仅修改草稿，仍需手动创建。进入请求状态或离开页面后旧提案失效，手表向导保留来源上下文。

            Mac 从聊天输入区的“压缩为续聊”打开选项。临时会话、空白且没有交接的会话、生成或修改历史期间不能开始。保留轮次可选 0、2、4、6、10，模型可自动选择或使用已激活聊天模型，侧重点可留空。向导只能经原生确认修改这三个草稿字段，不能开始压缩、停止请求、保存会话、跳转或移除入口；仍需用户手动点击“创建续聊会话”。离页、切换会话、锁定或数据恢复使旧提案失效。介绍页独立声明只读上下文。

            原会话在压缩边界显示续聊入口，边界消息不再可见时入口移到顶部；续聊会话顶部可返回来源并查看摘要、保留原文和工具调用参数/结果。目标已删除时不能跳转，但可经原生确认移除入口。移除只隐藏当前方向的入口，不删除会话或交接；数据库仅更新一个标记，不覆盖同步来的正文和另一侧标记。详情和移除确认页的向导只读，不提供消息正文或执行工具的权限。

            Mac 的设置→上下文→上下文压缩控制提醒，沿用 contextCompression.reminder.enabled 和 contextCompression.reminder.tokenThreshold，修改立即保存；阈值规范到 1000–2000000。估算在后台针对完整分支和交接计算，不是服务端精确计费数。请求结束且达到阈值时，按会话、交接与阈值在本次运行中去重；刚创建且没有新消息的续聊不重复提醒。系统通知需要授权；点击只打开选项，不自动生成。冷启动先暂存通知目标，解锁后定位；目标删除后不会替换为别的会话。

            压缩和移除入口期间阻止并发修改历史。锁定与退出取消尚未提交的生成，已接受的数据库保存仍须收尾；取消或来源已变更后不自动导航。备份与恢复不得跨越正在写入的压缩任务，退出等待任务结束，恢复后丢弃旧通知和展示快照。磁盘读取、Token 估算与正文排版在后台执行，流式分片不反复读取关系。Mac 的工程接入、模型请求、通知与窗口行为仍须实际构建和运行验证。
            """ : """
            Compression creates an independent continuation from the complete current branch and any inherited handoff. It does not delete or rewrite the source. Recent rounds retain their original content; earlier history receives one summary. Core extracts readable audio, image, video and file content and reports unsupported attachments instead of silently omitting them. The handoff uses the existing database, backup and sync format and is injected into later requests independently of the ordinary history limit.

            On all three platforms, summary requests use the manually selected provider and model. A missing or disabled selection fails explicitly and never switches accounts. Only Automatic tries the source conversation's preferred model, then the main chat model, then the first available chat model. iPhone and Apple Watch preserve edits when returning from a picker or guide; Watch labels include the provider to distinguish identical model names. Options are locked during compression so they continue to describe the running request. Attachment recognition may still use separate vision, speech or video models rather than the final summary model.

            iPhone and Apple Watch options also declare their own guide context with retained rounds, compression model and focus as draft fields, plus read-only source session, available models and routing rules. The guide cannot read API keys, start compression or create a conversation. Confirmation changes the draft only; manual creation is still required. Starting a request or leaving invalidates old proposals. The Watch guide retains the source context.

            On Mac, open Compress to Continue beside the composer. Temporary chats, empty chats without a handoff, and conversations with active generation or history changes cannot start. Choose 0, 2, 4, 6 or 10 retained rounds, automatic or an activated chat model, and an optional focus. The guide can update only these three draft fields after native confirmation. It cannot generate, stop, save, navigate or remove links. Manual Create Continuation is required. Leaving the page, changing sessions, locking or restoring invalidates old proposals. The introduction has its own read-only context.

            The source displays a link at the compression boundary, or at the top if that message is no longer visible. The child offers the source link and a read-only handoff with summary, retained text and tool arguments/results. A deleted target cannot be opened, but its link can still be removed after native confirmation. Removal hides only that direction; it does not delete a session or handoff. The database updates one flag without overwriting synced text or the other flag. Detail and removal guides are read-only and do not expose message content or execute tools.

            Settings → Context → Context Compression uses contextCompression.reminder.enabled and contextCompression.reminder.tokenThreshold, saved immediately. Thresholds normalize to 1000–2000000. Background estimates cover the complete branch and handoff and are not exact billed counts. After generation ends, reminders deduplicate by session, handoff and threshold for this app run. A fresh continuation without new messages does not immediately remind again. System notifications require permission. A click opens options only; it never starts generation. Cold launches defer the target until unlock, and missing targets never redirect to another conversation.

            Compression and link removal exclude concurrent history mutations. Locking and termination cancel uncommitted generation; accepted database saves finish, but cancellation or a changed source prevents automatic navigation. Backup and restore cannot overlap these writes; termination waits for completion. Restore discards old notification intents and presentation state. Reads, token estimates and rich text preparation run in the background; streaming chunks do not repeatedly read relationships. Mac target integration, model requests, notifications and window behavior still require build and runtime verification.
            """)
    }
}

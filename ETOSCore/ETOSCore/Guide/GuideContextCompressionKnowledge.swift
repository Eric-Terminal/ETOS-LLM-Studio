import Foundation

public enum GuideContextCompressionKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "context-compression",
            title: chinese ? "上下文压缩与续聊" : "Context Compression and Continuations",
            keywords: ["压缩", "续聊", "摘要", "Token", "保留原文", "Mac", "compression", "continuation", "summary"],
            content: chinese ? """
            当一段对话越聊越长、响应变慢或消耗过多 Token 时，“上下文压缩（压缩为续聊）”可以帮你在不删改原对话的前提下，把早期的聊天记录提炼成一份精简摘要，同时完整保留最近几轮原话，生成一个新的续聊会话继续聊。新会话后续提问时会自动带上这份背景摘要和保留原话，不受普通历史消息条数截断的影响，也会随正常备份和同步一起保存。

            怎么使用“压缩为续聊”：
            • 入口位置：Mac 在聊天输入框旁点击“压缩为续聊”，iPhone 和 Apple Watch 从聊天快捷菜单点开（临时对话、空白新会话或模型正在回复时无法发起压缩）。
            • 三个可调选项：
              1. 保留最近轮次（可选 0、2、4、6、10 轮）：这些最近消息会原封不动带入新对话，更早的消息则合并提炼为一段摘要。
              2. 压缩模型：可设为“自动选择”（依次尝试来源会话的首选模型 → 全局主聊天模型 → 第一个可用聊天模型），也可手动指定某个已启用的聊天模型。注意：只要你手动选定了模型，请求就会严格发给该模型；如果它停用或失效会直接报错提醒，不自动改用其他账户。iPhone 和 Apple Watch 从模型列表或向导返回时会保留你刚改好的选择，手表同时显示模型名与提供商，方便区分同名模型。
              3. 额外侧重点（可留空）：告诉模型在总结时特别保留哪些关键细节（例如代码约束、角色设定或待办结论）。
            • 附件处理说明：如果历史消息里包含语音、图片、视频或文档，系统会先提取其中的可读内容再一起总结；此时附件识别仍可能使用独立的视觉、语音或视频模型，不一定等同于最终写摘要的聊天模型。若遇到无法读取的附件会明确提示，不会悄悄忽略。

            原对话与续聊会话之间的跳转管理：
            • 创建成功后，原对话会在压缩分界处显示跳往续聊的入口（若分界消息已被删改，入口会移到对话顶部）；续聊会话顶部则可以一键跳回来源对话，并随时点开查看摘要全文、保留的原话以及工具调用参数与结果。
            • 如果其中一侧的会话已经被删除，无法再跳转时可以手动确认移除该跳转条——移除只隐藏当前方向的入口，不会删除你的聊天会话，也不会清掉续聊里的背景摘要。

            长度提醒与通知设置：
            • 在“设置 → 上下文（或会话） → 上下文压缩”中可以开启压缩提醒，并设置 Token 提醒阈值（范围 1,000–2,000,000，修改立即保存）。
            • 这里的字数统计是针对当前对话分支的本地估算值（并非服务商精确账单）。当一轮回复结束且估算长度达到阈值时，每次运行期间会温和提醒一次；刚建好且还没有发新消息的续聊不会立刻重复提醒。
            • 开启系统通知后，点击提醒通知只会帮你打开压缩选项页，绝不会在后台自动扣费开始压缩。

            页面向导说明与安全边界：
            • 在 iPhone、Apple Watch 和 Mac 的压缩选项页，向导经你原生确认后只能帮你修改“保留轮次”、“压缩模型”和“额外侧重点”这三个草稿项；改好后仍需你亲自点击“创建续聊会话”才会真正发起请求。一旦开始压缩、切换会话或离开页面，未确认的旧提案就会自动失效。
            • 向导看不到你的 API Key 和聊天消息正文，不能开始压缩、不能停止请求、不能替你创建会话或移除跳转入口；续聊详情页、移除确认页与功能说明页对向导均为只读。
            """ : """
            When a conversation grows long and starts using too many tokens, Context Compression (Compress to Continue) lets you carry the discussion forward in a fresh continuation session—without deleting or altering your original chat. Your most recent turns are kept word-for-word, earlier turns are condensed into a clean summary, and future replies in the new chat automatically include that handoff context regardless of your ordinary history limit.

            How to set up a continuation:
            • Where to start: click Compress to Continue beside the composer on Mac, or open it from the chat quick actions menu on iPhone and Apple Watch (unavailable in Temporary Chats, empty chats or while a reply is actively streaming).
            • Three options you can customize:
              1. Retained rounds (0, 2, 4, 6 or 10): keeps those latest exchanges verbatim while summarizing older history.
              2. Compression model: choose Automatic (tries the source chat's preferred model → global main chat model → first available chat model) or pick a specific enabled model. Manual choices are strict—if the selected model is disabled or unavailable, compression reports an error and never switches accounts behind your back. iPhone and Apple Watch preserve edits when returning from the model picker or guide, and Apple Watch labels show both model and provider names so identical model names stay clear.
              3. Optional focus: tell the model what details matter most to preserve, such as code decisions, constraints or character state.
            • Attachments in history: readable audio, images, video and files are extracted before summarizing, reporting an error if an attachment cannot be read instead of silently dropping it. Attachment recognition may still use separate vision, speech or video models rather than the final summary model.

            Navigating between source and continuation chats:
            • The original chat shows a jump link right at the compression point (or at the top if that message is no longer visible), while the continuation chat lets you jump back to the source and inspect the summary, retained messages and literal tool call records anytime.
            • If the linked conversation was deleted, you can remove the broken banner after native confirmation; removing it hides only that direction's link without deleting any chat or handoff summary.

            Length reminders and notifications:
            • Open Settings → Context (or Conversation) → Context Compression to toggle reminders and set a token threshold (1,000–2,000,000; changes save immediately).
            • Token counts are local estimates rather than exact provider billing numbers. When a reply finishes past your threshold, the app reminds you once per session state during the current run, and a brand-new continuation waits until you send new messages before reminding again.
            • Clicking a system notification opens options only—it never starts model generation automatically.

            Guide support and manual boundaries:
            • On the compression options page across iPhone, Apple Watch and Mac, the guide can update only the three draft fields (retained rounds, model and focus) after native confirmation. Manual Create Continuation is still required to actually run the summary request, and leaving the page or switching chats invalidates stale proposals.
            • The guide never reads your API keys or conversation text, and cannot start or stop compression, navigate between chats or remove links; handoff detail, removal confirmation and introduction pages are strictly read-only.
            """
        )
    }
}

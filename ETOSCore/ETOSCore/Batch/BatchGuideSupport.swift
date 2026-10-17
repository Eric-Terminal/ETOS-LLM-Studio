import Foundation

public enum BatchGuideSupport {
    public static let documents = [GuideDocumentReference(id: "batch-tasks", title: "Batch Tasks")]

    public static func document() -> GuideDocument {
        GuideDocument(id: "batch-tasks", title: "批量任务", keywords: ["Batch", "批量", "JSONL", "异步", "取消", "重试", "多模型"], content: """
        设置→拓展能力→批量任务提供 OpenAI 兼容 Batch API。提供商必须支持 /files 与 /batches；普通聊天可用不代表 Batch 可用。新建页每个非空行是一条独立文本请求，可选择多个已启用的 OpenAI Chat Completions 或 Responses 模型，每个模型创建一个独立远端任务。请求不携带聊天历史、附件、MCP 或快捷指令，也不执行返回的工具调用。模型参数及当前全局温度、top-p 会在提交时固定；流式和跨请求会话续接被关闭。

        输入与模型选择是草稿。手表通过输入框逐条添加，请求列表可滑动移除；尚未添加的输入不会提交。向导只能经原生确认修改草稿字段，不能提交、取消、重试、删除、导出或授予通知权限。任务列表、详情、结果和介绍页只读；这些只读页面的快照不包含 API Key、请求正文或结果正文，编辑器仅公开当前草稿。离开页面后旧提案失效。

        Batch 在服务端异步处理，通常允许 24 小时完成，不能保证比普通聊天更快。支持范围、价格与额度由提供商决定。App 在前台恢复及活动期间低频刷新，失败后退避；系统挂起或退出后不会持续轮询。下次打开 App 或手动刷新时继续下载，不能保证关机期间及时通知。允许通知后，发现任务结束且结果保存成功时发送不含正文的本地通知。

        结果按 custom_id 对应原输入，成功与错误文件都保存；取消或过期也保留部分结果。只重试失败项会创建新的计费任务，原结果保留。下载中断可重新刷新；创建响应丢失时使用恢复提交查询服务端，绝不自动重复创建，未找到时需到提供商控制台核实。管理任务要求原地址、请求头及同一 API Key；任务不保存密钥明文。删除仅删除本地记录，不删除服务端文件；活动或尚未确认提交结果的任务不可删除。

        iOS、watchOS、macOS 共用任务格式与聊天数据库。手机／手表使用现有聊天库同步功能传递任务，需同时具备对应提供商和凭据；覆盖同步仍遵守原同步页面的确认和冲突规则。快照备份包含这些数据。iOS/macOS 可导出 JSONL，手表可同步到手机后导出。导出包含模型原始响应，分享前自行检查内容。

        Batch Tasks sends independent text requests through a provider's Batch API. Each selected model creates a separate job. Draft editing does not submit requests. Polling runs only while the application is active; completion notifications are delivered after a successful refresh and local save. Results, including partial failures, are retained in the chat database. Recovery checks remote metadata before retrying an uncertain submission. The guide cannot submit tasks or operate external tools.
        """)
    }
}

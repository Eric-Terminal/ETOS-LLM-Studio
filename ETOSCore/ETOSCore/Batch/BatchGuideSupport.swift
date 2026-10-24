import Foundation

public enum BatchGuideSupport {
    public static let documents = [GuideDocumentReference(id: "batch-tasks", title: "Batch Tasks")]

    public static func document() -> GuideDocument {
        GuideDocument(id: "batch-tasks", title: "批量任务", keywords: ["Batch", "批量", "JSONL", "异步", "取消", "重试", "多模型", "模型筛选", "多行请求", "按行添加"], content: """
        设置→拓展功能→批量任务提供 OpenAI 兼容 Batch API。iOS、watchOS 和 macOS 的设置首页不再单列批量任务，需先打开拓展功能。提供商必须支持 /files 与 /batches；普通聊天可用不代表 Batch 可用。候选模型仅表示已启用且接口格式兼容 OpenAI Chat Completions 或 Responses，未验证提供商的实际 Batch 权限。每个选中的模型创建一个独立远端任务。请求不携带聊天历史、附件、MCP 或快捷指令，也不执行返回的工具调用。模型参数及当前全局温度、top-p 会在提交时固定；流式和跨请求会话续接被关闭。

        三端新建页都以请求条目为单位；添加或点开条目进入独立编辑器，整段内容是一条请求，正文换行会保留，空白内容不能保存。只有用户选择“按行添加多条”时，才会把每个非空行作为一条请求，并在保存前显示条数。编辑器保存只加入内存草稿；取消不改已有条目。主页面支持移除条目，名称可留空。

        “选择模型”打开独立多选页，可按显示名、模型 ID 或提供商名称搜索，按提供商筛选，也可只看已选。选择使用勾选；全选或取消仅作用于当前显示的筛选结果，不影响其他已选模型。主页面只显示已选摘要。核对页列出全部目标模型、请求数和总次数：5 条请求 × 2 个模型会产生 2 个远端任务，共 10 次处理。必须手动点击提交；部分失败仍会返回已保存任务列表，显示成功及待处理数量，应打开失败任务处理而不是整批重发。

        向导页面分别是 batch-editor（名称可写，请求数量和已选模型只读）、batch-request-editor-请求ID（当前单条正文可写）、batch-request-import（按行导入文本可写）、batch-model-picker（搜索、提供商筛选、仅看已选及当前筛选结果的模型勾选可写）、batch-review（提交摘要只读）。请求编辑器和导入页的提案仅修改当前输入，需用户手动保存才加入主草稿。模型勾选直接改变内存草稿；不产生网络请求。所有写入经原生确认，离开页面后旧提案失效。向导不能保存输入、提交、取消、重试、删除、导出或授予通知权限。任务列表、详情、结果和介绍页只读；这些只读页面的快照不包含 API Key、请求正文或结果正文。

        Batch 在服务端异步处理，通常允许 24 小时完成，不能保证比普通聊天更快。支持范围、价格与额度由提供商决定。App 在前台恢复及活动期间低频刷新，失败后退避；系统挂起或退出后不会持续轮询。下次打开 App 或手动刷新时继续下载，不能保证关机期间及时通知。允许通知后，发现任务结束且结果保存成功时发送不含正文的本地通知。

        结果按 custom_id 对应原输入，成功与错误文件都保存；取消或过期也保留部分结果。只重试失败项会创建新的计费任务，原结果保留。下载中断可重新刷新；创建响应丢失时使用恢复提交查询服务端，绝不自动重复创建，未找到时需到提供商控制台核实。管理任务要求原地址、请求头及同一 API Key；任务不保存密钥明文。删除仅删除本地记录，不删除服务端文件；活动或尚未确认提交结果的任务不可删除。

        iOS、watchOS、macOS 共用任务格式与聊天数据库。手机／手表使用现有聊天库同步功能传递任务，需同时具备对应提供商和凭据；覆盖同步仍遵守原同步页面的确认和冲突规则。快照备份包含这些数据。iOS/macOS 可导出 JSONL，手表可同步到手机后导出。导出包含模型原始响应，分享前自行检查内容。

        Open Settings → Extensions → Batch Tasks on iOS, watchOS and macOS. Add and edit independent request entries; line breaks remain inside each request. Only Add Multiple Lines splits nonempty lines, with a count before Save. Search models by display name, model ID or provider, filter by provider or selected models, and select or deselect only the shown results. A compatible API format does not verify Batch availability. Review all selected models and the multiplied request count before submitting; each selected model creates a separate remote job. Partial submission failures return to the saved tasks so successful jobs are not duplicated.

        Guide contexts are declared separately for the editor, single-request editor, line import, model picker and read-only review. Confirmed request-text changes still require Save; model selections affect only the in-memory draft. The guide cannot save input, submit tasks or operate external tools. Polling runs only while the application is active; completion notifications follow a successful refresh and local save. Results, including partial failures, are retained in the chat database. Recovery checks remote metadata before retrying an uncertain submission.
        """)
    }
}

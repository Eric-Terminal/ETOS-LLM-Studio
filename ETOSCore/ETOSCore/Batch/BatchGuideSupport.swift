import Foundation

public enum BatchGuideSupport {
    public static let documents = [GuideDocumentReference(id: "batch-tasks", title: "Batch Tasks")]

    public static func document() -> GuideDocument {
        GuideDocument(
            id: "batch-tasks",
            title: "批量任务",
            keywords: ["Batch", "批量", "JSONL", "异步", "取消", "重试", "多模型", "模型筛选", "多行请求", "按行添加"],
            content: """
            批量任务适合把一批互不关联的问题一次性提交给支持 OpenAI Batch 接口的服务商在后台集中处理。在 iOS、watchOS 和 macOS 上，统一从设置→拓展功能→批量任务进入。请注意：普通聊天能用的服务商不一定开通了批量接口（需支持 /files 与 /batches），候选列表仅代表模型已启用且协议格式兼容 OpenAI Chat Completions 或 Responses。每条批量请求都是独立提问，不会附带聊天历史、文件附件、MCP 工具或快捷指令；提交时会固定当时的模型参数与全局温度、top-p，并自动关闭流式输出。

            怎么添加请求与选择模型：
            1. 单条添加与按行导入：新建任务时默认按条管理请求。点开单条编辑器输入的内容视为完整的一条提问，正文换行会保留，空白内容不能保存。只有点击“按行添加多条”时，才会把每一行非空文字拆分成一条独立请求，并在保存前提示拆分后的条数。单条编辑点保存后才会加入当前任务草稿，点取消不会改动已有条目；任务名称可以留空。
            2. 多选模型：点“选择模型”可按显示名称、模型 ID 或服务商名称搜索，也支持按服务商筛选或“仅看已选”。点击“全选”或“取消全选”只作用于当前筛选出来的列表，不会误改其他已勾选的模型。
            3. 核对与提交：核对页会清楚列出目标模型、请求条数与总处理次数——每个选中的模型都会创建一个独立的远端任务，例如 5 条请求 × 2 个模型会产生 2 个远端任务，共 10 次处理。核对无误后必须手动点击“提交”。若多个模型中有个别提交失败，已成功的任务仍会保留在任务列表里，只需点开失败项单独处理，不必整批重发。

            进度刷新、通知与结果管理：
            • 批量任务由服务商在云端异步处理，通常在 24 小时内完成，并不比普通对话更快；具体价格与额度以服务商规则为准。
            • App 在前台打开期间会自动刷新任务状态并下载已完成的结果，切到后台或关闭应用后不会持续联网轮询；下次打开 App 或手动刷新时会接着下载。开启系统通知后，一旦检测到任务结束且结果已保存到本机，会发送一条不含正文的完成提醒。
            • 成功回复与报错信息都会按原提问顺序一一对应展示；即使任务取消或过期，已完成的部分结果也会保留。你可以选择“仅重试失败项”（会创建新的计费任务，原有成功结果保留）。若提交瞬间网络中断，恢复机制会先向服务端核对任务信息，绝不会盲目重复创建任务。
            • 查询或管理远端任务需要保持原服务商地址、请求头以及同一把 API Key（任务记录本身不保存密钥明文）。删除任务只会移除本机记录，不会删除服务商云端文件；正在运行或尚未确认提交结果的任务不可删除。

            多设备同步与导出：
            • iOS、watchOS 与 macOS 共用同一套任务记录，保存在本地聊天数据库中。手机与手表可通过现有的聊天同步功能传递任务（接收端需配好对应的服务商与凭据），备份快照也会一并包含这些记录。
            • iOS 与 macOS 支持将结果导出为 JSONL 文件（手表可先同步到手机再导出）。导出文件包含模型的原始返回内容，分享给他人前请先自行检查。

            页面向导说明与安全边界：
            • 各页面的向导标识分别为：batch-editor（可改任务名称；请求条数与已选模型只读）、batch-request-editor-请求ID（可改当前单条请求草稿）、batch-request-import（可改按行导入草稿）、batch-model-picker（可改搜索词、服务商筛选、仅看已选开关及当前筛选结果的模型勾选）、batch-review（提交前核对页，只读）。
            • 向导提出的所有修改都必须经过你的原生确认；其中单条编辑与按行导入改完后，仍需你手动点“保存”才会合入主草稿，勾选模型则只更新当前页面草稿，不会直接联网发请求。离开当前页面后旧的修改建议自动失效。
            • 任务列表、详情、结果查看与说明页对向导均为只读，不包含你的 API Key、提问正文或回复正文；向导不能替你保存输入、提交任务、取消、重试、删除、导出或开启通知权限。

            Open Settings → Extensions → Batch Tasks on iOS, watchOS and macOS to submit independent prompts in bulk to OpenAI-compatible Batch services (/files and /batches). Line breaks stay inside each single request; only Add Multiple Lines splits nonempty lines and previews the count before Save. Filter models by name, model ID, provider or current selection—Select All applies only to the currently filtered results. Each selected model creates its own remote job, so review the multiplied total before manually clicking Submit. Partial submission failures still keep the jobs that succeeded so you never have to resend everything.

            Batch jobs run asynchronously on the provider's server (typically within 24 hours). The app refreshes progress while active in the foreground and sends a body-free local notification once results are saved locally. Recovery checks remote metadata before retrying an uncertain submission so jobs are not duplicated. Tasks live in the local chat database for backup and sync across devices, without storing plaintext API keys; iOS and macOS can export results as JSONL. Across batch-editor, single-request editors, batch-request-import, batch-model-picker and read-only batch-review, every guide change requires native confirmation, request edits still need manual Save, and the guide never reads your API keys, prompt text or results—nor can it submit, cancel, retry, delete or export jobs.
            """
        )
    }
}

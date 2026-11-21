import Foundation

public enum GuideStorageManagementKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(
            id: "storage-management",
            title: chinese ? "存储占用与文件浏览" : "Storage Usage and File Browser",
            keywords: ["存储", "文件", "缓存", "孤立数据", "SQLite", "storage", "files", "cache", "Mac"],
            content: chinese ? """
            “存储管理”帮你一目了然地查看应用占用了多少空间、直接浏览应用数据文件夹、预览文本/图片与数据库内容，或安全清理不再需要的残留文件。在 Mac 上可从“设置 → 数据管理（或同步与备份） → 存储管理”或“拓展功能 → 存储管理”进入（页面内也提供了本地工作区与外部目录管理入口）。

            空间统计与文件浏览：
            • 10 大统计分类：聊天会话、语音、图片、记忆、背景、配置、Skills、快捷指令、世界书、本地模型，其余未归类内容计入“其他文件”（Mac 的数据根目录位于系统 Application Support 下的应用文件夹，iOS / watchOS 位于 Documents 目录）。显示的大小为进入页面扫描时的结果。
            • 文件夹浏览与删除保护：在 Mac 上可逐层点开目录，支持单选或多选删除文件。请注意：**文件删除后不可恢复**，也不会自动修复聊天或角色里的关联引用；同时，正在运行使用的三个核心数据库（聊天、配置、记忆）及其上级目录受系统保护，无法在此直接删除——如需调整记录请前往对应功能管理页，或使用快照备份恢复。若待删文件在打开页面后发生过改动，系统会提示先刷新重选，防止误删新内容。

            本地文件与 SQLite 只读预览：
            • 文本文件按每页 100 行分页展示，图片直接在本地预览（不支持通过软链接跳出应用目录查看电脑外部文件）。
            • 点开 `.sqlite` 数据库文件，可以查看表与视图列表、字段结构以及每页 50 行的只读表格（超长单元格会先显示摘要，点开可分页阅读全文）。你还可以编写单条只读 SQL 语句（仅支持 SELECT、WITH 或 PRAGMA），但必须亲自点击页面上的“执行”按钮才会运行查询；离开页面后不会自动重复执行草稿。

            “清理缓存”与“清理孤立数据”的重要区别（操作前必看）：
            • 清理缓存：会一次性删除应用保存的**全部语音和图片文件**，其中可能包含历史聊天里的图片语音附件、角色头像以及角色卡素材，而不仅仅是临时缩略图！除非你确认不再需要这些媒体文件，否则请谨慎使用。
            • 清理孤立数据：安全清理没有消息的空会话记录、已无任何消息引用的残留语音/图片以及失效音频记录，同时**会完整保留**角色头像与角色素材。两项清理都需要你手动确认，完成后会展示实际清理结果（待发送输入框里未发出的附件也会一并清空）。

            页面向导说明与隐私边界：
            • 向导在存储管理及各级浏览页只能看到扫描状态、各分类字节大小与数量统计，绝对不会读取你的文件路径、文件名、文本图片正文或数据库里的具体记录。
            • 只有在 SQL 查询页，向导可以经你原生确认帮你草拟查询语句，但向导不能执行查询，仍需你手动点击执行；向导也不能读取文件内容、替你勾选要删除的文件或确认任何清理操作。
            """ : """
            Storage Management gives you a clear breakdown of how much disk space the app uses, lets you browse files inside the app's data folder, previews text, images and SQLite tables locally, and helps clean up leftover files. Open it from Settings → Data Management (or Sync & Backup) → Storage Management, or from Extended Features → Storage Management on Mac (which also links to workspace and external folder management).

            Space breakdown and file browser:
            • Ten tracked categories: Sessions, Audio, Images, Memory, Backgrounds, Configuration, Skills, Shortcuts, Worldbooks and Local Models, plus Other Files for anything else inside the app root (`Application Support` on Mac, `Documents` on iOS and watchOS). Sizes reflect the latest background scan.
            • Browsing and protected files: on Mac you can step into subfolders and delete single or multiple items. Keep in mind that **file deletion is permanent** and does not automatically fix references inside chats or cards. To keep your app working safely, the three live core databases (chat, configuration and memory) and their parent folders are protected from direct deletion—manage records from their dedicated settings pages or restore a snapshot instead. If any selected file changed on disk since you opened the folder, the app asks you to refresh before deleting, and symbolic links cannot be used to peek outside the app folder.

            Local file and read-only SQLite previews:
            • Text files load in 100-line pages and images preview locally.
            • Opening a `.sqlite` file shows its tables/views, column definitions and 50-row read-only pages (extra-long cells show a summary with full paged text on click). You can also draft a single read-only query (`SELECT`, `WITH` or `PRAGMA`), which always requires clicking the native Run button yourself; leaving the page never reruns a query automatically.

            Clear Cache vs. Clean Up Orphans (important difference):
            • Clear Cache: deletes **all stored audio and image files**, which can include chat attachments, character avatars and roleplay card assets—not just temporary files. Use it only when you are sure you no longer need local media.
            • Clean Up Orphans: safely removes empty session entries and unreferenced audio/image files while preserving character avatars and roleplay assets. Both actions require native confirmation, clear any unsent composer attachments and report actual cleanup counts when finished.

            Guide support and privacy boundaries:
            • Across Storage Management and its browser pages, the guide receives only scan status, category byte totals and item counts—never paths, filenames, file contents, database rows or raw error messages.
            • Only the SQL draft field can be updated via a natively confirmed guide proposal, and you must still click the native Run button yourself. The guide cannot run queries, read file contents, select files to delete or confirm storage cleanup.
            """
        )
    }
}

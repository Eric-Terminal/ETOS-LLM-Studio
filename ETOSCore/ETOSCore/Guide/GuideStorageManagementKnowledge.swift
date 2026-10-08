import Foundation

public enum GuideStorageManagementKnowledge {
    public static func document(locale: Locale = .current) -> GuideDocument {
        let chinese = locale.language.languageCode?.identifier == "zh"
        return GuideDocument(id: "storage-management", title: chinese ? "存储占用与文件浏览" : "Storage Usage and File Browser",
            keywords: ["存储", "文件", "缓存", "孤立数据", "SQLite", "storage", "files", "cache", "Mac"],
            content: chinese ? """
            存储管理复用 StorageUtility 的 10 个分类：聊天会话、语音、图片、记忆、背景、配置、Skills、快捷指令、世界书、本地模型；其他目录单独计入总量。Mac 根目录为应用的 Application Support，移动端仍使用 Documents，数据库格式不变。扫描在后台运行，大小是扫描时刻的结果；目录行只统计直接文件的大小。Mac 从设置→数据管理或拓展功能进入，也可进入已有工作区与外部挂载管理。

            Mac 目录支持逐级进入、单项和多选删除，其他文件只在根目录排除已知分类，子目录继续显示全部内容。符号链接不能用于预览应用目录外的文件。三个正在使用的主数据库（chat/config/memory）、WAL/SHM 及包含它们的目录不能直接删除；应使用相应管理页修改数据，或快照恢复。删除前核对修改时间、大小和文件身份，目标变化后必须刷新重选。删除文件和目录不可撤销，文件浏览器不自动修复其业务引用。

            文件正文在本机预览：文本按 100 行分页，图片在后台读取，SQLite 支持表/视图列表、字段结构以及每页 50 行只读结果。长单元格先显示摘要，可打开完整分页。只读查询只接受单条 SELECT/WITH/PRAGMA，必须用户点击执行；编辑 SQL 会清除旧结果，翻页沿用已执行的 SQL，离页或恢复后不会自动重放草稿。实时数据库可能在翻页之间改变，结果不是跨页一致快照。

            清理缓存删除所有语音和图片文件，可能包含会话附件、角色头像及素材，并非仅删除可重建文件。孤立清理按 Core 检查无消息的会话索引、无引用音频/图片和失效音频引用，保留角色头像及素材引用。孤立数量仅用于预估，确认时重新计算并报告实际结果。Mac 原生确认后复用数据维护屏障，暂停聊天、工具、Linux 与同步，等待写入和预览读取结束，然后清理并刷新工作区；待发附件会移除。关页或退出不截断已接受写入。锁定、数据替换和离页取消旧预览，数据库替换等待其后台读取实际结束。

            根页、目录、文件预览、数据库目录、表页、SQL 草稿、长单元格、清理确认和独立介绍各自声明向导。仅 SQL 草稿可经提案确认修改，仍需原生执行；其他页只读。快照只含扫描状态、分类字节和数量，不含路径、文件名、正文、数据库记录或错误原文；SQL 草稿会按普通页面字段提供。向导不能执行查询、读取文件正文、选择删除目标或确认清理。页面代次、语言、选择、锁定和恢复必须使旧提案失效。Mac 源码仍需工程接入及实际文件、键盘、恢复与退出验证。
            """ : """
            Storage Management reuses StorageUtility's ten categories: sessions, audio, images, memory, backgrounds, configuration, Skills, Shortcuts, worldbooks and local models. Other directories contribute to the total separately. Mac uses the app's Application Support directory; mobile keeps Documents and the database format is unchanged. Scans run in the background and show point-in-time sizes. Directory totals count immediate files only. Open the page from Settings → Data Management or Extended Features; existing workspace and external mount management is also linked.

            The Mac browser supports nested directories, single deletion and multiple selection. Other Files excludes known categories only at the root. Symbolic links cannot expose files outside the app root. The three active chat/config/memory databases, their WAL/SHM files and ancestor directories cannot be deleted directly; use their management pages or snapshot recovery. Deletion checks modification time, size and file identity; changed items require refresh and reselection. Deletion is irreversible and does not repair application references automatically.

            Previews stay local: text uses 100-line pages, images load in the background, and SQLite exposes tables/views, column declarations and 50-row read-only pages. Long cells show a bounded preview with full paged content available separately. Queries accept one SELECT/WITH/PRAGMA statement and require a native Run action. Editing SQL clears old results; paging uses the last executed SQL. Leaving or restoring never automatically reruns a query draft. Live databases can change between pages; this is not a multi-page snapshot.

            Clear Cache deletes all audio and image files, potentially including chat attachments, character avatars and assets, not only regenerable files. Orphan cleanup follows Core rules for session indexes without messages, unreferenced audio/images and invalid audio references; character avatar and asset references are preserved. Counts are estimates; confirmation recalculates and reports actual results. Mac cleanup uses the existing data maintenance barrier to pause chat, tools, Linux and sync, drain writes and preview reads, then clean and refresh the workspace. Pending attachments are removed. Leaving or quitting does not interrupt accepted writes. Locking, replacement and leaving invalidate previews; database replacement waits for their actual background completion.

            Root, directory, file preview, database catalog, table, SQL draft, long cell, confirmation and introduction pages each declare guide context. Only the SQL draft is writable through a confirmed proposal; native execution is still required. Other pages are read-only. Snapshots expose status, category bytes and counts, never paths, filenames, file contents, database records or raw errors; the SQL draft is a normal page field. The guide cannot execute queries, read file contents, select deletion targets or confirm cleanup. Page revisions, language, selection, lock and restore invalidate stale proposals. Mac target integration and actual file, keyboard, restoration and termination behavior remain to be verified.
            """)
    }
}

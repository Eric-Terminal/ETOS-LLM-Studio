# macOS 工程接入记录

本文件记录原生 Mac 源码的接入条件。当前尚未创建 Mac target/scheme，也没有运行构建或测试；不能据此认定客户端已可发布。工程文件需在完整 Xcode 环境恢复后通过 Xcode 配置，不手工改写 `.xcodeproj`。

## Target 与源码

- 在现有 workspace 内新增 macOS App target，使用 SwiftUI 生命周期，入口为 `ETOS LLM Studio/ETOS LLM Studio macOS App/ETOSMacApp.swift`。添加该目录全部 Swift 文件；不要同时加入移动端的 `@main` 入口或整个移动端 Views 目录。
- Mac 最低系统与 ETOSCore 的现有配置保持一致：macOS 26.0。语言模式先与核心保持 Swift 5；默认 actor 隔离使用 `nonisolated`，界面模型已显式标注 `@MainActor`。不要照搬移动端 target 的 `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`，否则后台展示数据的静态方法会变成主执行器隔离。
- 添加 workspace 内的 ETOSCore framework target 依赖与嵌入签名。ETOSCore 使用同步文件夹，新加入的 Core Swift 文件仍需确认 Target Membership；Mac App 文件夹需要单独绑定新 target。
- 复用既有第三方依赖版本，不创建 `Package.swift`。重点核实 SQLCipher、llama.cpp、iSH runtime 的 macOS 架构切片及链接条件；不能把 iOS 模拟器产物当作原生 macOS 产物。
- Mac App 的 `PRODUCT_MODULE_NAME` 使用 `ETOS_LLM_Studio_macOS_App`；新增相应的 macOS 单元测试 target，加入 `ETOS LLM Studio/ETOS LLM Studio macOS AppTests` 中的测试源码。该测试目录不加入 App target。

## 资源与签名

- Mac target 共享 iOS 目录下八种 `*.lproj/Localizable.strings`，保持 `en` 为开发语言。不复制第三份本地化表；本次新增文案已同步到 iOS/watchOS 资源。
- 共享需要的图片、字体、默认配置、许可证和向导源码包。检查 iOS 的资源构建步骤后逐项选择，不直接复制移动端 Info.plist、扩展、Watch App 或移动端 entitlements。
- 新建独立的 Mac bundle identifier 和对应的签名配置。iCloud 如要读取现有云端容器，继续使用项目现有容器 `iCloud.com.ericterminal.els`，并在开发者账号中为 Mac App 启用所需能力。钥匙串访问组和 App Group 必须与实际签名配置匹配。
- 本机 stdio 需要运行用户安装的可执行文件及访问其依赖。当前实现面向具有这些权限的原生桌面进程；启用 App Sandbox 后不能假定任意 `node`／`uvx` 程序及其数据路径均可访问。发布签名与沙盒策略确定后需实际验证，不能用移动端 Linux 的 workspace/mount 字段充当本机隔离措施。
- 按最终启用的 Mac 能力补充系统权限用途说明及相应本地化，例如麦克风、相机、照片、联系人、日历、提醒事项、位置和本地网络。尚未完成桌面接入的功能不能仅凭复制用途说明就宣称可用。

## 数据兼容与验证

Mac 根目录为 `Application Support/ETOS LLM Studio`，通过 `StorageUtility.documentsDirectory` 获取。数据库 schema、文件名、提供商/MCP 编码及附件相对路径继续共用 ETOSCore，不建立独立的 Mac 数据库版本。

工具链恢复并获得明确授权后，需要分别构建和测试。新 Mac scheme 的具体命令应在 target 创建后确定，当前不提供一个不存在的 scheme 命令。已有 iOS/watchOS 的构建和测试命令继续以仓库 AGENTS.md 为准，编译授权与测试授权分开。

待验证项目包括：

1. 从移动端完整备份恢复未加密和加密数据库，核对会话、模型、密钥条目、MCP 环境引用和媒体相对路径；Mac 修改后的备份再回到移动端核对。
2. MCP stdio 完整握手、工具目录和调用、超时与取消、stderr 分离、空闲退出和后台退出；使用本机实际安装路径检查 argv 和环境变量。
3. 多会话生成、流式滚动、消息编辑关联结果、切换窗口和锁定后的审批、HTTP/证书原生弹窗、向导草稿确认及页面失效。
4. ETOSCore 新增的 `MCPConfigurationPersistenceTests`、`CloudSyncLocalRestoreTests`、此前 Mac stdio/图片/存储目录测试；当前都只有测试源码，未执行。
5. 系统保存面板的文件权限、覆盖已有快照、加密快照导入、S3/R2 列表及取消下载、恢复时后台任务隔离、首次 iCloud 裁决及过期确认；iCloud 还需配置容器、签名和通知能力。
6. 工具问答的必填、单选/多选、自由文本、跨会话排队及补充发送；Widget 的交互 DOM、复制、PNG/HTML 保存和链接。Core 已有 `ToolInteractionPresentationTests` 源码，Mac 有 `MacQuestionnaireModelTests` 源码；原生 UI 自动化与 WebKit 实机检查须在 target 接入后补做。
7. 记忆草稿保存、并发编辑与已删除条目保护、重新嵌入进度及单条重试。`MemoryDraftWriteTests` 检查写入结果、旧版本与空白草稿；尚未运行。原生编辑器和数据库恢复期间的后台嵌入任务仍需集成验证。
8. 记忆 Markdown 目录与 `.etosmemory` 归档导出、Finder 定位和分享、文件选择器授权、导入预览及冲突保留。核心继续使用既有 `MemoryGovernanceTests` 中的归档验证用例；本次未改动归档格式和导入策略，也未运行这些测试。Mac 文件面板和跨端往返需在 target 创建后验证。
9. 跨对话摘要开关、专用模型、触发参数与画像编辑、事实查看和清空确认。`ConversationMemoryManagerTests` 补充空白草稿、并发保存、旧画像和已删除画像的版本保护，尚未运行；应验证自动更新时编辑器报错及切换页面后的向导失效。

目前源码包含聊天、附件、会话草稿、提供商/模型/MCP 基础配置、快照备份恢复、S3/R2 与 iCloud 同步管理、工具问答与 Widget、记忆编辑、嵌入维护、归档传输、跨对话摘要与画像和向导入口。完整功能对齐仍在继续，角色扮演、世界书、Agent/浏览器、MCP 资源和提示词、高级模型配置等不能据此视为完成。

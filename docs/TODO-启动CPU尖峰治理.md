# 启动 CPU 尖峰治理 TODO

## 目标
- 消除 iOS/watchOS 启动后每隔数秒出现的 CPU 周期性尖峰。
- 将高频路径从“轮询 + 大 JSON 解码”改为“数据库变更驱动 + 按需查询”。

## MCP（优先）

### 阶段一：关系化拆表（已完成）
- [x] 在 `config-store.sqlite` 建立 `mcp_servers` 表。
- [x] 在 `config-store.sqlite` 建立 `mcp_tools` 表，并配置 `ON DELETE CASCADE`。
- [x] 提供 GRDB Record 映射（`FetchableRecord` / `PersistableRecord` / `TableRecord`）。
- [x] 自动迁移旧 `mcp_servers_records_v1`（Blob / JSON 文件）到关系表。

### 阶段二：移除轮询（已完成）
- [x] 删除 `MCPManager` 中 `ConfigWatcher` 的定时轮询逻辑。
- [x] 使用 `ValueObservation` 监听 `mcp_servers + mcp_tools` 签名变化。
- [x] 仅在数据库真实写入变更时触发 `reloadServers()`。

### 阶段三：按需查询（已完成）
- [x] 新增 `MCPServerStore.loadTools(for:)`，直接查询 `mcp_tools`。
- [x] 在工具中心界面链路上优先使用 `loadTools(for:)`，避免无关字段解码。
- [x] 为资源/提示词提供同类按需读取 API（`loadResources/loadResourceTemplates/loadPrompts/loadRoots/loadServerInfo`）并接入关键调用点。

## 非 MCP（后续排查）
- [x] 盘点仍存在“定时检查 + 大对象解码”的模块（Provider/Worldbook/Feedback 等）。
- [x] Provider 配置改为关系表读写（`providers` / `provider_models` / `provider_model_capabilities` 等），并清理旧 Blob。
- [x] Worldbook 改为关系表读写（`worldbooks` / `worldbook_entries` / `worldbook_entry_keys` / metadata），并清理旧 Blob。
- [x] ShortcutTools 改为关系表读写（`shortcut_tools` / `shortcut_tool_metadata`），并清理旧 Blob。
- [x] FeedbackTickets 改为关系表读写（`feedback_tickets`），并清理旧 Blob。
- [x] Memory 原始记忆改为关系表读写（`memory_items`），并清理旧 Blob。
- [x] Conversation 用户画像改为关系表读写（`conversation_user_profile`），并清理旧 Blob。
- [ ] 对高频路径补充 Instruments 基线（主线程占比、JSON 解码耗时、DB 读次数）。
- [ ] 对仍存在轮询热点的模块继续推进 ValueObservation（若后续定位到新热点再落地）。

## 验收标准
- [ ] watchOS 启动后 60 秒内不再出现固定周期的 JSON 解码尖峰。
- [ ] `MCPManager.processConfigWatcherTick` 不再出现在调用栈中。
- [ ] `MCPToolDescription.init(from:)` 不再在空闲期高频出现。

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

### 阶段三：按需查询（进行中）
- [x] 新增 `MCPServerStore.loadTools(for:)`，直接查询 `mcp_tools`。
- [ ] 在工具中心界面链路上优先使用 `loadTools(for:)`，避免无关字段解码。
- [ ] 为资源/提示词提供同类按需读取 API（仅在确有调用点时落地）。

## 非 MCP（后续排查）
- [ ] 盘点仍存在“定时检查 + 大对象解码”的模块（Provider/Worldbook/Feedback 等）。
- [ ] 对高频路径补充 Instruments 基线（主线程占比、JSON 解码耗时、DB 读次数）。
- [ ] 对确认热点模块复用同样策略：关系化 + ValueObservation + 按需查询。

## 验收标准
- [ ] watchOS 启动后 60 秒内不再出现固定周期的 JSON 解码尖峰。
- [ ] `MCPManager.processConfigWatcherTick` 不再出现在调用栈中。
- [ ] `MCPToolDescription.init(from:)` 不再在空闲期高频出现。

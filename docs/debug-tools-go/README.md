# ETOS LLM Studio 调试工具（Go 版）

这是面向电脑端精细化调试的 Go 版工具，启动后默认进入 Bubble Tea TUI，同时保留同源 WebUI。

## 为什么要有 Go 版

- 用户机器没有 Python 环境也能直接运行
- 单文件可执行程序，下载即用
- 可通过 GitHub Actions 自动跨平台编译并发布 Release

## 功能覆盖

- WebSocket 调试通道（推荐）
- HTTP 轮询调试通道（备用）
- OpenAI 兼容请求导入代理（`/v1/chat/completions`）
- Bonjour/mDNS 自动发现（服务类型 `_etos-debug._tcp`）
- Bubble Tea TUI：文件、提供商、会话、记忆、SQLite 统一操作
- 内置 Web GUI 控制台（同源 API，无 CORS）
- SQLite 调试 API：列出 chat/config/memory 数据库表、执行只读查询与受保护写入
- 与现有 iOS/watchOS 设备端协议兼容（命令字保持一致）

## 本地运行

```bash
cd docs/debug-tools-go
go run .
```

启动后会直接进入 TUI。按 `Tab` 切换模块，按 `r` 刷新当前模块，按 `Esc` 返回侧栏或取消输入，按 `Ctrl+C` 退出。会话列表会显示提示词、世界书、标签与隔离等信息摘要；会话页按 `Enter` 进入气泡预览，`↑/↓` 选择消息气泡，再按 `Enter` 查看更多，`Esc` 会按层级返回。Provider 页支持 `a` 新增 Provider、`e` 编辑 Provider、Header Overrides 与独立代理、`m` 新增模型、`M` 选择并编辑已有模型参数。

默认只监听一个端口：

- 调试服务: `7654`
- WebUI/API/HTTP 轮询: `http://电脑IP:7654`
- WebSocket: `ws://电脑IP:7654/ws`
- OpenAI 兼容导入代理: `http://电脑IP:7654/v1/chat/completions`
- Bonjour/mDNS: `_etos-debug._tcp`（发布同一个调试服务端口）

### Web GUI 控制台

启动后可直接打开：

```bash
http://127.0.0.1:7654/
```

GUI 主要功能：

- Finder 风格文件浏览（左侧目录树 + 中间目录列表 + 右侧预览区）、文本/JSON/图片预览、上传/下载/删除
- 提供商配置表单化编辑（Provider、API Key、Header Overrides、独立代理、模型类型、模态、能力、请求体覆盖、Override Parameters 与 Pricing），也保留 JSON 高级编辑入口
- 会话列表、会话元数据编辑、消息表单/JSON 双模式高级编辑
- 记忆列表编辑与重嵌入触发
- SQLite 表结构浏览、查询与写入 API
- OpenAI 捕获队列查看与保存/忽略
- 关键写操作默认二次确认（删除、覆盖保存、会话/记忆保存等）
- `/api/*` 错误响应统一带 `error_code`（如 `INVALID_ARGS`、`NOT_FOUND`、`TIMEOUT`、`DEVICE_DISCONNECTED`）

连接策略：

- 设备端会优先通过 Bonjour 自动发现电脑端服务并询问是否填入地址；仍可手动输入 IP。
- 设备端可优先走 WebSocket，若连接失败会自动回退 HTTP 轮询；两种模式共用 `7654` 端口。

### 自定义端口

```bash
go run . <port>
```

例如：

```bash
go run . 7654
```

### 调试日志开关

默认关闭详细日志，避免后台连接日志打乱 TUI。需要排查协议时可用环境变量开启：

```bash
ETOS_DEBUG_MODE=true go run .
```

## HTTP API

WebUI 和 TUI 共用同一组服务端能力。常用 SQLite API：

- `GET /api/app-config?query=...`：列出 `app_config` 配置键、类型、当前值、默认值与同步属性
- `POST /api/app-config/set`：参数 `key`、`value`，按配置原始类型写入单项设置
- `POST /api/providers/upsert`：按 `provider_id` 更新或按 `name` 新增 Provider，可写入 `base_url`、`api_key`、`api_format`、`header_overrides`、`proxy_configuration` 等字段
- `POST /api/providers/models/upsert`：按 `provider_id` 为指定 Provider 新增或更新模型，可写入 `model_name`、`display_name`、`kind`、`input_modalities`、`output_modalities`、`capabilities`、`request_body_override_mode`、`raw_request_body_json`、`override_parameters`、`request_body_controls` 与 `pricing`
- `POST /api/sqlite/tables`：参数 `database` 为 `chat`、`config` 或 `memory`，可选 `include_internal`、`include_create_sql`
- `POST /api/sqlite/query`：参数 `database`、`sql`，可选 `parameters`、`max_rows`
- `POST /api/sqlite/mutate`：参数 `database`、`sql`，可选 `parameters`、`allow_without_where`、`returning_max_rows`

写入 SQL 默认只允许 `INSERT/UPDATE/DELETE/REPLACE`，且 `UPDATE/DELETE` 必须带 `WHERE`，除非显式传入 `allow_without_where=true`。

## 构建二进制

```bash
cd docs/debug-tools-go
go build -o etos-debug-server-go
```

当前 Charmbracelet TUI 依赖要求 Go 1.24.2 或更新版本；Release CI 会按 `go.mod` 自动安装对应 Go 版本。

## 回归测试

```bash
cd docs/debug-tools-go
go test ./...
```

当前已覆盖：

- 命令发送在无 WebSocket 时自动入队（HTTP 轮询回退路径）
- `sendCommandWithResponse` 的 request_id 关联、超时清理
- `/api/*` 错误码推断与 HTTP 状态码映射
- 典型接口参数校验（如文件读取缺少 path）
- app_config 设置接口参数校验与命令转发
- Provider 与模型 upsert 接口参数校验、命令转发，以及 TUI 模型高级编辑 payload 生成
- SQLite API 参数校验与命令转发

## Release 下载（CI）

仓库提供了 GitHub Actions 工作流：

- 文件：`.github/workflows/debug-tools-go-release.yml`
- 触发：推送 tag `debug-tools-go-v*`

示例：

```bash
git tag debug-tools-go-v0.1.0
git push origin debug-tools-go-v0.1.0
```

CI 会自动构建多平台压缩包并附加到 GitHub Release。

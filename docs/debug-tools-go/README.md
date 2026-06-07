# ETOS LLM Studio 调试工具（Go 版）

这是面向电脑端精细化调试的 Go 版工具，启动后默认进入 Bubble Tea TUI，同时保留同源 WebUI。

## 为什么要有 Go 版

- 用户机器没有 Python 环境也能直接运行
- 单文件可执行程序，下载即用
- 可通过 GitHub Actions 自动跨平台编译并发布 Release

## 功能覆盖

- WebSocket 调试通道（推荐）
- HTTP 轮询调试通道（备用）
- OpenAI 请求捕获代理（`/v1/chat/completions`）
- Bonjour/mDNS 自动发现（服务类型 `_etos-debug._tcp`）
- Bubble Tea TUI：文件、提供商、会话、记忆、SQLite、OpenAI 捕获统一操作
- 内置 Web GUI 控制台（同源 API，无 CORS）
- SQLite 调试 API：列出 chat/config/memory 数据库表、执行只读查询与受保护写入
- 与现有 iOS/watchOS 设备端协议兼容（命令字保持一致）

## 本地运行

```bash
cd docs/debug-tools-go
go run .
```

启动后会直接进入 TUI。按 `Tab` 切换模块，按 `r` 刷新当前模块，按 `Esc` 退出。

默认端口：

- WebSocket: `8765`
- HTTP 轮询: `7654`
- HTTP 代理: `8080`
- Bonjour/mDNS: `_etos-debug._tcp`（发布 HTTP 端口，并在 TXT 中附带 WebSocket 与代理端口）

### Web GUI 控制台

启动后可直接打开：

```bash
http://127.0.0.1:7654/
```

GUI 主要功能：

- Finder 风格文件浏览（左侧目录树 + 中间目录列表 + 右侧预览区）、文本/JSON/图片预览、上传/下载/删除
- 提供商配置 JSON 可视化编辑（含快捷新增）
- 会话列表、会话元数据编辑、消息表单/JSON 双模式高级编辑
- 记忆列表编辑与重嵌入触发
- SQLite 表结构浏览、查询与写入 API
- OpenAI 捕获队列查看与保存/忽略
- 关键写操作默认二次确认（删除、覆盖保存、会话/记忆保存等）
- `/api/*` 错误响应统一带 `error_code`（如 `INVALID_ARGS`、`NOT_FOUND`、`TIMEOUT`、`DEVICE_DISCONNECTED`）

连接策略：

- 设备端会优先通过 Bonjour 自动发现电脑端服务并询问是否填入地址；仍可手动输入 IP。
- 设备端可优先走 WebSocket，若连接失败会自动回退 HTTP 轮询（默认端口 `7654`，也支持 `host:wsPort:httpPort` 双端口地址格式）。

### 自定义端口

```bash
go run . <ws_port> <http_poll_port> <proxy_port>
```

例如：

```bash
go run . 8765 7654 8080
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

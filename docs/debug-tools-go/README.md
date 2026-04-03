# ETOS LLM Studio 调试工具（Go 版）

这是 `docs/debug-tools/debug_server.py` 的 Go 可执行版。

## 为什么要有 Go 版

- 用户机器没有 Python 环境也能直接运行
- 单文件可执行程序，下载即用
- 可通过 GitHub Actions 自动跨平台编译并发布 Release

## 功能覆盖

- WebSocket 调试通道（推荐）
- HTTP 轮询调试通道（备用）
- OpenAI 请求捕获代理（`/v1/chat/completions`）
- 交互式菜单：列目录、上传、下载、删除、批量同步
- 内置 Web GUI 控制台（同源 API，无 CORS）
- 与现有 iOS/watchOS 设备端协议兼容（命令字保持一致）

## 本地运行

```bash
cd docs/debug-tools-go
go run .
```

默认端口：

- WebSocket: `8765`
- HTTP 轮询: `7654`
- HTTP 代理: `8080`

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
- OpenAI 捕获队列查看与保存/忽略
- 关键写操作默认二次确认（删除、覆盖保存、会话/记忆保存等）
- `/api/*` 错误响应统一带 `error_code`（如 `INVALID_ARGS`、`NOT_FOUND`、`TIMEOUT`、`DEVICE_DISCONNECTED`）

连接策略：

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

默认开启详细日志，可用环境变量关闭：

```bash
ETOS_DEBUG_MODE=false go run .
```

## 构建二进制

```bash
cd docs/debug-tools-go
go build -o etos-debug-server-go
```

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

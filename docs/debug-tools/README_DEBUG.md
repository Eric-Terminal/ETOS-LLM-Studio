# ETOS LLM Studio - 反向探针调试系统

## 🎯 问题与解决方案

**问题**: watchOS 禁止大多数 App 作为服务器监听端口 ([TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos))

**解决方案**: 反向探针架构 - 设备主动连接电脑，通过 WebSocket 接收命令

## 🏗️ 架构

```
┌─────────────┐                      ┌─────────────┐
│  Watch/iOS  │  WebSocket 客户端    │   电脑端    │
│   设备端    │ ──────────────────> │  WS服务器   │
│             │  主动连接             │             │
│ - 文件操作  │ <────────────────── │ - 菜单界面  │
│ - OpenAI捕获│  接收命令/发送结果   │ - 代理转发  │
└─────────────┘                      └─────────────┘
```

## 🚀 快速开始

### 1. 电脑端设置

**安装 Python 依赖:**

打开终端/命令提示符，进入 `docs/debug-tools` 目录，运行：

```bash
pip3 install -r requirements.txt
```

或使用 pip (Windows):

```bash
pip install -r requirements.txt
```

**启动服务器:**

```bash
python3 debug_server.py
```

或 (Windows):

```bash
python debug_server.py
```

**自定义端口:**

```bash
python3 debug_server.py 8765 8080
```

第一个参数是 WebSocket 端口(默认8765)，第二个是 OpenAI 代理端口(默认8080)。

### 2. 设备端设置

在 Watch/iPhone 上:
1. 打开 App 的本地调试界面
2. 输入服务器地址，格式: `192.168.1.100:8765`
   - 可通过网络设置或 `ipconfig`(Windows)/`ifconfig`(macOS/Linux) 查看电脑IP
   - 端口号与启动服务器时指定的 WebSocket 端口一致
3. 点击「连接」

### 3. 功能说明

**文件管理:**
- 📂 列出目录
- 📥 下载文件
- 📤 上传文件  
- 🗑️ 删除文件/目录
- 📁 创建目录

**OpenAI 请求捕获:**
1. 设置 OpenAI API Base URL 为: `http://电脑IP:8080`
2. 发送请求时会自动捕获
3. 设备上弹出确认，选择是否保存到会话

## 📝 使用示例

### 电脑端操作

```
📱 设备 192.168.1.100 - ETOS LLM Studio 调试控制台
============================================================
1. 📂 列出目录
2. 📥 下载文件
3. 📤 上传文件
4. 🗑️  删除文件/目录
5. 📁 创建目录
6. 🔄 刷新连接
0. 🚪 退出
============================================================
请选择操作 [0-6]: 1
输入路径 (默认 .): .

✅ 成功: 
📁 目录内容:
名称                                     类型       大小            修改时间            
------------------------------------------------------------------------------------------
ChatSessions.json                       文件       2.5 KB          2026-01-01 12:34:56
Messages                                目录       -               2026-01-01 12:30:00
```

### OpenAI 代理

将 OpenAI API Base URL 设置为: `http://电脑IP:8080`

例如在代码或环境变量中:
```bash
# macOS/Linux
export OPENAI_API_BASE=http://192.168.1.10:8080

# Windows (命令提示符)
set OPENAI_API_BASE=http://192.168.1.10:8080

# Windows (PowerShell)
$env:OPENAI_API_BASE="http://192.168.1.10:8080"
```

然后正常发送请求，会自动转发到设备进行捕获确认。

## 🔧 技术细节

**设备端 (Swift)**:
- 使用 `NWConnection` + `NWProtocolWebSocket`
- 作为 WebSocket 客户端主动连接
- 异步处理命令并返回 JSON 响应

**电脑端 (Python)**:
- `websockets` 库提供 WS 服务器
- `aiohttp` 提供 HTTP 代理
- 交互式菜单界面

## ⚠️ 注意事项

1. **防火墙**: 确保电脑防火墙允许入站连接 (端口 8765, 8080)
2. **同一网络**: 设备和电脑必须在同一局域网
3. **服务器地址**: 在设备上输入完整地址如 `192.168.1.100:8765`，使用电脑的局域网 IP，不是 127.0.0.1
4. **权限**: iOS 14+ 需要授予"本地网络"权限

## 🐛 调试

**设备连接不上?**
- 检查服务器地址格式是否正确 (IP:端口)
- 检查防火墙设置
- 确认在同一 Wi-Fi 网络
- 确认 Python 服务器正在运行

**OpenAI 捕获不工作?**
- 确认 API Base URL 设置正确
- 检查电脑端 HTTP 服务器是否运行
- 查看设备端日志

## 📦 文件说明

- `LocalDebugServer.swift` - 设备端 WebSocket 客户端
- `debug_server.py` - 电脑端 WebSocket 服务器
- `requirements.txt` - Python 依赖
- `README_DEBUG.md` - 本文档

## 🎉 优势

✅ 绕过 watchOS 服务器限制  
✅ 无需 PIN 码验证  
✅ 菜单式操作更友好  
✅ 支持 OpenAI 请求转发  
✅ 保留所有原有功能  

---

Made with 💪 to fight Apple's BS restrictions

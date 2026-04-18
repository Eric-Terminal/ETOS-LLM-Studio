# 安装与运行

## 环境要求

- macOS
- Xcode 26.0 或更高版本
- 对应的 iOS / watchOS SDK
- 一个可用的 Apple 模拟器或真机

## 拉取仓库

```bash
git clone https://github.com/Eric-Terminal/ETOS-LLM-Studio.git
cd ETOS-LLM-Studio
```

## 打开工程

请打开工作区文件，而不是直接打开 `xcodeproj`：

```text
ETOS LLM Studio.xcworkspace
```

首次打开时，Xcode 会自动解析并下载 Swift Package 依赖。

## 推荐的启动顺序

### iPhone 端

适合先完成这些事情：

- 配置提供商与模型
- 浏览设置页与功能入口
- 导入导出会话、世界书或记忆
- 打开调试、反馈和同步相关功能

### Apple Watch 端

更适合这些场景：

- 随手发起对话
- 接收 Daily Pulse
- 使用已经同步过来的配置继续聊
- 在轻量交互场景下做快速操作

## 首次运行后要做的第一件事

进入设置，把至少一个模型提供商配置好。  
如果你暂时不想在手表上逐个输入 API Key，优先在 iPhone 端完成，然后再让双端同步接过去。

## 常见误区

### 误区一：直接打开错误的工程文件

这个项目默认应当使用 workspace。  
如果你直接打开 `xcodeproj`，依赖解析和运行体验都可能不完整。

### 误区二：还没配模型就开始排查聊天问题

先确认提供商、模型、Base URL、鉴权头都正确，再去看聊天页本身。

### 误区三：把手表当成主配置端

Watch 端当然能做不少事情，但大量配置仍然更适合在 iPhone 上完成。

## 下一步

- 配模型：看 [第一次配置提供商](/guide/first-provider)
- 发起聊天：看 [第一次发起聊天](/guide/first-chat)

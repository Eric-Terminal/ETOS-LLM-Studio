# 贡献指南

感谢你对 ETOS LLM Studio 的兴趣！无论是修 Bug、加功能、改善文档还是提建议，我们都非常欢迎。

## 快速开始

1. **Fork** 本仓库并克隆到本地：
   ```bash
   git clone --recurse-submodules https://github.com/<你的用户名>/ETOS-LLM-Studio.git
   cd ETOS-LLM-Studio
   ```
2. 确保你已安装 **Xcode 26.0+** 以及 **CMake + Ninja**（`brew install cmake ninja`）。
3. 创建功能分支：
   ```bash
   git checkout -b fix/你的分支名
   ```
4. 进行修改、测试、提交。
5. 向 `main` 分支发起 Pull Request。

## 编译指南

详细的编译步骤请参考 [README.md](README.md#-编译指南)。

简要流程：
1. 先编译 llama.cpp 静态库（运行 `scripts/build-llama-static-library.sh`）。
2. 打开 `ETOS LLM Studio.xcworkspace`（注意是 **workspace**，不是 xcodeproj）。
3. 选择对应的 Scheme（iOS App 或 Watch App），Command + R 运行。

## 代码规范

- **语言**：Swift 6，请遵循 Swift API Design Guidelines。
- **架构**：MVVM + Protocol Oriented Programming。
- **平台逻辑**：业务逻辑放在 `ETOSCore/ETOSCore/`，视图层分别放在 iOS App 或 Watch App 目录。
- **文件头**：每个文件顶部使用标准三行注释格式说明文件职责：
  ```swift
  // ============================================================================
  // FileName.swift
  // ============================================================================
  // 简要描述本文件的职责与归属模块。
  // ============================================================================
  ```
- **命名**：类型用 `PascalCase`，属性和方法用 `camelCase`，常量用 `camelCase`。
- **注释**：关键逻辑使用中文注释；公开 API 使用 `///` 文档注释。
- **@AppStorage**：已全面替代为 `AppConfigStore`，新增配置项请走 `AppConfigStore`。
- **数据库**：数据持久化使用 GRDB + SQLite，新增存储请走 GRDB Migration。

## 提交规范

使用语义化提交信息，格式如下：

```
<type>(<scope>): <描述>

[可选正文]
[可选脚注]
```

**type** 类型：
| 类型 | 说明 |
|------|------|
| `feat` | 新功能 |
| `fix` | Bug 修复 |
| `refactor` | 重构（不新增功能、不修 Bug） |
| `perf` | 性能优化 |
| `style` | 代码格式调整（不影响逻辑） |
| `docs` | 文档变更 |
| `test` | 新增或修改测试 |
| `chore` | 构建、工具、CI 等变更 |

**scope** 示例：`聊天`, `Watch`, `MCP`, `记忆`, `同步`, `UI`, `配置`, `安全`, `LLM` 等。

示例：
```
fix(语音输入): 修复 iPhone 端停止录音后缺少预览确认流程
feat(Watch): 支持语音识别结果预览后再填入输入框
refactor(ChatService): 将会话标签管理拆分到独立 extension
```

## 报告 Bug

请使用 [Issue 模板](https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues/new?template=bug_report.md)，并包含以下信息：

- 平台（iOS / watchOS / macOS）
- App 版本与 Build 号
- 设备型号与系统版本
- 复现步骤
- 预期行为 vs 实际行为
- 日志（如有）

## 功能建议

请使用 [Feature Request 模板](https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues/new?template=feature_request.md) 描述你的想法。如果你打算自己实现，请先开 Issue 讨论方案，避免重复劳动。

## Pull Request 流程

1. 确保你的分支基于最新的 `main`。
2. PR 标题遵循提交规范格式。
3. 填写 PR 模板中的所有必填项。
4. 确保 CI 编译检查通过（iOS + watchOS 均可编译）。
5. 如果修改了 UI，请附上截图或录屏。
6. 等待 Review，根据反馈进行修改。

## 行为准则

请尊重每一位参与者。我们不接受任何形式的骚扰、歧视或人身攻击。

## 许可证

本项目使用 [GPL-3.0](LICENSE) 协议。提交代码即表示你同意你的贡献在 GPL-3.0 下授权。

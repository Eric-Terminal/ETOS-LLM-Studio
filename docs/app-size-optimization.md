# 发布包体积维护

## 核心框架的符号剥离

ETOSCore 目标的 Release 配置使用 `STRIP_STYLE = non-global`，由 Xcode 在正式归档的后处理步骤中剥离局部符号。此配置统一覆盖 iOS 和 watchOS 等支持平台，Debug 保持默认设置。

Framework 默认的 `debugging` 对应 `strip -S`，只移除调试符号；`non-global` 对应 `strip -x`，进一步移除非全局符号。它与删除未引用代码的 Dead Code Stripping 是不同的设置，不能互相替代。保留归档中的 dSYM，用于崩溃符号化；不要在归档签名完成后手动覆盖框架文件。

在用户提供的 Build 436 归档临时副本中，局部符号剥离使 watchOS 单架构 ETOSCore 减少约 3.47–3.65 MB，代码和数据节内容保持一致。新构建的实际收益以分发体积报告为准。

## 扩展文案

主 App 保存完整翻译，各扩展仅打包自己目录下的 `*.lproj/Localizable.strings`。不要再把主 App 的 Localizable.strings 勾选到扩展的 Target Membership，否则会重复携带数 MB 文案或产生同名资源冲突。

| 扩展 | 翻译来源 | 当前文案键数 |
| --- | --- | ---: |
| ETOS Agent Watch Widgets | watchOS 主 App | 8 |
| ETOS Agent Widgets，含实时活动 | iOS 主 App | 21 |
| ETOS Agent Share | iOS 主 App | 16 |
| ETOS Workspace Provider | iOS 主 App | 1 |

每个扩展均保留主 App 支持的全部 8 种语言，项目默认开发语言仍为英文。共享存储和入口模型使用系统错误，目前没有额外的自定义本地化错误文案。

新增或调整扩展文案时，在对应主 App 的各语言表中维护翻译，然后运行：

```sh
python3 scripts/sync-extension-localizations.py
```

脚本使用 Xcode 的 `extractLocStrings` 提取扩展源码及 `SystemEntrySharedModels.swift` 中的本地化键，复用主 App 的翻译。生成文件随源码一起提交，不在运行时扫描或加载主 App 文案库。不要直接编辑生成文件，也不要使用动态键构造扩展内置文案；如果扩展开始调用其他包含本地化提示的共享文件，需要把这些文件加入脚本的 `SHARED_SOURCES`。

可单独执行检查而不更新资源：

```sh
python3 scripts/sync-extension-localizations.py --check
```

Xcode Cloud 的 `ci_pre_xcodebuild.sh` 会在预构建原生依赖前执行同样的检查。缺少翻译或生成文件未同步会停止构建，避免发布后才发现漏译。本地 Xcode 构建直接使用已提交的资源；修改文案后也应先执行检查。

## 验证记录与后续检查

本次完成 32 份生成文案的覆盖、翻译一致性和 plist 语法检查，Xcode 工程文件及 CI 脚本语法检查也通过；通过 Xcode 检查了手表小组件文案的独立目标归属。手表扩展的二进制文案表估算合计 4,034 字节，原归档为 6,073,114 字节。

本次改动仅涉及打包配置和资源，未新增运行时功能。按项目约定，未获编译或测试授权，因此没有执行 Xcode 构建、单元测试或 UI 测试。后续在获得相应授权后，应重新构建并验证扩展在英文和中文等语言下的文案，以及正式分发的手表变体体积；旧归档不会因源码修改而变小。

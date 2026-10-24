# watchOS 包体积维护

watchOS 发布变体需要满足 App Store 的 75 MB 未压缩包体限制。应以发布归档导出的 App Thinning 报告为准；模拟器包、静态库归档和 IPA 下载大小不能代替这个数字。

## 文案资源

- watchOS 的八种语言原文统一维护在 `Localization/watchOS/<语言>.lproj/Localizable.strings`。
- 修改翻译后运行 `python3 scripts/prepare-watch-localizations.py`，并提交原文与生成资源。
- 英语生成到 Watch App 的 `en.lproj/Localizable.strings`，其余语言生成到 `Resources/Localizations/WatchLocalizable-<语言>.zip`。
- 系统在进程外读取的 App Intents 标题、说明和参数名列在 `Localization/watchOS/system-keys.json`，生成到各语言的原生 `Localizable.strings` 小表。新增这类元数据时同步补充该列表；`extractLocStrings` 不能提取这些隐式类型的字符串。
- `InfoPlist.strings` 和 `AppShortcuts.strings` 继续保留在 Watch App 的原生语言目录，供系统权限界面和快捷指令使用。
- 手表扩展从 `Localization/watchOS` 获取原文，继续通过 `scripts/sync-extension-localizations.py` 生成自身需要的原生文案。
- iOS/macOS 的翻译来源与打包方式保持不变；同一功能的翻译仍须同步维护三端。

`prepare-watch-localizations.py --check` 检查所有语言的键集合、压缩往返一致性及生成资源是否过期。Xcode Cloud 在构建前执行该检查，避免把旧翻译或完整原文与压缩包同时发布。该检查只读资源，不编译应用。

运行时由独立 Actor 解压和解析，仅缓存英语与最近选中的一种语言。首次显示业务页面前完成语言准备；切换语言不重置导航，过期或取消的加载不能覆盖新语言。`NSLocalizedString` 只查内存字典，缺失键回退英语。所有语言随包携带，无需下载。

App Intent 执行和冷启动 URL 处理共用语言准备器，动态回复也会等待字典就绪。系统权限提示、快捷指令短语及上述元数据仍可直接从 Bundle 读取。

## 图标和编译设置

“关于”页的 `AppIconDisplay` 使用 256×256 图片，满足手表 56 pt 展示需要；App Store 图标继续保留 1024×1024 原图。

Watch App 的 Release 使用 Swift `-Osize`。ETOSCore 仅对 Release 的 watchOS / watchOS Simulator 使用 `-Osize`；其他平台及 Debug 保持原有优化设置。Whole Module 和 Dead Code Stripping 继续启用。

`scripts/build-llama-static-library.sh` 对 watchOS Release 原生静态库使用隐藏符号可见性，使 ETOSCore 链接器能够移除不再需要对外导出的实现。C 桥接接口继续正常导出，模型格式、多模态与推理计算优化级别保持不变。可见性参数参与产物缓存签名，旧静态库会在下次原生库构建时失效。没有更改 iSH 子模块或 RootFS。

## 验证范围

`CompressedAppLocalizationTests` 覆盖压缩文案解码、非法归档、英语回退、系统语言匹配、后台资源加载、快速切换及取消。只有获得明确测试授权后才运行 ETOSCore 测试。

发布前还需在获得构建授权后比较新旧真机 Release 归档，确认所有 watchOS 变体的未压缩大小；获得测试授权后验证语言切换、导航保留及本地推理。资源字节减少量不等于最终商店包的减少量，也不构成构建或运行验证。

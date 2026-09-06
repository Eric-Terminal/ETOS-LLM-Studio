# Apple 原生工具支持范围与配置

核对日期：2026-09-06。本文覆盖 `NativeCapabilities` 的四组 64 项工具，以及同属个人数据服务器的日历、提醒事项权限边界。

## 本机执行范围

工具目录、缓存恢复和实际 MCP 调用采用相同的平台判断。不支持的能力不显示、不向模型提供，也不通过配对 iPhone 代执行。系统授权被拒绝、网络临时不可达、没有家庭配件或附近 BLE 外设不属于平台不支持，工具会返回实际错误。

| 能力 | iOS | watchOS | 使用条件 |
| --- | --- | --- | --- |
| 剪贴板读取、写入、清空 | 支持 | 不提供 | 只处理当前设备的纯文本剪贴板 |
| 本地通知 | 支持 | 支持 | 仅管理 ETOS 登记的通知；登记时申请通知权限 |
| AlarmKit 闹钟 | iOS 26 起支持 | 不提供 | 闹钟隐私说明和用户授权；只管理 ETOS 创建的闹钟 |
| 地点搜索、路线与打开地图 | 支持 | 支持 | 完整路线仅支持驾车、步行、骑行；公交可交由系统地图展示 |
| 系统 URL | 支持限定协议 | 仅 `tel`、`sms` | 手表只能确认请求已交给系统 |
| 设备状态 | 支持 | 支持 | 只读系统、电池、存储状态 |
| 语音朗读与停止 | 支持 | 支持 | 只控制 ETOS 自己发起的朗读 |
| 音频文件转写 | 支持 | 不提供 | Speech 授权、可用的语言识别服务和本机 `app://` 文件 |
| 媒体播放与控制 | 支持 | 支持 | 只控制 ETOS 自己创建的播放器和本机 `app://` 文件 |
| 当前天气、逐小时与逐日预报 | 支持 | 支持 | WeatherKit 服务与签名授权、网络连接；使用显式坐标 |
| HomeKit 家庭、配件、场景与特征 | 支持 | 支持 | HomeKit 签名能力、隐私说明、用户家庭授权和实际配件 |
| BLE 扫描、连接与特征读写 | 支持 | 支持 | 蓝牙硬件、系统授权；连接属于当前会话或 Agent Run |
| NFC 扫描和 NDEF 读写 | 支持 NFC 的 iPhone | 不提供 | 按 `readingAvailable` 过滤；模拟器和不支持的设备不显示 |
| 联系人读取 | 支持 | 支持 | 联系人授权 |
| 联系人写入与删除 | 支持 | 不提供 | 每次写入都需要确认 |
| 系统照片图库 | 支持 | 不提供 | Photos 授权；模型使用本机受控文件 URI |
| 定位、逆地理编码与地点搜索 | 支持 | 支持 | 获取当前位置时申请定位权限；坐标查询不读取设备位置 |
| Vision 文字、条码、图像与文档识别 | 支持 | 不提供 | 目录按 Vision 框架支持范围过滤 |
| NaturalLanguage 语言分析 | 支持 | 支持 | 具体任务还受语言资源支持范围限制 |
| 日历与提醒事项读取 | 支持 | 支持 | 相应系统授权 |
| 日历与提醒事项写入 | 支持 | 不提供 | 每次写入都需要确认 |

原生工具的配对设备代执行通道已删除。Browser Agent、用户快捷指令和视频帧提取的独立协作功能不属于这个原生工具通道。

## 本地配置

- iOS Debug 和 Release 都声明 WeatherKit、HomeKit、HealthKit 和 NFC `TAG` 权限。
- watchOS 声明 WeatherKit、HomeKit 和 HealthKit；不添加 NFC 或 AlarmKit 能力。
- iOS 的 `Config/iOSInfo.plist` 包含 `NSAlarmKitUsageDescription`。
- watchOS 的 `Info.plist` 包含蓝牙、联系人和 HomeKit 隐私说明。定位说明同时覆盖用户显式调用定位工具的行为。
- 相关权限说明和工具中心介绍卡在双端的八种语言中同步维护。

这些文件是签名请求和隐私声明，不能证明开发者后台或已安装旧版本的授权已经生效。

## 开发者后台与签名

在 [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) 核对实际团队下的两个明确 App ID：

| App ID | Capabilities | App Services |
| --- | --- | --- |
| `com.ericterminal.els` | WeatherKit、HomeKit、HealthKit、NFC Tag Reading；保留已有其他能力 | WeatherKit |
| `com.ericterminal.els.watchkitapp` | WeatherKit、HomeKit、HealthKit；保留已有其他能力 | WeatherKit |

WeatherKit 必须同时启用 App Capabilities 和 App Services 中的对应选项。若手表 App ID 在列表中找不到，先按完整 Bundle ID 搜索并确认团队；确实不存在时，才注册对应的明确 App ID。修改后需更新 provisioning profile，并在后续获准构建时检查实际签名产物的 entitlement，重新安装后验证。

本次后台核对：已通过 Computer Use 找到两个 App ID，并确认 `com.ericterminal.els` 的 Capabilities 中 WeatherKit、HomeKit、HealthKit 和 NFC Tag Reading 均已开启。iOS 的 App Services 与手表 App ID 的能力仍待核对，尚未提交网页变更。后台与签名核对完成前，不能把 WeatherKit 鉴权错误标记为已修复。

## 文档依据

- [WeatherKit 服务配置](https://developer.apple.com/help/account/services/weatherkit/)：App ID 的两个标签页均需启用 WeatherKit。
- [WeatherKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.weatherkit)：支持 watchOS，在执行请求的 App Target 中声明。
- [AlarmKit 闹钟示例](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit)：缺少有效的 `NSAlarmKitUsageDescription` 时不能安排闹钟。
- [HomeKit 的 HMHomeManager](https://developer.apple.com/documentation/homekit/hmhomemanager)：提供 watchOS 原生家庭访问接口。
- [蓝牙隐私说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription)：使用蓝牙接口必须声明用途。
- [Speech 识别器](https://developer.apple.com/documentation/speech/sfspeechrecognizer)与 [Photos 图库](https://developer.apple.com/documentation/photos/phphotolibrary)：当前接口不提供 watchOS 支持。
- [MapKit 公交交通类型](https://developer.apple.com/documentation/mapkit/mkdirectionstransporttype/transit)：仅支持预计到达时间，不能用完整路线计算替代。
- [watchOS 系统 URL](https://developer.apple.com/documentation/watchkit/wkapplication/opensystemurl(_:))：支持电话与短信协议。
- [Core NFC](https://developer.apple.com/documentation/corenfc)：调用前判断设备的 `readingAvailable`。

## 验证范围

已补充目录发现、旧缓存与路由过滤、不支持工具的调用拒绝、公交参数拒绝、手表 URL 限制及宿主权限声明回归用例。按照项目约定，本次未获得构建或运行测试授权，因此未执行 `xcodebuild` 或测试。

后续获准测试时运行改动涉及的 ETOSCore 测试；真机验收还应覆盖开发者后台配置更新后的 WeatherKit 请求、首次 AlarmKit 授权、手表蓝牙与 HomeKit 首次授权，以及 NFC 支持设备与不支持设备的目录差异。

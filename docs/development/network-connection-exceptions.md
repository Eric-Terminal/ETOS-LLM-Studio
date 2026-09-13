# 用户确认的连接例外

对应 Issue：[#140](https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues/140)。

## 使用方式

连接例外的管理入口位于 iOS 和 watchOS 的“设置 → 拓展功能”底部。

- HTTP 默认在发送请求前询问，确认前不会发送请求正文或认证头。
- HTTPS 默认执行系统服务器信任验证；验证失败时说明连接仍加密，但服务器身份无法正常确认。
- 用户可以取消、仅本次继续或继续并记住。记住会开启对应类型的例外，授权在 App 各网络功能之间共用。
- 主机名/IP、协议、端口共同确定来源。路径、查询参数、用户名、密码不参与匹配，也不会进入确认页面或向导快照。
- 管理页的开关只控制已记住的例外，不会信任所有服务器。关闭类型或删除地址会取消受影响的请求；撤销证书例外时还会重置会话连接。

## 网络实现

两个 App 的 Info.plist 使用 `NSAllowsArbitraryLoads`，并通过 `NSExceptionDomains` 为 `els.ericterminal.com` 及其子域名保留完整 ATS 要求。用户域名不进入打包配置。

`NetworkConnectionSecurity` 在独立 actor 中处理数据库读取、来源授权和证书验证。普通 API 使用 `URLSession.securedData`、`securedBytes`；带进度的上传和下载在创建任务前授权，并继承 `NetworkSecuritySessionDelegate` 处理服务器信任和重定向。代理设置仍交给原生 URLSession。

MCP SDK 的公开初始化接口不能注入 URLSession，所以仅对 SDK 会话安装 `MCPNetworkSecurityURLProtocol`。它通过原生 URLSession 转接请求、逐块传递流式响应，并在停止时取消底层任务。原生 MCP SSE、OAuth 令牌请求和其他 API 请求使用共同的授权策略。

证书处理顺序为：

1. 使用 `SecTrustEvaluateWithError` 执行默认验证。
2. 如果已有该来源的例外，应用 `SecTrustSetExceptions`，然后重新验证。
3. 原例外不适用时，清除旧例外并展示当前验证问题。
4. 用户同意后调用 `SecTrustCopyExceptions`，应用新例外并再次验证；只有验证成功才接受 URLSession 的认证挑战。

同地址并发请求可共用确认，但证书链或验证问题不同时不会合并成一次授权。取消任务和离开前台会结束待确认请求，避免恢复后执行过期操作。拒绝连接的 MCP SSE 请求不会继续自动重连并反复弹窗。

原生确认界面由 `NetworkConnectionApprovalHost` 承载，iOS 在当前可见控制器上展示，watchOS 使用系统提示。仅本次的选择不写入数据库。

## 持久化与向导边界

例外保存在配置数据库的辅助记录中。记录使用本机钥匙串中的设备绑定密钥进行 HMAC 校验；从其他安装导入的记录或被修改的数据库记录不能直接取得授权。原始证书例外数据不进入日志或页面向导。

管理根页、地址详情、说明弹页和连接确认分别声明向导上下文。信任决定只能通过用户的原生操作完成，向导只读，不提供放行工具。watchOS 的根页、详情和教程均使用页面向导入口，并保留来源上下文。

设置影响接入上述网络层的 App 请求，不修改操作系统的证书信任库、Safari 或内嵌 Linux 独立程序的网络策略。WebKit 网页子资源由 WebKit 管理，不经过 URLSession 的 HTTP 请求预检；Browser Agent 的原生下载接入此策略。

## 验证记录与计划

已补充 `NetworkConnectionSecurityTests`，覆盖来源标准化、自有域名边界、默认拦截、仅本次选择、授权复用、撤销、导入记录校验，以及证书替换和新增过期错误的重新验证。证书测试只使用公开的自签名测试证书，关闭在线证书获取，并固定验证时间。

已通过 18 个属性列表/本地化文件的格式检查、44 个 Swift 文件的语法解析，并完成请求入口静态排查和 Git 补丁空白检查。语法解析不包含类型检查。按照项目约定，本次没有执行编译或运行测试，以下验证仍待明确授权后进行：

- 执行 ETOSCore 测试，核对上述策略用例和现有 MCP、代理、文件传输回归用例。
- 构建 iOS App（连带 watchOS），核对两端的类型检查、链接和 SDK 可用性。
- 在提供商编辑弹页、聊天页和 MCP 页面分别连接 HTTP 服务，核对取消前无请求到达服务器，以及仅本次和记住的区别。
- 连接自签名 HTTPS 服务，核对记住后可重连、更换证书后重新询问、拒绝后不自动降级 HTTP。
- 对长时间 SSE、代理、OAuth、上传和下载执行取消及撤销，确认底层连接停止；同时检查跳转到新 HTTP 来源仍需要确认。
- 在 iOS/watchOS 前后台切换、多个请求同时等待、向导页切换和其他原生提示已打开时检查确认界面。
- 逐项核对八种语言的说明和按钮，以及 watchOS 狭窄布局。

参考苹果文档：[ATS 例外配置](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)、[手动服务器信任验证](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication)、[应用证书例外后重新评估](https://developer.apple.com/documentation/security/sectrustsetexceptions(_:_:))。

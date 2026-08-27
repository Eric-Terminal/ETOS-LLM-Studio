# iOS 聊天界面重构工程日志

## 背景与验收基线

本次重构以 2026-08-26 `dev` 分支的 iOS 聊天界面为视觉和功能基线。目标不是重新设计界面，而是替换长期叠加的滚动协调机制：长会话向上阅读几条消息后，视口会不受控制地下滑，同时模拟器 CPU 持续达到 100%。自动历史加载和手动分批加载均受影响。

必须保留的用户体验包括：Telegram/iMessage 风格气泡与相邻连接、壁纸与液态玻璃材质、原生滚动阻尼、可选气泡滚动过渡、输入栏及其尺寸动画、发送飞行动画、回底按钮、四键时间线导航、跨窗口消息跳转，以及 UIKit 增量 Markdown 的动态/静态交接。

## 2026-08-26：初始取证

### 仓库状态

- 仓库：`/Users/Eric/Dev/Swift/ETOS LLM Studio`
- 分支：`dev`，相对 `origin/dev` 无提交差异。
- 开始时工作树干净。
- iOS 聊天主路径集中在 `ChatView.swift`、`ChatViewScrollHelpers.swift`、`ChatViewSupport.swift`、`ChatViewModel` 扩展与 `ChatHistoryWindow.swift`。

### 已确认的复杂度信号

- `ChatView.swift` 约 1522 行，其中直接持有大量滚动相关 `@State`。
- `ChatViewScrollHelpers.swift` 约 1051 行，同时负责历史扩窗、底部吸附、消息跳转、手势抢占、输入栏布局过渡和滚动目标生命周期。
- `ChatViewSupport.swift` 约 1265 行，其中 `ChatScrollMetricsObserver` 同时 KVO 观察 `contentOffset`、`contentSize` 和 `bounds`，又直接写入 `contentOffset`、启动流式跟随动画并向 SwiftUI 回写度量。
- 2026-08-07 至 2026-08-22 之间，同一滚动区域存在多轮尺寸吸底、呈现层偏移、流式高度反馈、窗口所有权、历史扩窗和锚点恢复修复，说明当前行为由多个补偿层共同维持。

### 当前滚动所有者（待收敛）

1. SwiftUI `.scrollPosition(id:anchor:)` 用于回底、消息跳转和历史锚点恢复。
2. `.defaultScrollAnchor(_:for:.sizeChanges)` 在非流式贴底时处理内容尺寸变化。
3. `ChatScrollMetricsObserver` 在流式期间观察内容高度并直接动画 `UIScrollView.contentOffset`。
4. 历史扩窗在消息数组身份变化后再次设置 `scrollPosition` 恢复旧边界消息。
5. 布局完整性监视器可额外写入 `chatScrollTarget` 做气泡重叠自愈。

这些路径共享 `shouldKeepBottomPinned`，并通过 SwiftUI 状态、KVO、异步任务和布局变化互相触发。后续取证要确认 CPU 循环的具体闭环，再决定哪些原生观察可保留为只读输入。

### Git 演变重点

- `c9b77184`：接入流式 Markdown 动静分离。
- `93d4bbb2`：曾移除流式气泡高度反馈闭环。
- `4fef95e6` 至 `1a4d3cf0`：多轮恢复流式自动追底、隔离定位状态并稳定 Markdown。
- `4a795d36`：加入自动回收的双向历史窗口。
- `caba2d4e`、`7d710122`：继续修复双端历史懒加载、回底裁切与长会话定位。

## 决策记录

### D-001：视觉层不是首轮重写对象

气泡、Markdown 子视图和输入栏已有用户认可的视觉结果。首轮仅把它们视为消息列表内容，重写滚动协调和分页边界；只有证据表明渲染身份参与反馈环时，才修改对应接口。

### D-002：手势拥有最高优先级

遵循原生直接操控原则：触摸开始即取消程序化滚动，后续状态更新不能在同一手势或减速期间重新取得所有权。程序化命令从当前呈现位置开始，且必须有单一、明确的结束条件。

## 待验证问题

- `contentSize` KVO → `contentOffset` 写入 → SwiftUI 度量回写 → View 重算/布局 → `contentSize` KVO 是否构成长时间主线程闭环。
- 历史扩窗后同时由 `.scrollPosition`、身份变化处理和原生 observer 恢复锚点，是否导致反复目标写入。
- 用户手势结束时 `pendingAutomaticHistoryLoadRequest` 是否在旧距离度量下触发扩窗，随后被 `handleDisplayedMessageIdentityChange()` 误判为需要回底。
- 手动加载模式是否走另一套未保持几何锚点的路径。
- `ChatLayoutIntegrityMonitor` 的自愈写入是否会在正常 Markdown 重排期间错误触发。

## 验证记录

### 滚动位置反馈闭环

- `.scrollPosition(id:anchor:)` 的绑定会在用户滚动时持续回写当前可见消息，这只是位置观测，不代表程序化滚动仍在执行。
- 2026-08-18 的时间线导航改动把任意非空 `chatScrollTarget` 都计入程序化滚动所有权；手势处理随后清空目标，SwiftUI 又立即回写新的可见消息，形成“消息 ID → nil → 消息 ID”的状态循环。
- 历史窗口扩展会同时改变消息身份和布局，使这个循环更容易进入持续失效、锚点竞争和主线程满载状态。
- 新增 `ChatScrollPositionController`，将系统位置观测与显式滚动命令分离。被动回写不发布 SwiftUI 状态；命令只在自己的生命周期内占有绑定，手势可立即释放命令且不再向绑定写入 `nil`。

### 首轮验证

- iOS App（包含嵌入的 watch App）构建成功。
- iOS App 回归测试通过，共 89 个测试、0 失败；新增用例覆盖被动位置回写不获取所有权，以及命令期间拒绝中间回写、释放后恢复观测。
- 构建仅出现 `swift-cmark` 缺少 umbrella header 的既有第三方警告。
- 回归测试启动时出现一次本机 `127.0.0.1:7890` 连接失败日志，但未影响测试执行与结果。

### D-003：历史窗口只使用几何锚点恢复

自动向前/向后扩窗与手动分批加载统一经过 `ChatHistoryViewportAnchorController`。扩窗前记录当前边界消息在消息栈内容坐标中的真实位置；消息身份发生变化后，用同一消息的新旧 `minY` 差生成一次 `contentOffset` 修正。修正由现有 UIKit 桥无动画原子应用，不再设置 `.scrollPosition`，也不再用延时任务猜测目标是否稳定。

用户开始拖动时会立即取消尚未应用的历史锚点。历史窗口只负责改变显示范围，流式跟随、消息跳转和布局自愈不会复用这条命令生命周期。

### D-004：连续滚动度量留在 UIKit 内

`contentOffset`、`contentSize` 和 `bounds` 仍由 UIKit 观察，以维持流式贴底和原生手势语义；但连续像素距离不再逐帧写入 SwiftUI。只有跨过以下交互边界、交互状态变化或显式命令要求回执时才发布：抵达顶部/底部、进入历史加载区、进入吸底区、跨过回底按钮阈值。

这保留了自动分页、回底按钮和命令完成判断，同时切断“每 0.5 点位移 → SwiftUI 状态更新 → 全列表重算”的热路径。

### D-005：布局探针按需启用

- 消息外框只在时间线导航、VoiceOver 或静止布局审计需要时上报；拖动、流式生成、程序化滚动和历史扩窗期间不采集视口坐标。
- 气泡内部正文 frame 只在两次新鲜、稳定的重叠复核样本期间启用，复核结束立即关闭。
- 历史锚点使用消息栈内容坐标，常规滚动不会改变数值；它与视口坐标探针分离。

### D-006：聊天视图只持有一个滚动协调器

`ChatView` 不再直接保存二十余个滚动布尔值、任务和控制器，而只持有一个 `ChatScrollCoordinator`。协调器统一拥有程序化滚动命令、历史锚点、布局监视、自动分页、手势抢占、会话切换和视图消失时的生命周期；其子控制器的状态变化会继续转发给 SwiftUI，因此不会损失原有界面刷新语义。

历史加载的开始、完成与取消均由协调器闭合：未实际加载时立即释放锚点和抑制标记，实际加载时只保留一次待应用的 UIKit 几何修正。用户触摸、切换会话或离开页面时使用同一入口取消不再合法的命令，避免视图扩展之间各自维护一套清理顺序。

### 文件职责拆分

针对聊天主路径原有多个千行文件，按职责拆分为会话组合、历史加载、滚动桥、滚动纯度量、滚动协调和布局审计上下文。`ChatViewLayoutIntegrity.swift` 再按无状态审计定义与有状态恢复调度拆分为 515 行和 477 行，避免把 1000 行硬限制误当作日常目标。`ChatViewModelMessageSync.swift` 中的历史窗口操作另行拆至 185 行的 `ChatViewModelHistoryWindow.swift`，原文件降至 834 行。原本集中的应用测试也按聊天滚动协调、流式滚动和真实长会话运行态拆开。拆分未改变气泡、壁纸、材质、输入栏、时间线导航和发送飞行动画的宏观结构。

### D-007：历史锚点等待 LazyVStack 几何稳定

真实挂载 `ChatView` 后确认，历史扩窗会让 `LazyVStack` 在短时间内连续上报过渡 frame；同时 `UIScrollView.contentSize` 的上限可能仍是扩窗前的估算值。锚点控制器现在等待几何连续静止 80 毫秒后只生成一次修正，历史锚点允许暂时越过旧的最大偏移上限，等下一轮布局刷新真实内容尺寸。普通布局自愈仍使用上下界钳制，历史修正也始终保留下界保护。

历史锚点测试不再假设防抖任务必须在固定 120 毫秒内获得调度，而是等待结果或在 3 秒后明确超时，避免模拟器冷启动与数据库维护造成时序型假失败。

## 最终验证

- iOS App 完整构建成功，命令同时构建并验证了嵌入的 watch App 与各扩展。
- iOS App 回归测试最终通过：99 个测试、16 个套件、0 失败。新增测试覆盖协调器完整历史变更生命周期、无数据加载时释放锚点，以及真实 UIKit 滚动桥的同语义区域回调抑制和历史锚点仅应用一次。
- 三组聊天滚动相关测试连续执行 3 轮，共 123 个测试、9 个套件全部通过。运行态测试真实挂载包含 60 条长消息的 `ChatView`：离底后连续模拟 20 个像素级偏移，视口没有自行回底或持续发布状态；自动与手动扩窗中，UIKit 实际偏移量与锚点消息的 frame 变化量一致。
- ETOSCore 全量执行 1503 个测试时，`RoleplayStoreThreadingTests.changingPersonaRefreshesSeededGreetingAfterConversationStarted()` 在同一次运行中报告 2 个断言问题；该模块未被本次改动。随后单独重跑整个“角色扮演存储”串行套件，6 个测试全部通过，确认不是稳定回归。
- 最终构建仍只有 `swift-cmark` 缺少 umbrella header 的既有第三方警告。
- 两次尝试本机界面控制均因 `Sky Computer Use service startup request failed` / `Transport closed` 无法启动，因此未把截图式人工冒烟作为通过项；改用真实 `UIWindow`、`UIHostingController` 和 `UIScrollView` 的确定性运行态回归覆盖长会话交互，宏观 UI 另由差异复核与完整构建确认未发生结构性改动。

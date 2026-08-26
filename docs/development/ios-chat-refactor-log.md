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

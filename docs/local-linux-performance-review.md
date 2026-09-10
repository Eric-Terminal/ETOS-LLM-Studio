# 本地 Linux 卡顿排查与输出链路优化

2026-09-10，通过本地源码检查 App、嵌入的 ish-multiarch、独立 ish-multiarch 工作目录、OpenMinis 及其 ish-arm64。未运行构建、测试或实机性能采样；以下区分已确认的代码行为与尚待测量的影响。

本次未发现“整个 iSH 模拟器直接在 UI 主线程执行”的调用链证据。`iSHAppleBridgeAdapter` 和 `LocalLinuxJobScheduler` 都是独立 actor；PTY 输出由 `.utility` 的 `Task.detached` 读取；guest 执行由内核 `task_start_suspended` 创建的 pthread 承担。这不等于已排除所有卡顿：后台 CPU、内存分配、调度器排队，以及终端长文本在主线程的布局，仍会影响体验。

实际构建来源是仓库中的 `Dependencies/ish-multiarch`，由 `scripts/build-ish-static-library.sh` 消费。本次检查时子模块提交为 `3c4fe752`；`~/Dev/C:C++/ish-multiarch` 为 `6140c26c`，后者仅多出一条文档提交。`tools/apple-core-gate.sh` 为核心配置 release 构建，并为 Apple ARM 切片选择 threaded 后端，没有看到误用纯 C 后端或开启 threaded profiling 的配置。

| 已确认的额外开销 | 本次修改 | 影响范围 |
| --- | --- | --- |
| `LocalLinuxOutputCollector.appendUserPreview` 每个 PTY 分片都调用 `renderedText`，拼接最多 2,000 行历史，即使没有页面读取它 | 继续增量解析协议与及时回包，只将纯文本缓存标记为失效，读取时才生成 | 隐藏终端、持续刷日志、长历史 |
| `LocalLinuxTerminalScreen.put` 和 `mutateBuffer` 先复制 `Buffer` 值，修改嵌套数组后再写回，存在逐字符写时复制开销 | 通过 `inout` 直接修改主屏或备用屏的存储 | 所有终端输出解析 |
| 缩略图先复制完整历史并生成所有屏幕行的富文本，最后才截取末尾几行 | 先选取尾部范围，再为选中的屏幕行生成样式 | 聊天页终端缩略图 |
| 调度器 actor 同步等待收集器锁并生成输出预览，期间输入、中断及其他会话操作可能排队 | 捕获收集器后，在独立后台任务中读取和生成快照 | iOS/watchOS 的任务调度与终端输入 |
| PTY 无论空闲还是有积压，始终每次休眠 5 毫秒 | 空闲时逐步退让至 50 毫秒；读满 16 KiB 时让出执行权后继续排空 | 空闲唤醒和连续输出吞吐 |
| 异步预览在终端切换或页面离开后仍可能返回 | iOS、watchOS 终端及 iOS 缩略图在回写前检查取消状态 | 防止旧会话结果覆盖新页面 |

空闲 PTY 稳定后，应用层读取检查频率从理论约 200 次/秒降至约 20 次/秒。这是代码中的调度间隔，不是整机 CPU 或耗电降低 90% 的测量结果；新输出最多多等待一个 50 毫秒的轮询间隔，另有系统调度与处理时间。读取、退出结果检查及日志保存继续运行，页面隐藏不会使 guest 因宿主停止读取而堵塞。本次没有新增设置或更改页面字段、文案与向导操作。

两套 AArch64 内核的差异也不能忽略。当前嵌入内核中，`guest/aarch64/runner.c:aarch64_run_one` 每次取一条指令；`guest/aarch64/threaded.c` 使用缓存解码与 C handler；`guest/aarch64/linux-process.c:aarch64_linux_process_run_one` 在普通指令完成后调用 `aarch64_linux_poll_signals`，再返回 task 循环。相对地，本地 `~/Dev/C:C++/ish-arm64/asbestos/guest-arm64/gen.c` 构造基本块的 gadget 序列，由预编译汇编 gadget 执行。因此，两者虽然都称为 threaded 后端，单条指令的处理路径已不相同，CPU 密集任务可能有明显差异，不能用同源或没有死循环推导出接近的性能。本次没有修改指令执行、信号时序或子模块版本。

OpenMinis 的宿主接入也有不同：`src/ios/iSH/ISHShellExecutor.m` 用后台 reader queue 与 `poll` 等待命令输出；`TerminalCanvasView.swift` 缓存已冻结的历史富文本，避免无关 SwiftUI 更新触发重建。它在 App 进入后台时开启 80% duty cycle 的 guest 节流，前台关闭，因此这段节流不能直接解释前台界面是否流畅。以上来自源码检查，没有采用其 README 中的跑分作为本项目的性能证据。

已补充 `LocalLinuxTerminalOutputPipelineTests` 和 `LocalLinuxTerminalScreenTests` 用例，覆盖无预览订阅时的原始帧完整性与协议回包、三种预览缓存的独立刷新、缩放、主备用屏隔离、历史与屏幕边界、空白行及背景样式、已发布快照不被后续修改，以及空闲退让和满块读取。本次仅做静态调用点检查与 `git diff --check`，按项目约定未执行这些测试。

实际流畅度仍需使用用户触发问题的命令，在相同设备、相同前后台状态下采样确认。验证应同时记录主线程耗时、guest 线程 CPU、输出速率与输入响应，并区分“计算但不输出”“持续输出”“隐藏终端”三种情况。纯计算的执行器速度不会因本次终端优化自动接近 ish-arm64；完整终端目前仍用一个 SwiftUI `Text` 呈现长历史，其主线程布局成本也是尚待实机采样确认的剩余因素。

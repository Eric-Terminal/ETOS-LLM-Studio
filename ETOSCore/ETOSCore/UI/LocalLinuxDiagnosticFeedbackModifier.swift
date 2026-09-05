import SwiftUI

public extension View {
    /// 根聊天页兜底接收命令诊断；Linux 页面和终端使用更高优先级承接当前弹窗。
    @MainActor
    func localLinuxDiagnosticFeedback(priority: Int = 0, active: Bool = true, blocked: Bool = false) -> some View {
        modifier(LocalLinuxDiagnosticFeedbackModifier(priority: priority, active: active, blocked: blocked))
    }
}

@MainActor
private struct LocalLinuxDiagnosticFeedbackModifier: ViewModifier {
    let priority: Int
    let active: Bool
    let blocked: Bool
    @ObservedObject private var coordinator = LocalLinuxDiagnosticFeedbackCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var presenterID = UUID()
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                updatePresenter()
            }
            .onDisappear {
                isVisible = false
                coordinator.unregisterPresenter(id: presenterID)
            }
            .onChange(of: blocked) { _, _ in updatePresenter() }
            .onChange(of: active) { _, _ in updatePresenter() }
            .onChange(of: scenePhase) { _, _ in updatePresenter() }
            .overlay(alignment: .bottom) {
                if coordinator.presenterID == presenterID, coordinator.isSending {
                    ProgressView(NSLocalizedString("正在发送诊断…", comment: "自动诊断反馈发送进度"))
                        .font(.footnote)
                        .padding()
                        .background(.regularMaterial)
                        .allowsHitTesting(false)
                }
            }
            .alert(item: Binding(
                get: { coordinator.presenterID == presenterID ? coordinator.prompt : nil },
                // 宿主切换或应用进入后台不等于用户拒绝，只有明确按钮操作才消费事件。
                set: { _ in }
            )) { prompt in
                switch prompt.kind {
                case .consent:
                    Alert(
                        title: Text(NSLocalizedString("向开发者共享 Linux 诊断？", comment: "自动诊断反馈征求同意")),
                        message: Text(String(format: NSLocalizedString("检测到 Linux 兼容性错误。允许后将通过反馈助手发送本次任务已收集的诊断事件（含进程名）、应用与设备信息及基本运行统计，不包含聊天记录、命令参数、环境变量或终端输出。\n\n%@", comment: "自动诊断反馈共享范围"), prompt.offer.summary)),
                        primaryButton: .default(Text(NSLocalizedString("允许并发送", comment: "自动诊断反馈同意按钮"))) {
                            coordinator.send(promptID: prompt.id)
                        },
                        secondaryButton: .cancel(Text(NSLocalizedString("暂不发送", comment: "自动诊断反馈拒绝按钮"))) {
                            coordinator.dismiss(promptID: prompt.id)
                        }
                    )
                case .sent(let issueNumber):
                    Alert(
                        title: Text(NSLocalizedString("诊断已发送", comment: "自动诊断反馈发送成功")),
                        message: Text(String(format: NSLocalizedString("已创建反馈 #%lld，可在反馈助手中查看进度或补充操作步骤。", comment: "自动诊断反馈工单回执"), Int64(issueNumber))),
                        dismissButton: .default(Text(NSLocalizedString("好", comment: "关闭诊断反馈回执"))) {
                            coordinator.dismiss(promptID: prompt.id)
                        }
                    )
                case .failed(let message):
                    Alert(
                        title: Text(NSLocalizedString("诊断发送失败", comment: "自动诊断反馈发送失败")),
                        message: Text(message),
                        primaryButton: .default(Text(NSLocalizedString("重试", comment: "重新发送同一份诊断"))) {
                            coordinator.send(promptID: prompt.id)
                        },
                        secondaryButton: .cancel(Text(NSLocalizedString("取消", comment: "取消诊断发送"))) {
                            coordinator.dismiss(promptID: prompt.id)
                        }
                    )
                }
            }
    }

    private func updatePresenter() {
        guard isVisible else { return }
        guard active else {
            coordinator.unregisterPresenter(id: presenterID)
            return
        }
        coordinator.registerPresenter(
            id: presenterID,
            priority: priority,
            blocked: blocked || scenePhase != .active
        )
    }
}

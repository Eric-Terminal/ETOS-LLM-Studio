import SwiftUI

/// 撤销会改变配置，不能让容易被认成返回的图标直接执行它。
public struct GuideUndoButton: View {
    @ObservedObject private var controller: GuideConversationController
    @State private var showingConfirmation = false

    public init(controller: GuideConversationController) {
        self.controller = controller
    }

    public var body: some View {
        Button {
            showingConfirmation = true
        } label: {
            Label(NSLocalizedString("撤销上次修改", comment: "向导撤销按钮"), systemImage: "arrow.uturn.backward")
        }
        .labelStyle(.iconOnly)
        .disabled(controller.isResponding || controller.pendingProposal != nil || controller.isAwaitingToolContinuation)
        .alert(
            NSLocalizedString("撤销上次修改？", value: "Undo the last change?", comment: "向导撤销二次确认标题"),
            isPresented: $showingConfirmation
        ) {
            Button(NSLocalizedString("取消", comment: "取消向导撤销"), role: .cancel) {}
            Button(NSLocalizedString("撤销修改", value: "Undo Change", comment: "确认撤销向导修改"), role: .destructive) {
                controller.undoLastChange()
            }
        } message: {
            Text(NSLocalizedString(
                "将恢复向导上次修改前的设置。此操作不会关闭向导。",
                value: "This restores the settings from before the guide’s last change. It does not close the guide.",
                comment: "说明撤销会恢复设置，而不是返回或关闭"
            ))
        }
    }
}

import ETOSCore
import SwiftUI

struct MacGuideView: View {
    @StateObject private var controller = GuideConversationController(historyStore: .contextualHelp)
    @State private var input = ""
    @State private var confirmsUndo = false
    @State private var confirmsClear = false

    var body: some View {
        VStack {
            HStack {
                Label(NSLocalizedString("页面向导", comment: ""), systemImage: "sparkles").font(.headline)
                Spacer()
                Button(NSLocalizedString("撤销", comment: "")) { confirmsUndo = true }
                    .disabled(!controller.canUndo || controller.isResponding)
                Button(NSLocalizedString("清空", comment: "")) { confirmsClear = true }
                    .disabled(controller.isResponding)
            }
            MacGuideModelPicker(router: controller.router)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(controller.messages) { message in
                        Text(message.content)
                            .textSelection(.enabled)
                            .padding(.vertical)
                            .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                    }
                    MacGuideStreamingText(state: controller.streamingState)
                    if let proposal = controller.pendingProposal {
                        GroupBox {
                            VStack(alignment: .leading) {
                                Text(proposal.summary).font(.headline)
                                ForEach(proposal.mutations) { mutation in
                                    LabeledContent(mutation.label) { GuideMutationValueView(mutation: mutation) }
                                }
                                HStack {
                                    Button(NSLocalizedString("不应用", comment: ""), role: .cancel) { controller.rejectPendingProposal() }
                                    Spacer()
                                    Button(NSLocalizedString("确认应用", comment: "")) { controller.confirmPendingProposal() }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                    if controller.isAwaitingToolContinuation {
                        HStack {
                            Button(NSLocalizedString("继续查找", comment: "")) { controller.continueToolCalls() }
                            Button(NSLocalizedString("停止查找", comment: "")) { controller.finishToolCalls() }
                        }
                    }
                    if controller.lastError != nil {
                        Button(NSLocalizedString("重试", comment: "")) { controller.retryLastResponse() }
                        if controller.canRetryWithBuiltIn {
                            Button(NSLocalizedString("使用内置向导重试", comment: "")) { controller.retryWithBuiltIn() }
                        }
                    }
                }
            }
            TextField(NSLocalizedString("询问当前页面", comment: ""), text: $input, axis: .vertical)
                .lineLimit(2...6)
            HStack {
                Spacer()
                if controller.isResponding {
                    Button(NSLocalizedString("停止", comment: "")) { controller.cancel() }
                } else {
                    Button(NSLocalizedString("发送", comment: "")) {
                        let text = input
                        input = ""
                        controller.send(text)
                    }
                    .disabled(input.isEmpty || controller.pendingProposal != nil || controller.isRestoringHistory || controller.isAwaitingToolContinuation)
                }
            }
        }
        .padding()
        .confirmationDialog(NSLocalizedString("撤销修改", comment: ""), isPresented: $confirmsUndo, titleVisibility: .visible) {
            Button(NSLocalizedString("撤销修改", comment: ""), role: .destructive) { controller.undoLastChange() }
        } message: {
            Text(NSLocalizedString("撤销会恢复上一次修改前的设置。", comment: ""))
        }
        .confirmationDialog(NSLocalizedString("清空对话", comment: ""), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(NSLocalizedString("清空", comment: ""), role: .destructive) { controller.clear() }
        }
    }
}

private struct MacGuideModelPicker: View {
    @ObservedObject var router: GuideModelRouter
    @ObservedObject private var configuration = AppConfigStore.shared
    var body: some View {
        Menu {
            Button(NSLocalizedString("内置向导", comment: "")) { router.useBuiltIn() }
            ForEach(router.availableUserModels) { model in
                Button(model.model.displayName) { router.selectUserModel(model) }
            }
        } label: {
            Text(configuration.guidePreferredRoute == GuideRoute.userModel.rawValue
                 ? router.selectedUserModel?.model.displayName ?? NSLocalizedString("选择模型", comment: "")
                 : NSLocalizedString("内置向导", comment: ""))
        }
    }
}

private struct MacGuideStreamingText: View {
    @ObservedObject var state: GuideStreamingState
    var body: some View {
        if state.messageID != nil {
            Text(state.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

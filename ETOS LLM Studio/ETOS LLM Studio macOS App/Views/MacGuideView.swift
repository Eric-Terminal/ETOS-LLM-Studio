import ETOSCore
import SwiftUI

struct MacGuideView: View {
    @ObservedObject private var controller = MacGuideSession.shared.controller
    @Environment(\.openSettings) private var openSettings
    @State private var input = ""
    @State private var hasQuestion = false
    @State private var confirmsClear = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(NSLocalizedString("使用助手", value: "App Guide", comment: "助手标题"), systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                MacGuideModelPicker(router: controller.router)
                GuideUndoButton(controller: controller)
                    .disabled(!controller.canUndo || controller.isResponding)
                Button { confirmsClear = true } label: {
                    Label(NSLocalizedString("清空对话", value: "Clear Conversation", comment: "清空助手对话"), systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .disabled(controller.messages.isEmpty || controller.isResponding)
            }
            .padding()
            Divider()
            MacGuideTranscript(controller: controller)
            Divider()
            if let proposal = controller.pendingProposal {
                VStack(alignment: .leading) {
                    Text(proposal.summary).font(.headline)
                    ScrollView {
                        VStack {
                            ForEach(proposal.mutations) { mutation in
                                LabeledContent(mutation.label) { GuideMutationValueView(mutation: mutation) }
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    HStack {
                        Button(NSLocalizedString("不应用", value: "Skip", comment: "拒绝修改"), role: .cancel) { controller.rejectPendingProposal() }
                        Spacer()
                        Button(NSLocalizedString("确认应用", value: "Apply Changes", comment: "确认修改")) { controller.confirmPendingProposal() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            if controller.isAwaitingToolContinuation {
                VStack(alignment: .leading) {
                    Text(NSLocalizedString("需要继续查找吗？", value: "Keep looking?", comment: "助手继续查找标题")).font(.headline)
                    Text(NSLocalizedString("这个问题涉及的设置稍微多一点，需要我继续往下排查吗？", value: "There are a few more settings to check. Would you like me to keep looking?", comment: "助手继续查找说明"))
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button(NSLocalizedString("不用了", value: "No Thanks", comment: "结束查找")) { controller.finishToolCalls() }
                        Button(NSLocalizedString("继续查找", value: "Keep Looking", comment: "继续查找")) { controller.continueToolCalls() }
                    }
                }
                .padding()
            }
            HStack(alignment: .bottom) {
                TextField(NSLocalizedString("问问软件怎么用，或让我带你去设置…", value: "Ask how to use the app or find a setting…", comment: "助手输入提示"), text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .onChange(of: input) { _, value in hasQuestion = value.contains { !$0.isWhitespace } }
                    .onSubmit(send)
                if controller.isResponding {
                    Button { controller.cancel() } label: {
                        Label(NSLocalizedString("停止", value: "Stop", comment: "停止回答"), systemImage: "stop.fill")
                    }
                    .labelStyle(.iconOnly)
                } else {
                    Button(action: send) {
                        Label(NSLocalizedString("发送", value: "Send", comment: "发送提问"), systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle).labelStyle(.iconOnly)
                    .disabled(!canSend)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding()
        }
        .modifier(GuideConversationFallbackContext())
        .onAppear { MacGuideSession.shared.attach(openSettings) }
        .confirmationDialog(NSLocalizedString("清空对话", value: "Clear Conversation", comment: "清空助手确认"), isPresented: $confirmsClear, titleVisibility: .visible) {
            Button(NSLocalizedString("清空", value: "Clear", comment: "确认清空"), role: .destructive) { controller.clear() }
        }
    }

    private var canSend: Bool {
        hasQuestion && !controller.isResponding &&
        !controller.isRestoringHistory && controller.pendingProposal == nil && !controller.isAwaitingToolContinuation
    }

    private func send() {
        guard canSend else { return }
        controller.send(input)
        input = ""
    }
}

private struct MacGuideModelPicker: View {
    @ObservedObject var router: GuideModelRouter
    @ObservedObject private var configuration = AppConfigStore.shared

    var body: some View {
        let builtIn = NSLocalizedString("内置免费向导", value: "Free Built-in Guide", comment: "内置模型")
        Menu {
            Button(builtIn) { router.useBuiltIn() }
            ForEach(router.availableUserModels) { model in
                Button(model.model.displayName) { router.selectUserModel(model) }
            }
        } label: {
            Text(configuration.guidePreferredRoute == GuideRoute.userModel.rawValue
                 ? router.selectedUserModel?.model.displayName ?? NSLocalizedString("选择模型", value: "Choose Model", comment: "选择回答模型") : builtIn)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(NSLocalizedString("选择向导模型", value: "Choose Guide Model", comment: "助手模型菜单"))
    }
}

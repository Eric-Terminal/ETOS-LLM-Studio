import SwiftUI

@MainActor
private final class DeviceMessageFormModel: ObservableObject {
    @Published private(set) var selections: [String: Set<String>] = [:]
    @Published private(set) var text: [String: String] = [:]
    @Published private(set) var canSubmit = false
    private var missingRequired = Set<String>()
    private var prepared = false

    func prepare(_ message: DeviceMessage) async {
        guard !prepared else { return }
        prepared = true
        missingRequired = await Task.detached {
            Set(message.questions.filter(\.required).map(\.id))
        }.value
        canSubmit = missingRequired.isEmpty
    }

    func select(_ option: String, question: SurveyQuestion) {
        if question.type == .singleSelect {
            selections[question.id] = selections[question.id] == [option] ? [] : [option]
            text[question.id] = ""
        } else if selections[question.id, default: []].contains(option) {
            selections[question.id, default: []].remove(option)
        } else {
            selections[question.id, default: []].insert(option)
        }
        updateValidity(question)
    }

    func setText(_ value: String, question: SurveyQuestion) {
        text[question.id] = String(value.prefix(1000))
        if AppToolAskUserInputAnswerPolicy.shouldClearSelectedOptionsAfterTypingCustomText(type: question.type, customText: value) {
            selections[question.id] = []
        }
        updateValidity(question)
    }

    private func updateValidity(_ question: SurveyQuestion) {
        if question.required {
            if AppToolAskUserInputAnswerPolicy.hasAnswer(selectedOptionIDs: selections[question.id, default: []], customText: text[question.id]) {
                missingRequired.remove(question.id)
            } else {
                missingRequired.insert(question.id)
            }
        }
        canSubmit = missingRequired.isEmpty
    }

    func answers(for message: DeviceMessage) async -> [DeviceMessageAnswer] {
        let selections = selections
        let text = text
        return await Task.detached {
            message.questions.map { question in
                DeviceMessageAnswer(
                    questionID: question.id,
                    selectedOptionIDs: selections[question.id, default: []].sorted(),
                    otherText: AppToolAskUserInputAnswerPolicy.normalizedCustomText(text[question.id])
                )
            }
        }.value
    }
}

/// 私密表单复用结构化问答的数据与选择规则，原始内容不开放给页面向导。
public struct DeviceMessageResponseView: View {
    public let message: DeviceMessage
    @ObservedObject private var manager: DeviceMessageManager
    @StateObject private var form = DeviceMessageFormModel()
    @State private var confirmsDismissal = false

    public init(message: DeviceMessage, manager: DeviceMessageManager = .shared) {
        self.message = message
        self.manager = manager
    }

    public var body: some View {
        Form {
            Section {
                Text(message.title).font(.headline)
                if !message.description.isEmpty { Text(message.description) }
            } footer: {
                Text(NSLocalizedString("feedback.device.privacy", value: "Only the developer can read your response on the feedback server. It will not be posted to GitHub. You can choose not to answer.", comment: "私密回复说明"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(message.questions) { question in
                Section {
                    ForEach(question.options) { option in
                        Button {
                            form.select(option.id, question: question)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if let description = option.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if form.selections[question.id, default: []].contains(option.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if question.allowOther {
                        TextField(
                            NSLocalizedString("feedback.device.answer", value: "Your response", comment: "私密回复输入框"),
                            text: Binding(get: { form.text[question.id, default: ""] }, set: { form.setText($0, question: question) }),
                            axis: .vertical
                        )
                    }
                } header: {
                    Text(question.question)
                } footer: {
                    if question.required {
                        Text(NSLocalizedString("feedback.device.required", value: "Required", comment: "必答问题"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(manager.isSubmitting || manager.isClosed)
            }
            Section {
                if manager.isSubmitting {
                    ProgressView(NSLocalizedString("正在提交…", value: "Submitting…", comment: "提交进度"))
                }
                if let error = manager.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if !manager.isClosed {
                    Button(message.questions.isEmpty
                           ? NSLocalizedString("feedback.device.acknowledge", value: "Got it", comment: "确认收到留言")
                           : NSLocalizedString("feedback.device.submit", value: "Send response", comment: "提交私密回答")) {
                        Task {
                            let answers = await form.answers(for: message)
                            await manager.respond(answers: answers)
                        }
                    }
                    .disabled(!form.canSubmit || manager.isSubmitting)
                }
                Button(NSLocalizedString("稍后再说", value: "Later", comment: "推迟处理留言")) { manager.postpone() }
                    .disabled(manager.isSubmitting)
                if !manager.isClosed {
                    Button(NSLocalizedString("feedback.device.decline", value: "Do not ask again", comment: "关闭当前留言"), role: .destructive) {
                        confirmsDismissal = true
                    }
                    .disabled(manager.isSubmitting)
                }
            } footer: {
                Text(NSLocalizedString("feedback.device.completion", value: "Once sent, this message closes automatically. Later keeps it for your next launch.", comment: "留言完成说明"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(NSLocalizedString("feedback.device.title", value: "Developer message", comment: "设备留言标题"))
        .interactiveDismissDisabled()
        .task { await form.prepare(message) }
        .alert(NSLocalizedString("feedback.device.decline_confirm", value: "Close this message without answering?", comment: "拒绝回答确认"), isPresented: $confirmsDismissal) {
            Button(NSLocalizedString("取消", value: "Cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("feedback.device.decline", value: "Do not ask again", comment: ""), role: .destructive) {
                Task { await manager.respond(answers: [], dismissed: true) }
            }
        }
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "feedback-device-message-\(message.key)"),
            title: NSLocalizedString("feedback.device.title", value: "Developer message", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", value: "Feedback", comment: ""))],
            settings: [
                .readOnly("question_count", label: NSLocalizedString("feedback.device.question_count", value: "Question count", comment: "向导只读题目数"), value: { .int(message.questions.count) }),
                .readOnly("submitting", label: NSLocalizedString("正在提交…", value: "Submitting…", comment: ""), value: { .bool(manager.isSubmitting) })
            ]
        )
    }
}

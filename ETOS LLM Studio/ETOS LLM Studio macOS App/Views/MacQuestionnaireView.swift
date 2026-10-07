import Combine
import ETOSCore
import SwiftUI

struct MacQuestionnaireView: View {
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @ObservedObject var model: MacQuestionnaireModel

    var body: some View {
        VStack(alignment: .leading) {
            Text(model.request.title ?? NSLocalizedString("询问用户选项", comment: "")).font(.headline)
            if let description = model.request.description {
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
            Form {
                ForEach(model.request.questions) { question in
                    Section {
                        ForEach(question.options) { option in
                            Toggle(isOn: Binding(
                                get: { model.selections[question.id, default: []].contains(option.id) },
                                set: { selected in model.select(option.id, selected: selected, for: question) }
                            )) {
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if let description = option.description {
                                        Text(description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(model.customTextBlocksSelection.contains(question.id))
                        }
                        if question.allowOther {
                            TextField(NSLocalizedString("其他（可选）", comment: ""), text: Binding(
                                get: { model.otherText[question.id] ?? "" },
                                set: { model.setCustomText($0, for: question) }
                            ), axis: .vertical)
                        }
                    } header: { Text(question.question) }
                    footer: {
                        Text(question.required ? NSLocalizedString("必填", comment: "") : NSLocalizedString("可跳过", comment: ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!model.isPrepared || model.isSubmitting)
            HStack {
                Button(NSLocalizedString("取消", comment: "")) { submit(cancelled: true) }
                    .disabled(model.isSubmitting)
                Spacer()
                if model.isSubmitting { ProgressView().controlSize(.small) }
                Button(model.request.submitLabel) { submit(cancelled: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSubmit || model.isSubmitting)
            }
        }
        .padding()
        .frame(minHeight: 220, idealHeight: 320, maxHeight: 420)
        .task(id: ObjectIdentifier(model)) { await model.prepare() }
    }

    private func submit(cancelled: Bool) {
        Task {
            guard let answers = await model.makeAnswers(cancelled: cancelled) else { return }
            await workspace.submitQuestionnaire(model.request, answers: answers, cancelled: cancelled)
        }
    }
}

@MainActor
final class MacQuestionnaireModel: ObservableObject {
    let request: AppToolAskUserInputRequest
    @Published private(set) var selections: [String: Set<String>] = [:]
    @Published private(set) var otherText: [String: String] = [:]
    @Published private(set) var customTextBlocksSelection: Set<String> = []
    @Published private(set) var isPrepared = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var canSubmit = false
    private var unansweredRequired: Set<String> = []
    private var isPreparing = false

    init(request: AppToolAskUserInputRequest) { self.request = request }

    func prepare() async {
        guard !isPrepared, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        let questions = request.questions
        unansweredRequired = await Task.detached { Set(questions.filter(\.required).map(\.id)) }.value
        isPrepared = true
        canSubmit = unansweredRequired.isEmpty
    }

    func select(_ optionID: String, selected: Bool, for question: AppToolAskUserInputQuestion) {
        guard !isSubmitting, AppToolAskUserInputAnswerPolicy.canSelectOption(type: question.type, customText: otherText[question.id]) else { return }
        if selected {
            if question.type == .singleSelect { selections[question.id] = [optionID] }
            else { selections[question.id, default: []].insert(optionID) }
        } else { selections[question.id]?.remove(optionID) }
        updateValidity(question)
    }

    func setCustomText(_ text: String, for question: AppToolAskUserInputQuestion) {
        guard !isSubmitting else { return }
        otherText[question.id] = text
        if AppToolAskUserInputAnswerPolicy.shouldClearSelectedOptionsAfterTypingCustomText(type: question.type, customText: text) {
            selections[question.id] = []
            customTextBlocksSelection.insert(question.id)
        } else {
            customTextBlocksSelection.remove(question.id)
        }
        updateValidity(question)
    }

    private func updateValidity(_ question: AppToolAskUserInputQuestion) {
        if question.required {
            if AppToolAskUserInputAnswerPolicy.hasAnswer(selectedOptionIDs: selections[question.id, default: []], customText: otherText[question.id]) {
                unansweredRequired.remove(question.id)
            } else { unansweredRequired.insert(question.id) }
        }
        canSubmit = isPrepared && unansweredRequired.isEmpty
    }

    func makeAnswers(cancelled: Bool) async -> [AppToolAskUserInputQuestionAnswer]? {
        guard !isSubmitting, cancelled || canSubmit else { return nil }
        isSubmitting = true
        if cancelled { return [] }
        let questions = request.questions
        let selections = selections
        let texts = otherText
        return await Task.detached(priority: .userInitiated) {
            questions.map { question in
                let options = question.options.filter { selections[question.id, default: []].contains($0.id) }
                return AppToolAskUserInputQuestionAnswer(
                    questionID: question.id, question: question.question, type: question.type,
                    selectedOptionIDs: options.map(\.id), selectedOptionLabels: options.map(\.label),
                    otherText: question.allowOther ? AppToolAskUserInputAnswerPolicy.normalizedCustomText(texts[question.id]) : nil
                )
            }
        }.value
    }
}

// ============================================================================
// WatchContentSheets.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS 主聊天界面使用的导入、模型切换与问答 Sheet。
// ============================================================================

import SwiftUI
import Foundation
import Shared

struct WatchImportSourceView: View {
    @Binding var source: String
    let history: [String]
    let isImporting: Bool
    let title: String
    let placeholder: String
    let progressTitle: String
    let confirmTitle: String
    let onImport: () -> Void
    let onCancel: () -> Void

    private var canImport: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isImporting
    }

    var body: some View {
        Form {
            Section {
                TextField(placeholder, text: $source.watchKeyboardNewlineBinding())
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                if isImporting {
                    ProgressView(progressTitle)
                }
            }

            if !history.isEmpty {
                Section(NSLocalizedString("最近链接", comment: "")) {
                    ForEach(history, id: \.self) { item in
                        Button {
                            source = item
                        } label: {
                            HStack(spacing: 6) {
                                Text(item)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if source == item {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("取消", comment: ""), action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmTitle, action: onImport)
                    .disabled(!canImport)
            }
        }
    }
}

struct WatchQuickModelSelectorView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?

    var body: some View {
        List {
            if models.isEmpty {
                Text(NSLocalizedString("暂无可用模型，请先在设置中启用模型。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                Section(header: Text(NSLocalizedString("模型", comment: ""))) {
                    ForEach(models, id: \.id) { model in
                        Button {
                            selectedModel = model
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.model.displayName)
                                        .etFont(.subheadline.weight(.semibold))
                                    Text("\(model.provider.name) · \(model.model.modelName)")
                                        .etFont(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedModel?.id == model.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section(header: Text(NSLocalizedString("请求控制", comment: ""))) {
                    requestControlRows
                }
            }
        }
        .navigationTitle(NSLocalizedString("切换模型", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var requestControlRows: some View {
        if let selectedModel {
            let controls = selectedModel.model.requestBodyControls.filter(\.isEnabled)
            if controls.isEmpty {
                Text(NSLocalizedString("当前模型没有可用请求控制。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controls) { control in
                    NavigationLink {
                        WatchRequestBodyControlDetailView(runnableModel: selectedModel, control: control)
                    } label: {
                        Text(control.title)
                    }
                }
            }
        } else {
            Text(NSLocalizedString("请先选择模型。", comment: ""))
                .foregroundStyle(.secondary)
        }
    }
}

// 独立的请求控制快速面板，供输入框左划快捷入口使用
struct WatchQuickRequestControlsView: View {
    let runnableModel: RunnableModel

    var body: some View {
        let controls = runnableModel.model.requestBodyControls.filter(\.isEnabled)
        List {
            if controls.isEmpty {
                Text(NSLocalizedString("当前模型没有可用请求控制。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controls) { control in
                    NavigationLink {
                        WatchRequestBodyControlDetailView(runnableModel: runnableModel, control: control)
                    } label: {
                        Text(control.title)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("请求控制", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WatchRequestBodyControlDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let runnableModel: RunnableModel
    let control: ModelRequestBodyControl
    @State private var state: ModelRequestBodyControlState

    init(runnableModel: RunnableModel, control: ModelRequestBodyControl) {
        self.runnableModel = runnableModel
        self.control = control
        _state = State(initialValue: runnableModel.requestBodyControlState)
    }

    var body: some View {
        List {
            switch control.kind {
            case .toggle:
                Toggle(isOn: toggleBinding(for: control)) {
                    Text(control.title)
                }
            case .optionGroup:
                if control.options.isEmpty {
                    Text(NSLocalizedString("这个控制还没有选项。", comment: ""))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(control.options) { option in
                        Button {
                            state.selectedOptionIDsByControlID[control.id] = option.id
                            saveState()
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if selectedOptionID(for: control) == option.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(control.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("完成", comment: "")) {
                    dismiss()
                }
            }
        }
    }

    private func toggleBinding(for control: ModelRequestBodyControl) -> Binding<Bool> {
        Binding(
            get: { state.toggleValuesByControlID[control.id] ?? control.defaultIsActive },
            set: { newValue in
                state.toggleValuesByControlID[control.id] = newValue
                saveState()
            }
        )
    }

    private func selectedOptionID(for control: ModelRequestBodyControl) -> String {
        state.selectedOptionIDsByControlID[control.id]
            ?? control.defaultOptionID
            ?? control.options.first?.id
            ?? ""
    }

    private func saveState() {
        state = ModelRequestBodyControlCompiler.normalized(state, for: runnableModel.model.requestBodyControls)
        runnableModel.saveRequestBodyControlState(state)
    }
}

struct WatchAskUserInputView: View {
    let request: AppToolAskUserInputRequest
    let onSubmit: ([AppToolAskUserInputQuestionAnswer]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedOptionIDsByQuestion: [String: Set<String>] = [:]
    @State private var otherTextByQuestion: [String: String] = [:]
    @State private var currentQuestionIndex = 0
    @State private var hasHandledAction = false

    private var canSubmit: Bool {
        request.questions.allSatisfy { question in
            !question.required || isQuestionAnswered(question)
        }
    }

    private var currentQuestion: AppToolAskUserInputQuestion? {
        guard request.questions.indices.contains(currentQuestionIndex) else { return nil }
        return request.questions[currentQuestionIndex]
    }

    private var progressText: String {
        let total = max(request.questions.count, 1)
        let current = min(currentQuestionIndex + 1, total)
        return "\(current) / \(total)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let title = request.title, !title.isEmpty {
                        Text(title)
                            .etFont(.headline)
                    } else {
                        Text(NSLocalizedString("请补充信息", comment: ""))
                            .etFont(.headline)
                    }
                    if let description = request.description, !description.isEmpty {
                        Text(description)
                            .etFont(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(progressText)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let question = currentQuestion {
                    Section {
                        ForEach(question.options) { option in
                            Button {
                                toggleOption(question: question, optionID: option.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: optionIconName(question: question, optionID: option.id))
                                        .foregroundStyle(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.label)
                                            .foregroundStyle(.primary)
                                        if let description = option.description, !description.isEmpty {
                                            Text(description)
                                                .etFont(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                !AppToolAskUserInputAnswerPolicy.canSelectOption(
                                    type: question.type,
                                    customText: otherTextByQuestion[question.id]
                                )
                            )
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Text(question.question)
                            if question.required {
                                Text("*")
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Section {
                        TextField(
                            NSLocalizedString("请输入自定义偏好", comment: ""),
                            text: Binding(
                                get: { otherTextByQuestion[question.id, default: ""] },
                                set: { newValue in
                                    otherTextByQuestion[question.id] = newValue
                                    if AppToolAskUserInputAnswerPolicy.shouldClearSelectedOptionsAfterTypingCustomText(
                                        type: question.type,
                                        customText: newValue
                                    ) {
                                        selectedOptionIDsByQuestion[question.id] = []
                                    }
                                }
                            )
                        )
                        Button(skipButtonTitle(for: question)) {
                            handleSkipOrSubmit(for: question)
                        }
                        .disabled(!canContinue(from: question))
                    }
                } else {
                    Section {
                        Text(NSLocalizedString("暂无可填写问题", comment: ""))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("结构化问答", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        goToPreviousQuestion()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(currentQuestionIndex == 0)
                    .opacity(currentQuestionIndex == 0 ? 0.45 : 1)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) {
                        handleCancelAndDismiss()
                    }
                }
            }
            .onAppear {
                resetSelectionState()
                hasHandledAction = false
            }
            .onChange(of: request) {
                resetSelectionState()
                hasHandledAction = false
            }
            .onDisappear {
                guard !hasHandledAction else { return }
                onCancel()
            }
        }
    }

    private func optionIconName(question: AppToolAskUserInputQuestion, optionID: String) -> String {
        let isSelected = selectedOptionIDsByQuestion[question.id, default: []].contains(optionID)
        switch question.type {
        case .singleSelect:
            return isSelected ? "largecircle.fill.circle" : "circle"
        case .multiSelect:
            return isSelected ? "checkmark.square.fill" : "square"
        }
    }

    private func toggleOption(question: AppToolAskUserInputQuestion, optionID: String) {
        guard AppToolAskUserInputAnswerPolicy.canSelectOption(
            type: question.type,
            customText: otherTextByQuestion[question.id]
        ) else {
            return
        }
        switch question.type {
        case .singleSelect:
            let current = selectedOptionIDsByQuestion[question.id, default: []]
            if current.contains(optionID) {
                selectedOptionIDsByQuestion[question.id] = []
            } else {
                selectedOptionIDsByQuestion[question.id] = [optionID]
                autoAdvanceIfNeeded(afterSelecting: question)
            }
        case .multiSelect:
            var current = selectedOptionIDsByQuestion[question.id, default: []]
            if current.contains(optionID) {
                current.remove(optionID)
            } else {
                current.insert(optionID)
            }
            selectedOptionIDsByQuestion[question.id] = current
        }
    }

    private func autoAdvanceIfNeeded(afterSelecting question: AppToolAskUserInputQuestion) {
        guard question.type == .singleSelect else { return }
        if isLastQuestion(question) {
            if canSubmit {
                submit()
            }
            return
        }
        guard canContinue(from: question) else { return }
        currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
    }

    private func goToPreviousQuestion() {
        guard currentQuestionIndex > 0 else { return }
        currentQuestionIndex -= 1
    }

    private func handleSkipOrSubmit(for question: AppToolAskUserInputQuestion) {
        guard canContinue(from: question) else { return }
        if isLastQuestion(question) {
            submit()
            return
        }
        currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
    }

    private func isQuestionAnswered(_ question: AppToolAskUserInputQuestion) -> Bool {
        let selected = selectedOptionIDsByQuestion[question.id] ?? []
        return AppToolAskUserInputAnswerPolicy.hasAnswer(
            selectedOptionIDs: selected,
            customText: otherTextByQuestion[question.id]
        )
    }

    private func canContinue(from question: AppToolAskUserInputQuestion) -> Bool {
        if isLastQuestion(question) {
            return canSubmit
        }
        return true
    }

    private func isLastQuestion(_ question: AppToolAskUserInputQuestion) -> Bool {
        request.questions.last?.id == question.id
    }

    private func skipButtonTitle(for question: AppToolAskUserInputQuestion) -> String {
        if isLastQuestion(question) {
            return request.submitLabel
        }
        return isQuestionAnswered(question) ? NSLocalizedString("下一题", comment: "") : NSLocalizedString("跳过", comment: "")
    }

    private func submit() {
        let answers = request.questions.map { question -> AppToolAskUserInputQuestionAnswer in
            let selectedIDs = question.options
                .map(\.id)
                .filter { selectedOptionIDsByQuestion[question.id, default: []].contains($0) }
            let selectedLabels = question.options
                .filter { selectedOptionIDsByQuestion[question.id, default: []].contains($0.id) }
                .map(\.label)
            let otherText = AppToolAskUserInputAnswerPolicy.normalizedCustomText(
                otherTextByQuestion[question.id]
            )
            return AppToolAskUserInputQuestionAnswer(
                questionID: question.id,
                question: question.question,
                type: question.type,
                selectedOptionIDs: selectedIDs,
                selectedOptionLabels: selectedLabels,
                otherText: otherText
            )
        }
        hasHandledAction = true
        onSubmit(answers)
        dismiss()
    }

    private func handleCancelAndDismiss() {
        hasHandledAction = true
        onCancel()
        dismiss()
    }

    private func resetSelectionState() {
        selectedOptionIDsByQuestion = [:]
        otherTextByQuestion = [:]
        currentQuestionIndex = 0
    }
}

struct FullErrorContentView: View {
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .etFont(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(NSLocalizedString("完整响应", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) { dismiss() }
                }
            }
        }
    }
}

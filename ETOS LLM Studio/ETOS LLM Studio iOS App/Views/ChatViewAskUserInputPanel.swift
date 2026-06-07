// ============================================================================
// ChatViewAskUserInputPanel.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载 ChatView 中工具请求用户补充信息时使用的问答输入面板。
// ============================================================================

import SwiftUI
import UIKit
import ETOSCore

struct AskUserInputComposerPanel: View {
    let request: AppToolAskUserInputRequest
    let submitAction: ([AppToolAskUserInputQuestionAnswer]) -> Void
    let cancelAction: () -> Void

    @State private var selectedOptionIDsByQuestion: [String: Set<String>] = [:]
    @State private var otherTextByQuestion: [String: String] = [:]
    @State private var currentQuestionIndex = 0
    @State private var measuredQuestionContentHeight: CGFloat = 0

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

    private var questionContentMaxHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.42, 340)
    }

    private var questionContentFrameHeight: CGFloat {
        let measured = measuredQuestionContentHeight
        guard measured > 1 else { return 180 }
        return min(max(measured + 4, 120), questionContentMaxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar

            if let question = currentQuestion {
                questionContent(for: question)
                navigationInputBar(for: question)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("暂无可填写问题", comment: ""))
                        .etFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
        .onAppear {
            resetSelectionState()
        }
        .onChange(of: request) {
            resetSelectionState()
        }
        .onChange(of: currentQuestionIndex) {
            measuredQuestionContentHeight = 0
        }
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Button(action: goToPreviousQuestion) {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(currentQuestionIndex == 0)
                .opacity(currentQuestionIndex == 0 ? 0.45 : 1)

                Spacer(minLength: 6)

                HStack(spacing: 8) {
                    Text(progressText)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("取消", comment: ""), action: cancelAction)
                        .etFont(.footnote)
                        .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(request.title ?? NSLocalizedString("请补充信息", comment: ""))
                    .etFont(.headline)
                if let description = request.description, !description.isEmpty {
                    Text(description)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
            .padding(.leading, 2)
        }
    }

    private func questionContent(for question: AppToolAskUserInputQuestion) -> some View {
        ScrollView {
            questionBlock(question)
                .padding(.vertical, 2)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: AskUserInputQuestionContentHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                )
        }
        .frame(height: questionContentFrameHeight, alignment: .top)
        .onPreferenceChange(AskUserInputQuestionContentHeightPreferenceKey.self) { newHeight in
            measuredQuestionContentHeight = newHeight
        }
    }

    @ViewBuilder
    private func questionBlock(_ question: AppToolAskUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(question.question)
                    .etFont(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if question.required {
                    Text("*")
                        .foregroundStyle(.red)
                        .etFont(.subheadline.weight(.bold))
                }
            }

            ForEach(question.options) { option in
                Button {
                    toggleOption(question: question, optionID: option.id)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: optionIconName(question: question, optionID: option.id))
                            .foregroundStyle(.blue)
                            .frame(width: 20, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .etFont(.subheadline)
                                .foregroundStyle(.primary)
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .etFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .disabled(
                    !AppToolAskUserInputAnswerPolicy.canSelectOption(
                        type: question.type,
                        customText: otherTextByQuestion[question.id]
                    )
                )
            }
        }
        .padding(.vertical, 2)
    }

    private func navigationInputBar(for question: AppToolAskUserInputQuestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(.secondary)

            TextField(NSLocalizedString("请输入自定义偏好", comment: ""),
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
                ),
                axis: .vertical
            )
            .lineLimit(1...3)
            .textFieldStyle(.plain)

            Button(skipButtonTitle(for: question)) {
                handleSkipOrSubmit(for: question)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canContinue(from: question))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
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
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
        }
    }

    private func goToPreviousQuestion() {
        guard currentQuestionIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex -= 1
        }
    }

    private func handleSkipOrSubmit(for question: AppToolAskUserInputQuestion) {
        guard canContinue(from: question) else { return }
        if isLastQuestion(question) {
            submit()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
        }
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
        submitAction(answers)
    }

    private func resetSelectionState() {
        selectedOptionIDsByQuestion = [:]
        otherTextByQuestion = [:]
        currentQuestionIndex = 0
        measuredQuestionContentHeight = 0
    }
}

private struct AskUserInputQuestionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

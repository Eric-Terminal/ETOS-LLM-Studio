// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio Watch App 主视图文件 
//
// 功能特性:
// - 应用的主界面，负责组合聊天列表和输入框
// - 连接 ChatViewModel 来驱动视图
// - 管理 Sheet 和导航
// ============================================================================

import SwiftUI
import Foundation
import MarkdownUI
import Shared
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreText)
import CoreText
#endif

enum WatchChatInputActionState: Equatable {
    case stop
    case send
    case quickRetry
    case speechInput
    case inactive

    static func resolve(isSending: Bool, hasSendableContent: Bool, canQuickRetry: Bool, isSpeechInputEnabled: Bool) -> Self {
        if isSending {
            return .stop
        }
        if hasSendableContent {
            return .send
        }
        if canQuickRetry {
            return .quickRetry
        }
        if isSpeechInputEnabled {
            return .speechInput
        }
        return .inactive
    }

    var systemImageName: String {
        switch self {
        case .stop:
            return "stop.circle.fill"
        case .send, .inactive:
            return "arrow.up"
        case .quickRetry:
            return "arrow.clockwise"
        case .speechInput:
            return "mic.fill"
        }
    }

    var isDisabled: Bool {
        self == .inactive
    }
}


enum WatchNativeNavigationDestination: String, Identifiable {
    case chat
    case settings

    var id: String { rawValue }
}


struct WatchMessageActionsNavigationTarget: Identifiable, Hashable {
    let id: UUID
}


enum WatchImportSourceHistory {
    nonisolated static let limit = 5

    nonisolated static func values(from rawValue: String, fallback: String = "") -> [String] {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return normalized([fallback])
        }
        let history = normalized(decoded)
        return history.isEmpty ? normalized([fallback]) : history
    }

    nonisolated static func appending(_ source: String, to history: [String]) -> [String] {
        normalized([source] + history)
    }

    nonisolated static func rawValue(for history: [String]) -> String {
        let normalizedHistory = normalized(history)
        guard let data = try? JSONEncoder().encode(normalizedHistory),
              let rawValue = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return rawValue
    }

    nonisolated static func normalized(_ sources: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for source in sources {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == limit { break }
        }
        return result
    }
}


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

    var canImport: Bool {
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
    @Environment(\.dismiss) var dismiss

    let models: [RunnableModel]
    @Binding var selectedModel: RunnableModel?

    var body: some View {
        List {
            if models.isEmpty {
                Text(NSLocalizedString("暂无可用模型，请先在设置中启用模型。", comment: ""))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models, id: \.id) { model in
                    Button {
                        selectedModel = model
                        dismiss()
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
        }
        .navigationTitle(NSLocalizedString("切换模型", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}


struct WatchAskUserInputView: View {
    let request: AppToolAskUserInputRequest
    let onSubmit: ([AppToolAskUserInputQuestionAnswer]) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) var dismiss
    @State var selectedOptionIDsByQuestion: [String: Set<String>] = [:]
    @State var otherTextByQuestion: [String: String] = [:]
    @State var currentQuestionIndex = 0
    @State var hasHandledAction = false

    var canSubmit: Bool {
        request.questions.allSatisfy { question in
            !question.required || isQuestionAnswered(question)
        }
    }

    var currentQuestion: AppToolAskUserInputQuestion? {
        guard request.questions.indices.contains(currentQuestionIndex) else { return nil }
        return request.questions[currentQuestionIndex]
    }

    var progressText: String {
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
                        HStack(spacing: 6) {
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
                                )
                            )

                            Button(skipButtonTitle(for: question)) {
                                handleSkipOrSubmit(for: question)
                            }
                            .disabled(!canContinue(from: question))
                        }
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

    func optionIconName(question: AppToolAskUserInputQuestion, optionID: String) -> String {
        let isSelected = selectedOptionIDsByQuestion[question.id, default: []].contains(optionID)
        switch question.type {
        case .singleSelect:
            return isSelected ? "largecircle.fill.circle" : "circle"
        case .multiSelect:
            return isSelected ? "checkmark.square.fill" : "square"
        }
    }

    func toggleOption(question: AppToolAskUserInputQuestion, optionID: String) {
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

    func autoAdvanceIfNeeded(afterSelecting question: AppToolAskUserInputQuestion) {
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

    func goToPreviousQuestion() {
        guard currentQuestionIndex > 0 else { return }
        currentQuestionIndex -= 1
    }

    func handleSkipOrSubmit(for question: AppToolAskUserInputQuestion) {
        guard canContinue(from: question) else { return }
        if isLastQuestion(question) {
            submit()
            return
        }
        currentQuestionIndex = min(currentQuestionIndex + 1, request.questions.count - 1)
    }

    func isQuestionAnswered(_ question: AppToolAskUserInputQuestion) -> Bool {
        let selected = selectedOptionIDsByQuestion[question.id] ?? []
        return AppToolAskUserInputAnswerPolicy.hasAnswer(
            selectedOptionIDs: selected,
            customText: otherTextByQuestion[question.id]
        )
    }

    func canContinue(from question: AppToolAskUserInputQuestion) -> Bool {
        if isLastQuestion(question) {
            return canSubmit
        }
        return true
    }

    func isLastQuestion(_ question: AppToolAskUserInputQuestion) -> Bool {
        request.questions.last?.id == question.id
    }

    func skipButtonTitle(for question: AppToolAskUserInputQuestion) -> String {
        if isLastQuestion(question) {
            return request.submitLabel
        }
        return isQuestionAnswered(question) ? NSLocalizedString("下一题", comment: "") : NSLocalizedString("跳过", comment: "")
    }

    func submit() {
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

    func handleCancelAndDismiss() {
        hasHandledAction = true
        onCancel()
        dismiss()
    }

    func resetSelectionState() {
        selectedOptionIDsByQuestion = [:]
        otherTextByQuestion = [:]
        currentQuestionIndex = 0
    }
}


// MARK: - 完整错误响应辅助类型

/// 用于包装完整错误内容的 Identifiable 结构
struct FullErrorContentWrapper: Identifiable {
    let id = UUID()
    let content: String
}


struct MessageJumpRequest: Equatable {
    let token = UUID()
    let messageID: UUID
}


/// 完整错误响应内容视图
struct FullErrorContentView: View {
    let content: String
    @Environment(\.dismiss) var dismiss
    
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


extension View {
    @ViewBuilder
    func etFont(_ font: Font?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font))
    }

    @ViewBuilder
    func etFont(_ font: Font?, sampleText: String?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font, sampleText: sampleText))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font, sampleText: String?) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font, sampleText: sampleText))
    }
}


extension Text {
    @ViewBuilder
    func etFont(_ font: Font?) -> some View {
        if let font {
            self.font(AppFontAdapter.adaptedFont(from: font, sampleText: TextSampleExtractor.extract(from: self)))
        } else {
            self.font(nil)
        }
    }

    @ViewBuilder
    func etFont(_ font: Font) -> some View {
        self.font(AppFontAdapter.adaptedFont(from: font, sampleText: TextSampleExtractor.extract(from: self)))
    }
}


enum TextSampleExtractor {
    static let maxDepth = 10

    static func extract(from text: Text) -> String? {
        let strings = collectStrings(from: text, depth: 0)
        guard !strings.isEmpty else { return nil }

        var ordered: [String] = []
        var seen = Set<String>()
        for item in strings {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }

        guard !ordered.isEmpty else { return nil }
        return ordered.joined(separator: " ")
    }

    static func collectStrings(from value: Any, depth: Int) -> [String] {
        guard depth <= maxDepth else { return [] }

        if let string = value as? String {
            return [string]
        }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let childValue = mirror.children.first?.value else { return [] }
            return collectStrings(from: childValue, depth: depth + 1)
        }

        var results: [String] = []
        for child in mirror.children {
            if shouldSkip(label: child.label) {
                continue
            }
            results.append(contentsOf: collectStrings(from: child.value, depth: depth + 1))
        }
        return results
    }

    static func shouldSkip(label: String?) -> Bool {
        switch label {
        case "modifiers", "table", "bundle", "arguments", "hasFormatting":
            return true
        default:
            return false
        }
    }
}


struct FontDescriptorInfo {
    let raw: String
    let lowercasedRaw: String

    init(rawDescription: String) {
        self.raw = rawDescription
        self.lowercasedRaw = rawDescription.lowercased()
    }

    var explicitSize: CGFloat? {
        firstMatchedNumber(after: "size:")
            ?? firstMatchedNumber(after: "size ")
    }

    var textStyle: Font.TextStyle? {
        if lowercasedRaw.contains("caption2") { return .caption2 }
        if lowercasedRaw.contains("caption") { return .caption }
        if lowercasedRaw.contains("footnote") { return .footnote }
        if lowercasedRaw.contains("callout") { return .callout }
        if lowercasedRaw.contains("subheadline") { return .subheadline }
        if lowercasedRaw.contains("headline") { return .headline }
        if lowercasedRaw.contains("title3") { return .title3 }
        if lowercasedRaw.contains("title2") { return .title2 }
        if lowercasedRaw.contains("largetitle") || lowercasedRaw.contains("large title") { return .largeTitle }
        if lowercasedRaw.contains("title") { return .title }
        if lowercasedRaw.contains("body") { return .body }
        return nil
    }

    var isItalic: Bool {
        lowercasedRaw.contains("italic")
    }

    var isMonospaced: Bool {
        lowercasedRaw.contains("monospaced") || lowercasedRaw.contains("mono")
    }

    var weight: Font.Weight? {
        if lowercasedRaw.contains("black") { return .black }
        if lowercasedRaw.contains("heavy") { return .heavy }
        if lowercasedRaw.contains("semibold") { return .semibold }
        if lowercasedRaw.contains("bold") { return .bold }
        if lowercasedRaw.contains("medium") { return .medium }
        if lowercasedRaw.contains("light") { return .light }
        if lowercasedRaw.contains("thin") { return .thin }
        if lowercasedRaw.contains("ultralight") || lowercasedRaw.contains("ultra light") { return .ultraLight }
        return nil
    }

    func firstMatchedNumber(after marker: String) -> CGFloat? {
        guard let markerRange = lowercasedRaw.range(of: marker) else { return nil }
        var cursor = markerRange.upperBound
        var digits = ""
        var hasStarted = false

        while cursor < lowercasedRaw.endIndex {
            let character = lowercasedRaw[cursor]
            if character.isNumber || character == "." {
                digits.append(character)
                hasStarted = true
            } else if hasStarted {
                break
            }
            cursor = lowercasedRaw.index(after: cursor)
        }

        guard !digits.isEmpty, let value = Double(digits) else { return nil }
        return CGFloat(value)
    }
}

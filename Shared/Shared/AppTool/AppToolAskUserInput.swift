// ============================================================================
// AppToolAskUserInput.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载“询问用户选项”工具的模型、答案策略与提交格式化。
// ============================================================================

import Foundation

public enum AppToolAskUserInputQuestionType: String, Codable, Hashable, Sendable {
    case singleSelect = "single_select"
    case multiSelect = "multi_select"
}

public enum AppToolAskUserInputAnswerPolicy {
    public static func normalizedCustomText(_ rawText: String?) -> String? {
        guard let rawText else { return nil }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func hasAnswer(selectedOptionIDs: Set<String>, customText: String?) -> Bool {
        !selectedOptionIDs.isEmpty || normalizedCustomText(customText) != nil
    }

    public static func canSelectOption(type: AppToolAskUserInputQuestionType, customText: String?) -> Bool {
        switch type {
        case .singleSelect:
            return normalizedCustomText(customText) == nil
        case .multiSelect:
            return true
        }
    }

    public static func shouldClearSelectedOptionsAfterTypingCustomText(
        type: AppToolAskUserInputQuestionType,
        customText: String?
    ) -> Bool {
        type == .singleSelect && normalizedCustomText(customText) != nil
    }
}

public struct AppToolAskUserInputOption: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

public struct AppToolAskUserInputQuestion: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let question: String
    public let type: AppToolAskUserInputQuestionType
    public let options: [AppToolAskUserInputOption]
    public let allowOther: Bool
    public let required: Bool

    public init(
        id: String,
        question: String,
        type: AppToolAskUserInputQuestionType,
        options: [AppToolAskUserInputOption],
        allowOther: Bool,
        required: Bool
    ) {
        self.id = id
        self.question = question
        self.type = type
        self.options = options
        self.allowOther = allowOther
        self.required = required
    }
}

public struct AppToolAskUserInputRequest: Codable, Identifiable, Equatable, Sendable {
    public static let payloadUserInfoKey = "payload"

    public let requestID: String
    public let title: String?
    public let description: String?
    public let submitLabel: String
    public let questions: [AppToolAskUserInputQuestion]

    public init(
        requestID: String,
        title: String?,
        description: String?,
        submitLabel: String,
        questions: [AppToolAskUserInputQuestion]
    ) {
        self.requestID = requestID
        self.title = title
        self.description = description
        self.submitLabel = submitLabel
        self.questions = questions
    }

    public var id: String { requestID }

    public var userInfo: [AnyHashable: Any] {
        [Self.payloadUserInfoKey: encodedJSONString]
    }

    public static func decode(from userInfo: [AnyHashable: Any]?) -> AppToolAskUserInputRequest? {
        guard let userInfo,
              let payload = userInfo[payloadUserInfoKey] as? String,
              let data = payload.data(using: .utf8),
              let request = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        return request
    }

    private var encodedJSONString: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

public struct AppToolAskUserInputQuestionAnswer: Codable, Equatable, Sendable {
    public let questionID: String
    public let question: String
    public let type: AppToolAskUserInputQuestionType
    public let selectedOptionIDs: [String]
    public let selectedOptionLabels: [String]
    public let otherText: String?

    public init(
        questionID: String,
        question: String,
        type: AppToolAskUserInputQuestionType,
        selectedOptionIDs: [String],
        selectedOptionLabels: [String],
        otherText: String?
    ) {
        self.questionID = questionID
        self.question = question
        self.type = type
        self.selectedOptionIDs = selectedOptionIDs
        self.selectedOptionLabels = selectedOptionLabels
        self.otherText = otherText
    }
}

public struct AppToolAskUserInputSubmission: Codable, Equatable, Sendable {
    public let requestID: String
    public let cancelled: Bool
    public let submittedAt: String
    public let answers: [AppToolAskUserInputQuestionAnswer]

    public init(
        requestID: String,
        cancelled: Bool,
        submittedAt: String,
        answers: [AppToolAskUserInputQuestionAnswer]
    ) {
        self.requestID = requestID
        self.cancelled = cancelled
        self.submittedAt = submittedAt
        self.answers = answers
    }
}

public enum AppToolAskUserInputSubmissionFormatter {
    public static func messageContent(
        request: AppToolAskUserInputRequest,
        submission: AppToolAskUserInputSubmission
    ) -> String {
        if submission.cancelled {
            return NSLocalizedString("用户取消了本次问答。", comment: "Ask user input tool cancelled result")
        }

        let questionByID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
        var blocks: [String] = []
        for answer in submission.answers {
            let answerText = formattedAnswerText(answer, question: questionByID[answer.questionID])
            blocks.append("Q: \(answer.question)\nA: \(answerText)")
        }

        if blocks.isEmpty {
            return NSLocalizedString("用户未提供回答。", comment: "Ask user input tool empty result")
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func formattedAnswerText(
        _ answer: AppToolAskUserInputQuestionAnswer,
        question: AppToolAskUserInputQuestion?
    ) -> String {
        var segments: [String] = []

        if let question {
            let labelByOptionID = Dictionary(
                uniqueKeysWithValues: question.options.map { option in
                    (option.id, option.label)
                }
            )
            let selectedLabels = answer.selectedOptionIDs.compactMap { optionID in
                labelByOptionID[optionID]
            }
            if !selectedLabels.isEmpty {
                segments.append(selectedLabels.joined(separator: ","))
            } else if !answer.selectedOptionLabels.isEmpty {
                segments.append(answer.selectedOptionLabels.joined(separator: ","))
            }
        } else if !answer.selectedOptionLabels.isEmpty {
            segments.append(answer.selectedOptionLabels.joined(separator: ","))
        }

        if let other = AppToolAskUserInputAnswerPolicy.normalizedCustomText(answer.otherText) {
            segments.append(other)
        }

        if segments.isEmpty {
            return NSLocalizedString("未填写", comment: "Ask user input unanswered placeholder")
        }
        return segments.joined(separator: ",")
    }
}

// ============================================================================
// AppToolManagerBasicExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具中的基础交互类工具执行逻辑。
// ============================================================================

import Foundation

extension AppToolManager {
    func executeShowWidget(argumentsJSON: String) throws -> String {
        struct ShowWidgetArgs: Decodable {
            let title: String?
            let widget_code: String
            let loading_messages: [String]?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(ShowWidgetArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 show_widget 的参数，请提供 widget_code。", comment: "Show widget tool invalid arguments")
            )
        }

        let widgetCode = args.widget_code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !widgetCode.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：show_widget 的 widget_code 不能为空。", comment: "Show widget tool empty widget code")
            )
        }

        let normalizedTitle = args.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLoadingMessages = (args.loading_messages ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let payload: [String: Any] = [
            "title": normalizedTitle as Any,
            "widget_code": widgetCode,
            "loading_messages": normalizedLoadingMessages
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeAskUserInput(argumentsJSON: String) throws -> String {
        struct AskUserInputArgs: Decodable {
            struct Question: Decodable {
                struct Option: Decodable {
                    let id: String?
                    let label: String
                    let description: String?
                }

                let id: String?
                let question: String
                let type: String
                let options: [Option]
                let allow_other: Bool?
                let required: Bool?
            }

            let request_id: String?
            let title: String?
            let description: String?
            let submit_label: String?
            let questions: [Question]
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(AskUserInputArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 ask_user_input 的参数，请提供 questions。", comment: "Ask user input tool invalid arguments")
            )
        }

        let normalizedQuestions = args.questions.enumerated().compactMap { questionIndex, question -> AppToolAskUserInputQuestion? in
            let questionText = question.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !questionText.isEmpty else { return nil }

            let normalizedTypeRaw = question.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let type = AppToolAskUserInputQuestionType(rawValue: normalizedTypeRaw) else { return nil }

            let questionID = Self.normalizedQuestionID(question.id, fallbackIndex: questionIndex)
            var seenOptionIDs: Set<String> = []
            let normalizedOptions = question.options.enumerated().compactMap { optionIndex, option -> AppToolAskUserInputOption? in
                let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return nil }
                let baseID = Self.normalizedOptionalText(option.id) ?? "option_\(optionIndex + 1)"
                let optionID = Self.uniqueIdentifier(from: baseID, seen: &seenOptionIDs)
                return AppToolAskUserInputOption(
                    id: optionID,
                    label: label,
                    description: Self.normalizedOptionalText(option.description)
                )
            }
            guard !normalizedOptions.isEmpty else { return nil }

            return AppToolAskUserInputQuestion(
                id: questionID,
                question: questionText,
                type: type,
                options: normalizedOptions,
                allowOther: question.allow_other ?? false,
                required: question.required ?? true
            )
        }

        guard !normalizedQuestions.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：ask_user_input 至少需要一个有效问题，且每个问题都要包含非空 question、合法 type 和非空 options。", comment: "Ask user input tool invalid normalized questions")
            )
        }

        let requestID = Self.normalizedRequestID(args.request_id)
        let request = AppToolAskUserInputRequest(
            requestID: requestID,
            title: Self.normalizedOptionalText(args.title),
            description: Self.normalizedOptionalText(args.description),
            submitLabel: Self.normalizedOptionalText(args.submit_label) ?? NSLocalizedString("提交", comment: "Ask user input default submit label"),
            questions: normalizedQuestions
        )

        NotificationCenter.default.post(
            name: .appToolAskUserInputRequested,
            object: nil,
            userInfo: request.userInfo
        )

        let payload: [String: Any] = [
            "request_id": request.requestID,
            "question_count": request.questions.count,
            "displayed": true,
            "await_user_supplement": true
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeEchoText(argumentsJSON: String) throws -> String {
        struct EchoArgs: Decodable {
            let text: String
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(EchoArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 echo_text 的参数，请提供 text 字段。", comment: "Echo tool invalid arguments")
            )
        }

        let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：echo_text 的 text 不能为空。", comment: "Echo tool empty text")
            )
        }

        return String(
            format: NSLocalizedString("文本回显结果：%@", comment: "Echo tool result format"),
            text
        )
    }

    func executeFillUserInput(argumentsJSON: String) throws -> String {
        struct FillUserInputArgs: Decodable {
            let text: String
            let mode: String?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(FillUserInputArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 fill_user_input 的参数，请提供 text。", comment: "Fill user input tool invalid arguments")
            )
        }

        let content = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：fill_user_input 的 text 不能为空。", comment: "Fill user input tool empty text")
            )
        }

        let mode = AppToolInputDraftMode(rawValue: (args.mode ?? AppToolInputDraftMode.replace.rawValue).lowercased()) ?? .replace
        let request = AppToolInputDraftRequest(text: args.text, mode: mode)
        NotificationCenter.default.post(
            name: .appToolFillUserInputRequested,
            object: nil,
            userInfo: request.userInfo
        )

        let payload: [String: Any] = [
            "mode": mode.rawValue,
            "characterCount": args.text.count,
            "applied": true
        ]
        return prettyPrintedJSONString(from: payload)
    }
}

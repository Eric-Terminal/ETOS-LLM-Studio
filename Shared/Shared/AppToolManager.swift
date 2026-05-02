// ============================================================================
// AppToolManager.swift
// ============================================================================
// 本地拓展工具管理器。
// - 管理默认关闭的本地拓展工具目录
// - 负责聊天工具暴露与执行分发
// ============================================================================

import Foundation
import Combine
import os.log
import SQLite3

public enum AppToolInputDraftMode: String, Codable, Hashable, Sendable {
    case replace
    case append
}

public struct AppToolInputDraftRequest: Equatable, Sendable {
    public static let textUserInfoKey = "text"
    public static let modeUserInfoKey = "mode"

    public var text: String
    public var mode: AppToolInputDraftMode

    public init(text: String, mode: AppToolInputDraftMode = .replace) {
        self.text = text
        self.mode = mode
    }

    public var userInfo: [AnyHashable: Any] {
        [
            Self.textUserInfoKey: text,
            Self.modeUserInfoKey: mode.rawValue
        ]
    }

    public static func decode(from userInfo: [AnyHashable: Any]?) -> AppToolInputDraftRequest? {
        guard let userInfo,
              let text = userInfo[textUserInfoKey] as? String else {
            return nil
        }
        let modeRawValue = (userInfo[modeUserInfoKey] as? String) ?? AppToolInputDraftMode.replace.rawValue
        let mode = AppToolInputDraftMode(rawValue: modeRawValue) ?? .replace
        return AppToolInputDraftRequest(text: text, mode: mode)
    }
}

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

    var encodedJSONString: String {
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
            return "用户取消了本次问答。"
        }

        let questionByID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
        var blocks: [String] = []
        for answer in submission.answers {
            let answerText = formattedAnswerText(answer, question: questionByID[answer.questionID])
            blocks.append("Q: \(answer.question)\nA: \(answerText)")
        }

        if blocks.isEmpty {
            return "用户未提供回答。"
        }
        return blocks.joined(separator: "\n\n")
    }

    static func formattedAnswerText(
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
            return "未填写"
        }
        return segments.joined(separator: ",")
    }
}

public extension Notification.Name {
    static let appToolFillUserInputRequested = Notification.Name("com.ETOS.LLM.Studio.appTool.fillUserInput")
    static let appToolAskUserInputRequested = Notification.Name("com.ETOS.LLM.Studio.appTool.askUserInput")
}

public enum AppToolSQLiteDatabase: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chat
    case config
    case memory

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat:
            return "聊天"
        case .config:
            return "配置"
        case .memory:
            return "记忆"
        }
    }
}


public struct AppToolCatalogItem: Identifiable, Equatable, Sendable {
    public let kind: AppToolKind
    public let isEnabled: Bool

    public var id: AppToolKind { kind }

    public init(kind: AppToolKind, isEnabled: Bool) {
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

public enum AppToolApprovalPolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case askEveryTime = "ask_every_time"
    case alwaysAllow = "always_allow"
    case alwaysDeny = "always_deny"

    public var displayName: String {
        switch self {
        case .askEveryTime:
            return NSLocalizedString("每次询问", comment: "Ask every time approval policy")
        case .alwaysAllow:
            return NSLocalizedString("总是允许", comment: "Always allow approval policy")
        case .alwaysDeny:
            return NSLocalizedString("始终拒绝", comment: "Always deny approval policy")
        }
    }
}

public enum AppToolExecutionError: LocalizedError {
    case toolGroupDisabled
    case toolDisabled(String)
    case toolDeniedByPolicy(String)
    case unknownTool
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .toolGroupDisabled:
            return NSLocalizedString("拓展工具总开关已关闭。", comment: "App tools group disabled")
        case .toolDisabled(let name):
            return String(
                format: NSLocalizedString("拓展工具“%@”当前未启用。", comment: "App tool disabled"),
                name
            )
        case .toolDeniedByPolicy(let name):
            return String(
                format: NSLocalizedString("拓展工具“%@”当前审批策略为始终拒绝。", comment: "App tool denied by approval policy"),
                name
            )
        case .unknownTool:
            return NSLocalizedString("未找到对应的拓展工具。", comment: "Unknown app tool")
        case .invalidArguments(let message):
            return message
        }
    }
}

@MainActor
public final class AppToolManager: ObservableObject {
    public static let shared = AppToolManager()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则工具中心里的总开关、启用态与审批策略不会稳定自动刷新。

    nonisolated static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "AppToolManager")
    nonisolated static let chatToolsEnabledUserDefaultsKey = "appTools.chatToolsEnabled"
    nonisolated static let enabledToolIDsUserDefaultsKey = "appTools.enabledToolIDs"
    nonisolated static let toolApprovalPoliciesUserDefaultsKey = "appTools.toolApprovalPolicies"
    #if os(watchOS)
    nonisolated static let defaultEnabledToolKinds: Set<AppToolKind> = [.askUserInput, .getSystemTime]
    #else
    nonisolated static let defaultEnabledToolKinds: Set<AppToolKind> = [.showWidget, .askUserInput, .getSystemTime]
    #endif
    nonisolated static let builtInToolKinds: Set<AppToolKind> = [.showWidget, .askUserInput, .getSystemTime]
    nonisolated static let sqliteToolDefaultMaxRows = 50
    nonisolated static let sqliteToolMaximumMaxRows = 500
    nonisolated static let sqliteToolMaxBlobPreviewBytes = 1024
    /// 使用 SQLite 官方约定的 transient 析构标记，强制 SQLite 复制绑定文本。
    /// 这里改为从指针位模式转换，避免在 arm64_32（watchOS 真机）上因 Int/函数指针尺寸不一致触发启动崩溃。
    nonisolated static var sqliteTransientDestructor: sqlite3_destructor_type {
        unsafeBitCast(UnsafeMutableRawPointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    }

    @Published public var chatToolsEnabled: Bool
    @Published var enabledToolIDs: Set<String>
    @Published var toolApprovalPolicies: [String: AppToolApprovalPolicy]

    init(defaults: UserDefaults = .standard) {
        chatToolsEnabled = defaults.object(forKey: Self.chatToolsEnabledUserDefaultsKey) as? Bool ?? true
        if let storedIDs = defaults.stringArray(forKey: Self.enabledToolIDsUserDefaultsKey) {
            var migratedIDs = Set(storedIDs.filter { AppToolKind(rawValue: $0) != nil })
            migratedIDs.formUnion(Self.defaultEnabledToolKinds.map(\.rawValue))
            enabledToolIDs = migratedIDs
            defaults.set(Array(migratedIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        } else {
            let defaultIDs = Set(Self.defaultEnabledToolKinds.map(\.rawValue))
            enabledToolIDs = defaultIDs
            defaults.set(Array(defaultIDs).sorted(), forKey: Self.enabledToolIDsUserDefaultsKey)
        }
        let storedPolicyRawValues = defaults.dictionary(forKey: Self.toolApprovalPoliciesUserDefaultsKey) as? [String: String] ?? [:]
        toolApprovalPolicies = storedPolicyRawValues.reduce(into: [String: AppToolApprovalPolicy]()) { result, pair in
            guard let kind = AppToolKind(rawValue: pair.key) else { return }
            guard kind.requiresApproval else { return }
            guard let policy = AppToolApprovalPolicy(rawValue: pair.value), policy != .askEveryTime else { return }
            result[pair.key] = policy
        }
    }
}

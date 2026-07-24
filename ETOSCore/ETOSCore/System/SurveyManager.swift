// ============================================================================
// SurveyManager.swift
// ============================================================================
// ETOS LLM Studio 意见征集管理器
//
// 负责筛选服务端下发的征集、协调启动展示，并通过 PoW 提交匿名答卷。
// ============================================================================

import Combine
import Foundation
import os.log

private let surveyLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "SurveyManager"
)

public struct SurveyOption: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?
}

public struct SurveyQuestion: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let question: String
    public let type: AppToolAskUserInputQuestionType
    public let options: [SurveyOption]
    public let allowOther: Bool
    public let required: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case question
        case type
        case options
        case allowOther = "allow_other"
        case required
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        question = try container.decode(String.self, forKey: .question)
        type = try container.decode(AppToolAskUserInputQuestionType.self, forKey: .type)
        options = try container.decode([SurveyOption].self, forKey: .options)
        allowOther = try container.decodeIfPresent(Bool.self, forKey: .allowOther) ?? false
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
    }

    var inputQuestion: AppToolAskUserInputQuestion {
        AppToolAskUserInputQuestion(
            id: id,
            question: question,
            type: type,
            options: options.map {
                AppToolAskUserInputOption(
                    id: $0.id,
                    label: $0.label,
                    description: $0.description
                )
            },
            allowOther: allowOther,
            required: required
        )
    }
}

public struct SurveyDefinition: Codable, Identifiable, Equatable, Sendable {
    public let key: String
    public let id: Int
    public let title: String
    public let description: String?
    public let minBuild: String?
    public let maxBuild: String?
    public let language: String?
    public let platform: String?
    public let questions: [SurveyQuestion]

    public var inputRequest: AppToolAskUserInputRequest {
        AppToolAskUserInputRequest(
            requestID: key,
            title: title,
            description: description,
            submitLabel: NSLocalizedString("提交", comment: "Survey submit button"),
            questions: questions.map(\.inputQuestion)
        )
    }

    enum CodingKeys: String, CodingKey {
        case key
        case id
        case title
        case description
        case minBuild = "min_build"
        case maxBuild = "max_build"
        case language
        case platform
        case questions
    }
}

private struct SurveySubmissionAnswer: Encodable, Sendable {
    let questionID: String
    let selectedOptionIDs: [String]
    let otherText: String?

    enum CodingKeys: String, CodingKey {
        case questionID = "question_id"
        case selectedOptionIDs = "selected_option_ids"
        case otherText = "other_text"
    }
}

private struct SurveySubmissionPayload: Encodable, Sendable {
    let answers: [SurveySubmissionAnswer]
    let platform: String
    let appBuild: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case answers
        case platform
        case appBuild = "app_build"
        case language
    }
}

private struct SurveyClientState: Codable, Sendable {
    var submittedKeys: Set<String> = []
    var dismissedKeys: Set<String> = []
}

public enum SurveyServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case decodeFailed
    case proofOfWorkFailed
    case signatureRejected
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("意见征集服务地址无效。", comment: "Survey invalid service URL")
        case .invalidResponse:
            return NSLocalizedString("意见征集服务返回了无效响应。", comment: "Survey invalid response")
        case .decodeFailed:
            return NSLocalizedString("意见征集数据解析失败。", comment: "Survey decode failed")
        case .proofOfWorkFailed:
            return NSLocalizedString("提交验证计算失败，请稍后重试。", comment: "Survey proof of work failed")
        case .signatureRejected:
            return NSLocalizedString("提交验证已失效，请重试。", comment: "Survey signature rejected")
        case .serverError(let message):
            return message
        }
    }
}

@MainActor
public final class SurveyManager: ObservableObject {
    public static let shared = SurveyManager()

    @Published public private(set) var currentSurvey: SurveyDefinition?
    @Published public var shouldShowSurvey = false
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var submissionErrorMessage: String?

    private static let stateKey = "survey_client_state_v1"
    private static let surveyPath = "/v1/surveys"
    private static let challengePath = "/v1/surveys/challenge"

    private let session: URLSession
    private let baseURL: URL
    private let timeoutInterval: TimeInterval
    private var pendingSurvey: SurveyDefinition?
    private var clientState = SurveyClientState()

    public init(
        session: URLSession = NetworkSessionConfiguration.shared,
        baseURL: URL = FeedbackServiceConfig.default.baseURL,
        timeoutInterval: TimeInterval = 20
    ) {
        self.session = session
        self.baseURL = baseURL
        self.timeoutInterval = timeoutInterval
    }

    public func checkSurveys(canPresent: Bool) async {
        do {
            let stateKey = Self.stateKey
            let storedState = await Task.detached {
                Persistence.loadAuxiliaryBlob(SurveyClientState.self, forKey: stateKey)
                    ?? SurveyClientState()
            }.value
            clientState = storedState

            let surveys = try await fetchSurveys()
            pendingSurvey = selectSurvey(
                from: surveys,
                excluding: clientState.submittedKeys.union(clientState.dismissedKeys)
            )
            if canPresent {
                presentPendingSurveyIfPossible()
            }
        } catch {
            surveyLogger.warning("获取意见征集失败: \(error.localizedDescription)")
            pendingSurvey = nil
        }
    }

    public func presentPendingSurveyIfPossible() {
        guard !shouldShowSurvey, currentSurvey == nil, let pendingSurvey else { return }
        currentSurvey = pendingSurvey
        shouldShowSurvey = true
    }

    public func dismissCurrentSurvey() {
        guard let survey = currentSurvey else {
            shouldShowSurvey = false
            return
        }
        clientState.dismissedKeys.insert(survey.key)
        persistClientState()
        clearPresentation()
    }

    public func clearSubmissionError() {
        submissionErrorMessage = nil
    }

    @discardableResult
    public func submit(_ answers: [AppToolAskUserInputQuestionAnswer]) async -> Bool {
        guard let survey = currentSurvey, !isSubmitting else { return false }
        isSubmitting = true
        submissionErrorMessage = nil
        defer { isSubmitting = false }

        do {
            let snapshot = FeedbackEnvironmentCollector.collectSnapshot()
            let payload = SurveySubmissionPayload(
                answers: answers.map {
                    SurveySubmissionAnswer(
                        questionID: $0.questionID,
                        selectedOptionIDs: $0.selectedOptionIDs,
                        otherText: $0.otherText
                    )
                },
                platform: snapshot.platform,
                appBuild: snapshot.appBuild,
                language: AppLanguagePreference.storedPreference.localizationIdentifier
                    ?? Locale.current.identifier
            )
            try await submit(payload, surveyKey: survey.key)
            clientState.submittedKeys.insert(survey.key)
            await persistClientStateAndWait()
            clearPresentation()
            return true
        } catch {
            submissionErrorMessage = error.localizedDescription
            surveyLogger.warning("提交匿名答卷失败: \(error.localizedDescription)")
            return false
        }
    }

    private func clearPresentation() {
        pendingSurvey = nil
        currentSurvey = nil
        shouldShowSurvey = false
        submissionErrorMessage = nil
    }

    private func persistClientState() {
        let state = clientState
        let stateKey = Self.stateKey
        Task.detached {
            _ = Persistence.saveAuxiliaryBlob(state, forKey: stateKey)
        }
    }

    private func persistClientStateAndWait() async {
        let state = clientState
        let stateKey = Self.stateKey
        await Task.detached {
            _ = Persistence.saveAuxiliaryBlob(state, forKey: stateKey)
        }.value
    }

    private func fetchSurveys() async throws -> [SurveyDefinition] {
        var request = try buildRequest(path: Self.surveyPath, method: "GET")
        request.cachePolicy = .useProtocolCachePolicy
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
        do {
            return try await Task.detached {
                try JSONDecoder().decode([SurveyDefinition].self, from: data)
            }.value
        } catch {
            throw SurveyServiceError.decodeFailed
        }
    }

    private func submit(_ payload: SurveySubmissionPayload, surveyKey: String) async throws {
        let challenge = try await requestChallenge()
        let bodyData: Data
        do {
            bodyData = try await Task.detached {
                try JSONEncoder().encode(payload)
            }.value
        } catch {
            throw SurveyServiceError.decodeFailed
        }

        let path = "\(Self.surveyPath)/\(surveyKey)/responses"
        var request = try buildRequest(path: path, method: "POST")
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let bodyHash = FeedbackSignature.bodyHashHex(bodyData)
        let signingText = "POST\n\(path)\n\(timestamp)\n\(bodyHash)\n\(challenge.nonce)"
        let signature = FeedbackSignature.hmacSHA256Hex(
            message: signingText,
            secret: challenge.clientSecret
        )
        let powBits = max(challenge.powBits ?? 0, 0)
        let challengeID = challenge.challengeID
        let powSalt = challenge.powSalt ?? ""
        let powSolution = await Task.detached(priority: .userInitiated) {
            FeedbackProofOfWork.solve(
                method: "POST",
                path: path,
                timestamp: timestamp,
                bodyHashHex: bodyHash,
                challengeID: challengeID,
                powSalt: powSalt,
                bits: powBits
            )
        }.value
        if powBits > 0 && powSolution == nil {
            throw SurveyServiceError.proofOfWorkFailed
        }

        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(challengeID, forHTTPHeaderField: "X-ELS-Challenge-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-ELS-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-ELS-Signature")
        if let powSolution {
            request.setValue(powSolution.nonce, forHTTPHeaderField: "X-ELS-PoW-Nonce")
            request.setValue(powSolution.hashHex, forHTTPHeaderField: "X-ELS-PoW-Hash")
            request.setValue(String(powSolution.bits), forHTTPHeaderField: "X-ELS-PoW-Bits")
        }

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
    }

    private func requestChallenge() async throws -> ChallengeResponse {
        var request = try buildRequest(path: Self.challengePath, method: "POST")
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
        do {
            return try await Task.detached {
                try FeedbackDateCodec.makeJSONDecoder().decode(ChallengeResponse.self, from: data)
            }.value
        } catch {
            throw SurveyServiceError.decodeFailed
        }
    }

    private func buildRequest(path: String, method: String) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SurveyServiceError.invalidURL
        }
        var finalPath = components.path
        if finalPath.hasSuffix("/") {
            finalPath.removeLast()
        }
        finalPath += path.hasPrefix("/") ? path : "/\(path)"
        components.path = finalPath
        guard let url = components.url else {
            throw SurveyServiceError.invalidURL
        }

        let snapshot = FeedbackEnvironmentCollector.collectSnapshot()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue(
            "ETOS LLM Studio/\(snapshot.appVersion) (\(snapshot.platform); \(snapshot.osVersion))",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SurveyServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw SurveyServiceError.signatureRejected
            }
            if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
               !envelope.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SurveyServiceError.serverError(envelope.error)
            }
            throw SurveyServiceError.serverError(
                String(
                    format: NSLocalizedString(
                        "服务错误（HTTP %d）",
                        comment: "Survey service HTTP error"
                    ),
                    httpResponse.statusCode
                )
            )
        }
    }

    private func selectSurvey(
        from surveys: [SurveyDefinition],
        excluding handledKeys: Set<String>
    ) -> SurveyDefinition? {
        let compatible = surveys.filter {
            !handledKeys.contains($0.key)
                && isVersionCompatible($0)
                && isPlatformCompatible($0)
        }
        let appLanguage = AppLanguagePreference.storedPreference
        let locale = appLanguage == .system
            ? Locale.current
            : Locale(identifier: appLanguage.localeIdentifier)
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        let localeIdentifier = appLanguage.localizationIdentifier ?? locale.identifier

        for id in Set(compatible.map(\.id)).sorted(by: >) {
            let group = compatible.filter { $0.id == id }
            let scored = group.enumerated().compactMap { index, survey -> (Int, Int, SurveyDefinition)? in
                guard let language = survey.language, !language.isEmpty else { return nil }
                let score = AnnouncementManager.languageMatchScore(
                    announcementLanguage: language,
                    deviceLanguageCode: languageCode,
                    deviceLocaleIdentifier: localeIdentifier
                )
                return score > 0 ? (score, index, survey) : nil
            }
            if let best = scored.max(by: { left, right in
                left.0 == right.0 ? left.1 > right.1 : left.0 < right.0
            }) {
                return best.2
            }
            if let unrestricted = group.first(where: {
                $0.language?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }) {
                return unrestricted
            }
            if let english = group.first(where: {
                $0.language?.lowercased().hasPrefix("en") == true
            }) {
                return english
            }
            if let first = group.first {
                return first
            }
        }
        return nil
    }

    private func isVersionCompatible(_ survey: SurveyDefinition) -> Bool {
        let currentBuild = Int(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        ) ?? 0
        if let minimum = survey.minBuild.flatMap(Int.init), currentBuild < minimum {
            return false
        }
        if let maximum = survey.maxBuild.flatMap(Int.init), currentBuild > maximum {
            return false
        }
        return true
    }

    private func isPlatformCompatible(_ survey: SurveyDefinition) -> Bool {
        guard let target = survey.platform, !target.isEmpty else { return true }
        return target.caseInsensitiveCompare(FeedbackEnvironmentCollector.platformName) == .orderedSame
    }
}

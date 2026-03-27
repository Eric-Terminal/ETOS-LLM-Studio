// ============================================================================
// FeedbackService.swift
// ============================================================================
// ETOS LLM Studio 反馈服务
//
// 定义内容:
// - 提交反馈（challenge + HMAC）
// - 查询反馈状态
// - 管理本地工单缓存
// ============================================================================

import Foundation
import Combine
import os.log

public struct FeedbackServiceConfig: Sendable {
    public var baseURL: URL
    public var challengePath: String
    public var issuesPath: String
    public var requestTimeout: TimeInterval

    public init(
        baseURL: URL,
        challengePath: String = "/v1/feedback/challenge",
        issuesPath: String = "/v1/feedback/issues",
        requestTimeout: TimeInterval = 20
    ) {
        self.baseURL = baseURL
        self.challengePath = challengePath
        self.issuesPath = issuesPath
        self.requestTimeout = requestTimeout
    }

    public static var `default`: FeedbackServiceConfig {
        let override = UserDefaults.standard.string(forKey: "feedback.apiBaseURL")
        let fallback = "https://feedback.els.ericterminal.com"
        let value = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: value?.isEmpty == false ? value! : fallback) ?? URL(string: fallback)!
        return FeedbackServiceConfig(baseURL: url)
    }
}

public enum FeedbackServiceError: LocalizedError {
    case invalidInput
    case invalidComment
    case invalidURL
    case serverError(String)
    case invalidResponse
    case decodeFailed
    case proofOfWorkFailed
    case signatureRejected

    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            return NSLocalizedString("请至少填写标题和详细描述。", comment: "Feedback invalid input")
        case .invalidComment:
            return NSLocalizedString("评论内容不能为空。", comment: "Feedback invalid comment")
        case .invalidURL:
            return NSLocalizedString("反馈服务地址无效。", comment: "Feedback invalid url")
        case .serverError(let message):
            return message
        case .invalidResponse:
            return NSLocalizedString("反馈服务返回了无效响应。", comment: "Feedback invalid response")
        case .decodeFailed:
            return NSLocalizedString("反馈服务数据解析失败。", comment: "Feedback decode failed")
        case .proofOfWorkFailed:
            return NSLocalizedString("反馈计算验证失败，请稍后重试。", comment: "Feedback proof of work failed")
        case .signatureRejected:
            return NSLocalizedString("反馈签名或验证校验失败，请重试。", comment: "Feedback signature rejected")
        }
    }
}

@MainActor
public final class FeedbackService: ObservableObject {
    public static let shared = FeedbackService()
    // 注意：这里必须使用系统合成的 objectWillChange，
    // 否则工单列表与提交状态不会稳定自动刷新。

    @Published public private(set) var tickets: [FeedbackTicket] = []
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var isRefreshing = false

    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "FeedbackService")
    private let session: URLSession
    private let config: FeedbackServiceConfig
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var notificationObserver: NSObjectProtocol?

    public init(
        session: URLSession = .shared,
        config: FeedbackServiceConfig = .default,
        decoder: JSONDecoder = FeedbackDateCodec.makeJSONDecoder(),
        encoder: JSONEncoder = FeedbackDateCodec.makeJSONEncoder()
    ) {
        self.session = session
        self.config = config
        self.decoder = decoder
        self.encoder = encoder
        self.tickets = FeedbackStore.loadTickets()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .feedbackTicketsUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickets = FeedbackStore.loadTickets()
            }
        }
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
    }

    public func reloadTickets() {
        tickets = FeedbackStore.loadTickets()
    }

    public func listTickets() -> [FeedbackTicket] {
        tickets
    }

    public func deleteTicket(issueNumber: Int) {
        FeedbackStore.deleteTicket(issueNumber: issueNumber)
        tickets = FeedbackStore.loadTickets()
    }

    @discardableResult
    public func submit(draft: FeedbackDraft) async throws -> FeedbackTicket {
        let sanitizedTitle = draft.sanitizedTitle
        let sanitizedDetail = draft.sanitizedDetail
        guard !sanitizedTitle.isEmpty, !sanitizedDetail.isEmpty else {
            throw FeedbackServiceError.invalidInput
        }

        isSubmitting = true
        defer { isSubmitting = false }

        let challenge = try await requestChallenge()
        let payload = SubmitIssuePayload(
            type: draft.category.rawValue,
            title: FeedbackTextSanitizer.redact(sanitizedTitle),
            detail: FeedbackTextSanitizer.redact(sanitizedDetail),
            reproductionSteps: FeedbackTextSanitizer.redact(draft.reproductionSteps?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            expectedBehavior: FeedbackTextSanitizer.redact(draft.expectedBehavior?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            actualBehavior: FeedbackTextSanitizer.redact(draft.actualBehavior?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            extraContext: FeedbackTextSanitizer.redact(draft.extraContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            environment: FeedbackEnvironmentCollector.collectSnapshot(),
            logs: FeedbackEnvironmentCollector.collectMinimalLogs().map(FeedbackTextSanitizer.redact)
        )

        let bodyData = try encoder.encode(payload)
        let submitPath = config.issuesPath
        var request = try buildRequest(path: submitPath, method: "POST")
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let bodyHash = FeedbackSignature.bodyHashHex(bodyData)
        let signingText = "POST\n\(submitPath)\n\(timestamp)\n\(bodyHash)\n\(challenge.nonce)"
        let signature = FeedbackSignature.hmacSHA256Hex(message: signingText, secret: challenge.clientSecret)
        let powBits = max(challenge.powBits ?? 0, 0)
        let powSalt = challenge.powSalt ?? ""
        let challengeID = challenge.challengeID
        let powSolution = await Task.detached(priority: .userInitiated) {
            FeedbackProofOfWork.solve(
                method: "POST",
                path: submitPath,
                timestamp: timestamp,
                bodyHashHex: bodyHash,
                challengeID: challengeID,
                powSalt: powSalt,
                bits: powBits
            )
        }.value

        if powBits > 0 && powSolution == nil {
            throw FeedbackServiceError.proofOfWorkFailed
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

        let submitResponse: SubmitIssueResponse
        do {
            submitResponse = try decoder.decode(SubmitIssueResponse.self, from: data)
        } catch {
            logger.error("解析提交响应失败: \(error.localizedDescription)")
            throw FeedbackServiceError.decodeFailed
        }

        let status = FeedbackStatusMapper.map(
            serverStatus: submitResponse.status,
            labels: [],
            isClosed: false
        )

        let now = Date()
        let ticket = FeedbackTicket(
            issueNumber: submitResponse.issueNumber,
            ticketToken: submitResponse.ticketToken,
            category: draft.category,
            title: sanitizedTitle,
            createdAt: now,
            lastKnownStatus: status,
            lastCheckedAt: now,
            lastKnownUpdatedAt: now,
            publicURL: submitResponse.publicURL,
            moderationBlocked: submitResponse.moderationBlocked,
            moderationMessage: submitResponse.moderationMessage,
            archiveID: submitResponse.archiveID
        )

        FeedbackStore.upsertTicket(ticket)
        tickets = FeedbackStore.loadTickets()
        return ticket
    }

    @discardableResult
    public func fetchStatus(ticket: FeedbackTicket) async throws -> FeedbackStatusSnapshot {
        isRefreshing = true
        defer { isRefreshing = false }

        let path = "\(config.issuesPath)/\(ticket.issueNumber)"
        var request = try buildRequest(
            path: path,
            method: "GET",
            queryItems: [URLQueryItem(name: "ticket_token", value: ticket.ticketToken)]
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let statusResponse: IssueStatusResponse
        do {
            statusResponse = try decoder.decode(IssueStatusResponse.self, from: data)
        } catch {
            logger.error("解析状态响应失败: \(error.localizedDescription)")
            throw FeedbackServiceError.decodeFailed
        }

        let visibleLabels = FeedbackLabelFilter.visibleLabels(from: statusResponse.labels)
        let status = FeedbackStatusMapper.map(
            serverStatus: statusResponse.status,
            labels: statusResponse.labels,
            isClosed: statusResponse.closed
        )

        let snapshot = FeedbackStatusSnapshot(
            issueNumber: statusResponse.issueNumber,
            title: statusResponse.title,
            status: status,
            labels: visibleLabels,
            updatedAt: statusResponse.updatedAt,
            publicURL: statusResponse.publicURL,
            isClosed: statusResponse.closed,
            comments: statusResponse.comments
        )

        FeedbackStore.upsertTicket(ticket.merged(with: snapshot))
        tickets = FeedbackStore.loadTickets()
        return snapshot
    }

    @discardableResult
    public func submitComment(ticket: FeedbackTicket, body: String) async throws -> FeedbackComment {
        let sanitizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedBody.isEmpty else {
            throw FeedbackServiceError.invalidComment
        }

        let challenge = try await requestChallenge()
        let payload = SubmitCommentPayload(body: FeedbackTextSanitizer.redact(sanitizedBody))
        let bodyData = try encoder.encode(payload)

        let commentPath = "\(config.issuesPath)/\(ticket.issueNumber)/comments"
        var request = try buildRequest(
            path: commentPath,
            method: "POST",
            queryItems: [URLQueryItem(name: "ticket_token", value: ticket.ticketToken)]
        )

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let bodyHash = FeedbackSignature.bodyHashHex(bodyData)
        let signingText = "POST\n\(commentPath)\n\(timestamp)\n\(bodyHash)\n\(challenge.nonce)"
        let signature = FeedbackSignature.hmacSHA256Hex(message: signingText, secret: challenge.clientSecret)
        let powBits = max(challenge.powBits ?? 0, 0)
        let powSalt = challenge.powSalt ?? ""
        let challengeID = challenge.challengeID
        let powSolution = await Task.detached(priority: .userInitiated) {
            FeedbackProofOfWork.solve(
                method: "POST",
                path: commentPath,
                timestamp: timestamp,
                bodyHashHex: bodyHash,
                challengeID: challengeID,
                powSalt: powSalt,
                bits: powBits
            )
        }.value

        if powBits > 0 && powSolution == nil {
            throw FeedbackServiceError.proofOfWorkFailed
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

        let submitResponse: SubmitCommentResponse
        do {
            submitResponse = try decoder.decode(SubmitCommentResponse.self, from: data)
        } catch {
            logger.error("解析评论响应失败: \(error.localizedDescription)")
            throw FeedbackServiceError.decodeFailed
        }

        if submitResponse.moderationBlocked == true {
            if let index = tickets.firstIndex(where: { $0.issueNumber == ticket.issueNumber }) {
                var updated = tickets[index]
                updated.lastKnownStatus = .blocked
                updated.moderationBlocked = true
                updated.moderationMessage = submitResponse.moderationMessage ?? updated.moderationMessage
                updated.archiveID = submitResponse.archiveID ?? updated.archiveID
                FeedbackStore.upsertTicket(updated)
                tickets = FeedbackStore.loadTickets()
            }
        }

        guard let comment = submitResponse.comment else {
            throw FeedbackServiceError.invalidResponse
        }
        return comment
    }

    public func refreshAllTickets() async {
        let current = FeedbackStore.loadTickets()
        for ticket in current {
            do {
                _ = try await fetchStatus(ticket: ticket)
            } catch {
                logger.warning("刷新工单 #\(ticket.issueNumber) 失败: \(error.localizedDescription)")
            }
        }
        tickets = FeedbackStore.loadTickets()
    }

    // MARK: - 私有请求

    private func requestChallenge() async throws -> ChallengeResponse {
        var request = try buildRequest(path: config.challengePath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        do {
            return try decoder.decode(ChallengeResponse.self, from: data)
        } catch {
            logger.error("解析 challenge 响应失败: \(error.localizedDescription)")
            throw FeedbackServiceError.decodeFailed
        }
    }

    private func buildRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw FeedbackServiceError.invalidURL
        }

        var finalPath = components.path
        if finalPath.hasSuffix("/") {
            finalPath.removeLast()
        }
        finalPath += path.hasPrefix("/") ? path : "/\(path)"
        components.path = finalPath
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw FeedbackServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = config.requestTimeout
        request.setValue(defaultUserAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func defaultUserAgent() -> String {
        let snapshot = FeedbackEnvironmentCollector.collectSnapshot()
        return "ETOS LLM Studio/\(snapshot.appVersion) (\(snapshot.platform); \(snapshot.osVersion); \(snapshot.deviceModel))"
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeedbackServiceError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw FeedbackServiceError.signatureRejected
            }

            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data),
               !envelope.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw FeedbackServiceError.serverError(envelope.error)
            }

            let fallback = String(
                format: NSLocalizedString("服务错误（HTTP %d）", comment: "Feedback service HTTP error"),
                httpResponse.statusCode
            )
            throw FeedbackServiceError.serverError(fallback)
        }
    }
}

// MARK: - DTO

private struct APIErrorEnvelope: Decodable {
    let error: String
}

private struct ChallengeResponse: Decodable {
    let challengeID: String
    let clientSecret: String
    let nonce: String
    let powBits: Int?
    let powSalt: String?
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case clientSecret = "client_secret"
        case nonce
        case powBits = "pow_bits"
        case powSalt = "pow_salt"
        case expiresAt = "expires_at"
    }
}

private struct SubmitIssuePayload: Encodable {
    let type: String
    let title: String
    let detail: String
    let reproductionSteps: String?
    let expectedBehavior: String?
    let actualBehavior: String?
    let extraContext: String?
    let environment: FeedbackEnvironmentSnapshot
    let logs: [String]

    enum CodingKeys: String, CodingKey {
        case type
        case title
        case detail
        case reproductionSteps = "reproduction_steps"
        case expectedBehavior = "expected_behavior"
        case actualBehavior = "actual_behavior"
        case extraContext = "extra_context"
        case environment
        case logs
    }

    init(
        type: String,
        title: String,
        detail: String,
        reproductionSteps: String,
        expectedBehavior: String,
        actualBehavior: String,
        extraContext: String,
        environment: FeedbackEnvironmentSnapshot,
        logs: [String]
    ) {
        self.type = type
        self.title = title
        self.detail = detail
        self.reproductionSteps = reproductionSteps.isEmpty ? nil : reproductionSteps
        self.expectedBehavior = expectedBehavior.isEmpty ? nil : expectedBehavior
        self.actualBehavior = actualBehavior.isEmpty ? nil : actualBehavior
        self.extraContext = extraContext.isEmpty ? nil : extraContext
        self.environment = environment
        self.logs = logs
    }
}

private struct SubmitCommentPayload: Encodable {
    let body: String
}

private struct SubmitIssueResponse: Decodable {
    let issueNumber: Int
    let ticketToken: String
    let publicURL: URL?
    let status: String?
    let moderationBlocked: Bool?
    let moderationMessage: String?
    let archiveID: String?

    enum CodingKeys: String, CodingKey {
        case issueNumber = "issue_number"
        case ticketToken = "ticket_token"
        case publicURL = "public_url"
        case status
        case moderationBlocked = "moderation_blocked"
        case moderationMessage = "moderation_message"
        case archiveID = "archive_id"
    }
}

private struct SubmitCommentResponse: Decodable {
    let comment: FeedbackComment?
    let moderationBlocked: Bool?
    let moderationMessage: String?
    let archiveID: String?

    enum CodingKeys: String, CodingKey {
        case comment
        case moderationBlocked = "moderation_blocked"
        case moderationMessage = "moderation_message"
        case archiveID = "archive_id"
    }
}

private struct IssueStatusResponse: Decodable {
    let issueNumber: Int
    let status: String?
    let title: String
    let updatedAt: Date
    let labels: [String]
    let publicURL: URL?
    let closed: Bool
    let comments: [FeedbackComment]

    enum CodingKeys: String, CodingKey {
        case issueNumber = "issue_number"
        case status
        case title
        case updatedAt = "updated_at"
        case labels
        case publicURL = "public_url"
        case closed
        case comments
    }
}

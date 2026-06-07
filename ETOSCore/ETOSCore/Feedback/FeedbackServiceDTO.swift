// ============================================================================
// FeedbackServiceDTO.swift
// ============================================================================
// ETOS LLM Studio 反馈服务
//
// 反馈服务与后端接口交互使用的请求和响应数据结构。
// ============================================================================

import Foundation

struct APIErrorEnvelope: Decodable {
    let error: String
}

struct ChallengeResponse: Decodable {
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

struct SubmitIssuePayload: Encodable {
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

struct SubmitCommentPayload: Encodable {
    let body: String
}

struct SubmitIssueResponse: Decodable {
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

struct SubmitCommentResponse: Decodable {
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

struct IssueTimelineEventResponse: Decodable {
    let id: String
    let type: FeedbackTimelineEventKind
    let actor: String
    let createdAt: Date
    let commit: FeedbackReferencedCommit?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case actor
        case createdAt = "created_at"
        case commit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else if let int64ID = try? container.decode(Int64.self, forKey: .id) {
            id = String(int64ID)
        } else {
            id = UUID().uuidString
        }
        type = try container.decode(FeedbackTimelineEventKind.self, forKey: .type)
        actor = try container.decode(String.self, forKey: .actor)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        commit = try container.decodeIfPresent(FeedbackReferencedCommit.self, forKey: .commit)
    }

    func makeTimelineEvent() -> FeedbackTimelineEvent? {
        switch type {
        case .comment:
            return nil
        case .referencedCommit:
            guard let commit else { return nil }
            return .referencedCommit(
                id: id,
                actor: actor,
                createdAt: createdAt,
                commit: commit
            )
        }
    }
}

struct IssueStatusResponse: Decodable {
    let issueNumber: Int
    let status: String?
    let title: String
    let updatedAt: Date
    let labels: [String]
    let publicURL: URL?
    let closed: Bool
    let comments: [FeedbackComment]
    let timelineEvents: [IssueTimelineEventResponse]

    enum CodingKeys: String, CodingKey {
        case issueNumber = "issue_number"
        case status
        case title
        case updatedAt = "updated_at"
        case labels
        case publicURL = "public_url"
        case closed
        case comments
        case timelineEvents = "timeline_events"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issueNumber = try container.decode(Int.self, forKey: .issueNumber)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        title = try container.decode(String.self, forKey: .title)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        publicURL = try container.decodeIfPresent(URL.self, forKey: .publicURL)
        closed = try container.decode(Bool.self, forKey: .closed)
        comments = try container.decodeIfPresent([FeedbackComment].self, forKey: .comments) ?? []
        timelineEvents = try container.decodeIfPresent([IssueTimelineEventResponse].self, forKey: .timelineEvents) ?? []
    }
}

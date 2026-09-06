// ============================================================================
// UpdateTimelineManagerSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 检查更新代理与 App Store 的解码结构。
// ============================================================================

import Foundation

struct UpdateTimelineFetchResult: Sendable {
    let commits: [UpdateTimelineCommit]
    let rateLimitResetAt: Date?
}

struct UpdateTimelineRefreshPayload: Sendable {
    let commits: [UpdateTimelineCommit]
    let rateLimitResetAt: Date?
    let appStoreLookup: AppStoreLookupResult?
}

struct AppStoreLookupResult: Sendable {
    let version: String
    let trackViewURL: URL?
}

struct AppStoreLookupEnvelope: Decodable {
    let results: [AppStoreLookupItem]
}

struct AppStoreLookupItem: Decodable {
    let version: String
    let trackViewUrl: String?
}

struct UpdateTimelineProxyEnvelope: Decodable {
    let version: Int
    let commits: [UpdateTimelineProxyCommit]
}

struct UpdateTimelineProxyCommit: Decodable {
    let oid: String
    let messageHeadline: String?
    let message: String?
    let committedAt: Date?
    let url: URL?
    let ciContexts: [String]?

    enum CodingKeys: String, CodingKey {
        case oid
        case messageHeadline = "message_headline"
        case message
        case committedAt = "committed_at"
        case url
        case ciContexts = "ci_contexts"
    }

    var timelineCommit: UpdateTimelineCommit {
        let normalizedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = messageHeadline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackHeadline = normalizedMessage?
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayHeadline: String
        if let headline, !headline.isEmpty {
            displayHeadline = headline
        } else {
            displayHeadline = fallbackHeadline ?? oid
        }
        let displayMessage: String
        if let normalizedMessage, !normalizedMessage.isEmpty {
            displayMessage = normalizedMessage
        } else {
            displayMessage = displayHeadline
        }
        return UpdateTimelineCommit(
            oid: oid,
            messageHeadline: displayHeadline,
            message: displayMessage,
            committedDate: committedAt,
            url: url,
            ciContexts: ciContexts ?? []
        )
    }
}

extension String {
    var isPlaceholderCommit: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "localbuild" || normalized == "unknown" || normalized == "n/a"
    }
}

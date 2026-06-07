// ============================================================================
// UpdateTimelineManagerSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 检查更新的 GitHub / App Store 解码结构。
// ============================================================================

import Foundation

struct GitHubTimelineFetchResult: Sendable {
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

struct GitHubGraphQLResponse: Decodable {
    let data: GitHubGraphQLData?
    let errors: [GitHubGraphQLError]?
}

struct GitHubGraphQLError: Decodable {
    let message: String
}

struct GitHubGraphQLData: Decodable {
    let repository: GitHubRepositoryNode
}

struct GitHubRepositoryNode: Decodable {
    let ref: GitHubRefNode?
}

struct GitHubRefNode: Decodable {
    let target: GitHubCommitTarget
}

struct GitHubCommitTarget: Decodable {
    let history: GitHubCommitHistory
}

struct GitHubCommitHistory: Decodable {
    let pageInfo: GitHubPageInfo
    let nodes: [GitHubCommitNode]
}

struct GitHubPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct GitHubCommitNode: Decodable {
    let oid: String
    let messageHeadline: String
    let message: String
    let committedDate: Date?
    let commitUrl: String
    let statusCheckRollup: GitHubStatusCheckRollup?
}

struct GitHubStatusCheckRollup: Decodable {
    let contexts: GitHubStatusCheckContexts
}

struct GitHubStatusCheckContexts: Decodable {
    let nodes: [GitHubStatusCheckNode]
}

struct GitHubStatusCheckNode: Decodable {
    let name: String?
    let checkSuite: GitHubGraphQLCheckSuite?
    let context: String?

    var contextName: String {
        [checkSuite?.app?.name, checkSuite?.workflowRun?.workflow.name, name, context]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }
}

struct GitHubGraphQLCheckSuite: Decodable {
    let app: GitHubGraphQLCheckRunApp?
    let workflowRun: GitHubGraphQLWorkflowRun?
}

struct GitHubGraphQLCheckRunApp: Decodable {
    let name: String
}

struct GitHubGraphQLWorkflowRun: Decodable {
    let workflow: GitHubGraphQLWorkflow
}

struct GitHubGraphQLWorkflow: Decodable {
    let name: String
}

struct GitHubRESTCommitNode: Decodable {
    let sha: String
    let htmlUrl: String
    let commit: GitHubRESTCommit

    private enum CodingKeys: String, CodingKey {
        case sha
        case htmlUrl = "html_url"
        case commit
    }
}

struct GitHubRESTCommit: Decodable {
    let message: String
    let author: GitHubRESTCommitIdentity?
    let committer: GitHubRESTCommitIdentity?
}

struct GitHubRESTCommitIdentity: Decodable {
    let date: Date
}

struct GitHubRESTStatusEnvelope: Decodable {
    let statuses: [GitHubRESTStatusContext]
}

struct GitHubRESTStatusContext: Decodable {
    let context: String
}

struct GitHubRESTCheckRunsEnvelope: Decodable {
    let checkRuns: [GitHubRESTCheckRun]

    private enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

struct GitHubRESTCheckRun: Decodable {
    let name: String
    let app: GitHubRESTCheckRunApp?

    var displayContext: String {
        [app?.name, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }
}

struct GitHubRESTCheckRunApp: Decodable {
    let name: String
}

extension String {
    var isPlaceholderCommit: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "localbuild" || normalized == "unknown" || normalized == "n/a"
    }
}

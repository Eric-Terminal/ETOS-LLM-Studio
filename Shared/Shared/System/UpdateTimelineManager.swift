// ============================================================================
// UpdateTimelineManager.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责无后端检查更新、版本坐标推移、GitHub 缓存和 AI 摘要。
// ============================================================================

import Combine
import Foundation
import os.log

#if canImport(UserNotifications)
import UserNotifications
#endif

public struct UpdateTimelineCommit: Identifiable, Codable, Hashable, Sendable {
    public var id: String { oid }
    public let oid: String
    public let messageHeadline: String
    public let message: String
    public let committedDate: Date?
    public let url: URL?
    public let ciContexts: [String]
    public var inferredBuildNumber: Int?

    public var shortOID: String {
        String(oid.prefix(7))
    }

    public var displayHeadline: String {
        let trimmed = messageHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? shortOID : trimmed
    }

    public var fullMessage: String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayHeadline : trimmed
    }

    public var hasXcodeCloudTrace: Bool {
        ciContexts.contains { context in
            let normalized = context.lowercased()
            return normalized.contains("xcode cloud")
                || normalized.contains("xcodecloud")
                || normalized.contains("apple cloud")
        }
    }

    public init(
        oid: String,
        messageHeadline: String,
        message: String,
        committedDate: Date?,
        url: URL?,
        ciContexts: [String],
        inferredBuildNumber: Int? = nil
    ) {
        self.oid = oid
        self.messageHeadline = messageHeadline
        self.message = message
        self.committedDate = committedDate
        self.url = url
        self.ciContexts = ciContexts
        self.inferredBuildNumber = inferredBuildNumber
    }
}

public enum UpdateTimelineChannel: String, Codable, Hashable, Sendable {
    case appStore
    case testFlight

    public var displayName: String {
        switch self {
        case .appStore:
            return NSLocalizedString("App Store", comment: "Update timeline channel")
        case .testFlight:
            return NSLocalizedString("TestFlight", comment: "Update timeline channel")
        }
    }
}

public enum UpdateTimelineStatus: String, Codable, Hashable, Sendable {
    case unknown
    case current
    case updateAvailable

    public var displayName: String {
        switch self {
        case .unknown:
            return NSLocalizedString("状态未知", comment: "Update timeline status")
        case .current:
            return NSLocalizedString("已是最新", comment: "Update timeline status")
        case .updateAvailable:
            return NSLocalizedString("发现更新", comment: "Update timeline status")
        }
    }
}

public struct UpdateTimelineState: Codable, Hashable, Sendable {
    public var storedPreviousSHA: String?
    public var storedCurrentSHA: String?
    public var realSHA: String?
    public var currentBuildNumber: Int?
    public var channel: UpdateTimelineChannel
    public var latestRemoteSHA: String?
    public var latestRemoteBuildNumber: Int?
    public var appStoreVersion: String?
    public var appStoreURL: URL?
    public var status: UpdateTimelineStatus
    public var lastCheckedAt: Date?
    public var lastErrorMessage: String?
    public var rateLimitResetAt: Date?
    public var notifiedRemoteSHA: String?
    public var summaryKey: String?
    public var summaryText: String?
    public var summaryGeneratedAt: Date?
    public var cachedCommits: [UpdateTimelineCommit]

    public static let empty = UpdateTimelineState(
        storedPreviousSHA: nil,
        storedCurrentSHA: nil,
        realSHA: nil,
        currentBuildNumber: nil,
        channel: .testFlight,
        latestRemoteSHA: nil,
        latestRemoteBuildNumber: nil,
        appStoreVersion: nil,
        appStoreURL: nil,
        status: .unknown,
        lastCheckedAt: nil,
        lastErrorMessage: nil,
        rateLimitResetAt: nil,
        notifiedRemoteSHA: nil,
        summaryKey: nil,
        summaryText: nil,
        summaryGeneratedAt: nil,
        cachedCommits: []
    )

    public var rangeCommits: [UpdateTimelineCommit] {
        guard let current = storedCurrentSHA?.lowercased(), !current.isEmpty else {
            return cachedCommits
        }
        guard let currentIndex = cachedCommits.firstIndex(where: { $0.oid.lowercased().hasPrefix(current) }) else {
            return cachedCommits
        }

        switch status {
        case .updateAvailable:
            return Array(cachedCommits.prefix(currentIndex))
        case .current:
            guard let previous = storedPreviousSHA?.lowercased(), !previous.isEmpty,
                  let previousIndex = cachedCommits.firstIndex(where: { $0.oid.lowercased().hasPrefix(previous) }) else {
                return Array(cachedCommits.prefix(currentIndex + 1))
            }
            let lowerBound = min(currentIndex, previousIndex)
            let upperBound = max(currentIndex, previousIndex)
            return Array(cachedCommits[lowerBound...upperBound])
        case .unknown:
            return Array(cachedCommits.prefix(30))
        }
    }

    public var allowsSummary: Bool {
        !(channel == .appStore && status == .updateAvailable)
    }
}

public enum UpdateTimelineError: LocalizedError {
    case missingGraphQLResponse
    case graphQLError(String)
    case emptyTimeline
    case noModelSelected
    case httpStatus(code: Int, responseBody: Data?, rateLimitResetAt: Date?)

    public var errorDescription: String? {
        switch self {
        case .missingGraphQLResponse:
            return NSLocalizedString("GitHub 返回的数据无法解析。", comment: "Update timeline error")
        case .graphQLError(let message):
            return message
        case .emptyTimeline:
            return NSLocalizedString("还没有可展示的提交记录。", comment: "Update timeline error")
        case .noModelSelected:
            return NSLocalizedString("当前没有可用的聊天模型，无法生成摘要。", comment: "Update timeline error")
        case .httpStatus(let code, let responseBody, _):
            let bodyText = responseBody.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let bodyText, !bodyText.isEmpty {
                return String(format: NSLocalizedString("GitHub 响应错误，状态码: %d\n%@", comment: "Update timeline HTTP error"), code, bodyText)
            }
            return String(format: NSLocalizedString("GitHub 响应错误，状态码: %d", comment: "Update timeline HTTP error"), code)
        }
    }
}

@MainActor
public final class UpdateTimelineManager: ObservableObject {
    public static let shared = UpdateTimelineManager()

    @Published public private(set) var state: UpdateTimelineState {
        didSet {
            displayedCommits = state.rangeCommits
        }
    }
    @Published public private(set) var displayedCommits: [UpdateTimelineCommit]
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isSummarizing = false

    nonisolated private static let stateKey = "updateTimeline.state.v1"
    nonisolated private static let repositoryOwner = "Eric-Terminal"
    nonisolated private static let repositoryName = "ETOS-LLM-Studio"
    nonisolated private static let branchName = "dev"
    nonisolated private static let maxCommitCount = 1_000
    nonisolated private static let graphQLPageSize = 100
    nonisolated private static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "UpdateTimeline")

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var startupProbeCompleted = false
    private var refreshTask: Task<Void, Never>?

    public var autoCheckEnabled: Bool {
        get { AppConfigStore.boolValue(for: .updateTimelineAutoCheckEnabled) }
        set { AppConfigStore.persistSynchronously(.bool(newValue), for: .updateTimelineAutoCheckEnabled, quickSync: false) }
    }

    public var autoSummaryEnabled: Bool {
        get { AppConfigStore.boolValue(for: .updateTimelineAutoSummaryEnabled) }
        set { AppConfigStore.persistSynchronously(.bool(newValue), for: .updateTimelineAutoSummaryEnabled, quickSync: false) }
    }

    public var repositoryURL: URL {
        URL(string: "https://github.com/\(Self.repositoryOwner)/\(Self.repositoryName)")!
    }

    public init(session: URLSession = NetworkSessionConfiguration.makeSession(minimumRequestTimeout: 45)) {
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let loadedState = Self.loadPersistedState(decoder: decoder)
        state = loadedState
        displayedCommits = loadedState.rangeCommits
        applyStartupProbeIfNeeded()
    }

    public func activateOnLaunchIfNeeded() {
        applyStartupProbeIfNeeded()
        guard autoCheckEnabled else { return }
        guard refreshTask == nil else { return }
        refreshTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshIfNeeded()
            await MainActor.run {
                self?.refreshTask = nil
            }
        }
    }

    public func refreshIfNeeded() async {
        if let checkedAt = state.lastCheckedAt,
           Date().timeIntervalSince(checkedAt) < 1_800,
           !state.cachedCommits.isEmpty {
            return
        }
        await refresh(forceNetwork: true)
    }

    public func refresh(forceNetwork: Bool = true) async {
        applyStartupProbeIfNeeded()
        if !forceNetwork, !state.cachedCommits.isEmpty {
            return
        }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snapshot = state
            let session = session
            let payload = try await Task.detached(priority: .utility) {
                let response = try await Self.fetchGitHubTimeline(session: session)
                guard !response.commits.isEmpty else { throw UpdateTimelineError.emptyTimeline }
                let commits = Self.inferBuildNumbers(
                    for: response.commits,
                    currentBuildNumber: snapshot.currentBuildNumber,
                    currentSHA: snapshot.storedCurrentSHA ?? snapshot.realSHA
                )
                let lookup = snapshot.channel == .appStore ? try? await Self.fetchAppStoreLookup(session: session) : nil
                return UpdateTimelineRefreshPayload(
                    commits: commits,
                    rateLimitResetAt: response.rateLimitResetAt,
                    appStoreLookup: lookup
                )
            }.value
            var updated = state
            updated.cachedCommits = payload.commits
            updated.latestRemoteSHA = payload.commits.first?.oid
            updated.latestRemoteBuildNumber = payload.commits.first?.inferredBuildNumber
            if let lookup = payload.appStoreLookup {
                updated.appStoreVersion = lookup.version
                updated.appStoreURL = lookup.trackViewURL
            }
            updated.lastCheckedAt = Date()
            updated.lastErrorMessage = nil
            updated.rateLimitResetAt = payload.rateLimitResetAt
            updated.status = status(for: updated)

            if shouldClearSummary(from: state, to: updated) {
                updated.summaryKey = nil
                updated.summaryText = nil
                updated.summaryGeneratedAt = nil
            }
            state = updated
            persistState()
            await notifyUpdateIfNeeded()
            if autoSummaryEnabled {
                await generateSummaryIfNeeded()
            }
        } catch {
            var updated = state
            updated.lastCheckedAt = Date()
            updated.lastErrorMessage = localizedDescription(for: error)
            if case UpdateTimelineError.httpStatus(let code, _, let resetAt) = error, code == 403 {
                updated.rateLimitResetAt = resetAt ?? Date().addingTimeInterval(3_600)
            }
            state = updated
            persistState()
            Self.logger.error("刷新检查更新失败: \(Self.localizedDescription(for: error), privacy: .public)")
        }
    }

    public func generateSummaryIfNeeded() async {
        let key = summaryKey(for: state)
        guard state.summaryKey != key || (state.summaryText ?? "").isEmpty else { return }
        await generateSummary()
    }

    public func generateSummary() async {
        applyStartupProbeIfNeeded()
        if isSummarizing { return }
        let commits = displayedCommits
        guard !commits.isEmpty else {
            setError(UpdateTimelineError.emptyTimeline)
            return
        }
        guard state.allowsSummary else { return }
        guard let model = ChatService.shared.selectedModelSubject.value ?? ChatService.shared.activatedRunnableModels.first(where: { $0.model.isChatModel }) else {
            setError(UpdateTimelineError.noModelSelected)
            return
        }

        isSummarizing = true
        defer { isSummarizing = false }

        do {
            let raw = try await ChatService.shared.generateDetachedChatCompletion(
                systemPrompt: Self.summarySystemPrompt,
                userPrompt: summaryUserPrompt(for: commits),
                temperature: 0.35,
                runnableModel: model,
                requestSource: .updateTimelineSummary
            )
            var updated = state
            updated.summaryKey = summaryKey(for: state)
            updated.summaryText = raw
            updated.summaryGeneratedAt = Date()
            updated.lastErrorMessage = nil
            state = updated
            persistState()
        } catch {
            setError(error)
        }
    }

    public func resetNotificationMarker() {
        state.notifiedRemoteSHA = nil
        persistState()
    }

    private func applyStartupProbeIfNeeded() {
        let realSHA = Self.bundleCommitHash()
        let buildNumber = Self.bundleBuildNumber()
        let channel = Self.detectChannel()

        guard !startupProbeCompleted || state.realSHA != realSHA || state.currentBuildNumber != buildNumber || state.channel != channel else {
            return
        }
        startupProbeCompleted = true

        var updated = state
        updated.realSHA = realSHA
        updated.currentBuildNumber = buildNumber
        updated.channel = channel
        if let realSHA, !realSHA.isPlaceholderCommit {
            let current = updated.storedCurrentSHA
            if current?.caseInsensitiveCompare(realSHA) != .orderedSame {
                updated.storedPreviousSHA = current
                updated.storedCurrentSHA = realSHA
                updated.notifiedRemoteSHA = nil
                updated.summaryKey = nil
                updated.summaryText = nil
                updated.summaryGeneratedAt = nil
            }
        }
        updated.status = status(for: updated)
        state = updated
        persistState()
    }

    nonisolated private static func fetchGitHubTimeline(session: URLSession) async throws -> GitHubTimelineFetchResult {
        do {
            return try await fetchGitHubTimelineWithGraphQL(session: session)
        } catch {
            Self.logger.warning("GraphQL 时间线拉取失败，降级到 REST: \(localizedDescription(for: error), privacy: .public)")
            return try await fetchGitHubTimelineWithREST(session: session)
        }
    }

    nonisolated private static func fetchGitHubTimelineWithGraphQL(session: URLSession) async throws -> GitHubTimelineFetchResult {
        var allCommits: [UpdateTimelineCommit] = []
        var cursor: String?
        var latestResetAt: Date?
        let decoder = timelineJSONDecoder()

        while allCommits.count < Self.maxCommitCount {
            var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("ETOS-LLM-Studio", forHTTPHeaderField: "User-Agent")
            let afterValue: Any = cursor ?? NSNull()
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "query": Self.graphQLQuery,
                "variables": [
                    "pageSize": min(Self.graphQLPageSize, Self.maxCommitCount - allCommits.count),
                    "after": afterValue
                ]
            ])

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateTimelineError.missingGraphQLResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw httpStatusError(for: httpResponse, data: data)
            }
            latestResetAt = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { raw -> Date? in
                guard let timestamp = TimeInterval(raw) else { return nil }
                return Date(timeIntervalSince1970: timestamp)
            } ?? latestResetAt

            let envelope = try decoder.decode(GitHubGraphQLResponse.self, from: data)
            if let message = envelope.errors?.compactMap(\.message).joined(separator: "\n"), !message.isEmpty {
                throw UpdateTimelineError.graphQLError(message)
            }
            guard let history = envelope.data?.repository.ref?.target.history else {
                throw UpdateTimelineError.missingGraphQLResponse
            }
            allCommits.append(contentsOf: history.nodes.map { node in
                UpdateTimelineCommit(
                    oid: node.oid,
                    messageHeadline: node.messageHeadline,
                    message: node.message,
                    committedDate: node.committedDate,
                    url: URL(string: node.commitUrl),
                    ciContexts: node.statusCheckRollup?.contexts.nodes.map(\.contextName) ?? []
                )
            })
            guard history.pageInfo.hasNextPage,
                  let endCursor = history.pageInfo.endCursor,
                  !endCursor.isEmpty else {
                break
            }
            cursor = endCursor
        }
        return GitHubTimelineFetchResult(commits: allCommits, rateLimitResetAt: latestResetAt)
    }

    nonisolated private static func fetchGitHubTimelineWithREST(session: URLSession) async throws -> GitHubTimelineFetchResult {
        var allCommits: [UpdateTimelineCommit] = []
        var latestResetAt: Date?
        var page = 1
        let decoder = timelineJSONDecoder()

        while allCommits.count < Self.maxCommitCount {
            var components = URLComponents(string: "https://api.github.com/repos/\(Self.repositoryOwner)/\(Self.repositoryName)/commits")!
            components.queryItems = [
                URLQueryItem(name: "sha", value: Self.branchName),
                URLQueryItem(name: "per_page", value: "\(Self.graphQLPageSize)"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            guard let url = components.url else { break }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("ETOS-LLM-Studio", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateTimelineError.missingGraphQLResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw httpStatusError(for: httpResponse, data: data)
            }
            latestResetAt = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { raw -> Date? in
                guard let timestamp = TimeInterval(raw) else { return nil }
                return Date(timeIntervalSince1970: timestamp)
            } ?? latestResetAt

            let nodes = try decoder.decode([GitHubRESTCommitNode].self, from: data)
            guard !nodes.isEmpty else { break }
            allCommits.append(contentsOf: nodes.map { node in
                UpdateTimelineCommit(
                    oid: node.sha,
                    messageHeadline: node.commit.message.components(separatedBy: .newlines).first ?? node.sha,
                    message: node.commit.message,
                    committedDate: node.commit.committer?.date ?? node.commit.author?.date,
                    url: URL(string: node.htmlUrl),
                    ciContexts: []
                )
            })
            guard nodes.count >= Self.graphQLPageSize else { break }
            page += 1
        }

        let enrichedCommits = await enrichRESTCommitsWithCIContexts(allCommits, session: session)
        return GitHubTimelineFetchResult(commits: enrichedCommits, rateLimitResetAt: latestResetAt)
    }

    nonisolated private static func enrichRESTCommitsWithCIContexts(_ commits: [UpdateTimelineCommit], session: URLSession) async -> [UpdateTimelineCommit] {
        guard !commits.isEmpty else { return commits }
        let enrichmentLimit = min(commits.count, 20)
        var result = commits

        for index in 0..<enrichmentLimit {
            guard !Task.isCancelled else { break }
            let oid = result[index].oid
            let contexts = await fetchRESTCIContexts(for: oid, session: session)
            guard !contexts.isEmpty else { continue }
            result[index] = UpdateTimelineCommit(
                oid: result[index].oid,
                messageHeadline: result[index].messageHeadline,
                message: result[index].message,
                committedDate: result[index].committedDate,
                url: result[index].url,
                ciContexts: contexts,
                inferredBuildNumber: result[index].inferredBuildNumber
            )
        }

        return result
    }

    nonisolated private static func fetchRESTCIContexts(for oid: String, session: URLSession) async -> [String] {
        let statuses = (try? await fetchRESTStatusContexts(for: oid, session: session)) ?? []
        let checkRuns = (try? await fetchRESTCheckRunContexts(for: oid, session: session)) ?? []
        let contexts = statuses + checkRuns
        var seen = Set<String>()
        return contexts.filter { context in
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
    }

    nonisolated private static func fetchRESTStatusContexts(for oid: String, session: URLSession) async throws -> [String] {
        let url = URL(string: "https://api.github.com/repos/\(Self.repositoryOwner)/\(Self.repositoryName)/commits/\(oid)/status")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ETOS-LLM-Studio", forHTTPHeaderField: "User-Agent")
        let decoder = timelineJSONDecoder()

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateTimelineError.missingGraphQLResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw httpStatusError(for: httpResponse, data: data)
        }
        return try decoder.decode(GitHubRESTStatusEnvelope.self, from: data).statuses.map(\.context)
    }

    nonisolated private static func fetchRESTCheckRunContexts(for oid: String, session: URLSession) async throws -> [String] {
        let url = URL(string: "https://api.github.com/repos/\(Self.repositoryOwner)/\(Self.repositoryName)/commits/\(oid)/check-runs")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ETOS-LLM-Studio", forHTTPHeaderField: "User-Agent")
        let decoder = timelineJSONDecoder()

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateTimelineError.missingGraphQLResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw httpStatusError(for: httpResponse, data: data)
        }
        return try decoder.decode(GitHubRESTCheckRunsEnvelope.self, from: data).checkRuns.map(\.displayContext)
    }

    nonisolated private static func fetchAppStoreLookup(session: URLSession) async throws -> AppStoreLookupResult? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: Bundle.main.bundleIdentifier ?? "com.ericterminal.els")
        ]
        guard let url = components.url else { return nil }
        let decoder = timelineJSONDecoder()
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateTimelineError.missingGraphQLResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw httpStatusError(for: httpResponse, data: data)
        }
        let lookup = try decoder.decode(AppStoreLookupEnvelope.self, from: data)
        guard let result = lookup.results.first else { return nil }
        return AppStoreLookupResult(
            version: result.version,
            trackViewURL: result.trackViewUrl.flatMap(URL.init(string:))
        )
    }

    nonisolated private static func httpStatusError(for response: HTTPURLResponse, data: Data) -> UpdateTimelineError {
        let resetAt = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { raw -> Date? in
            guard let timestamp = TimeInterval(raw) else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        return .httpStatus(code: response.statusCode, responseBody: data, rateLimitResetAt: resetAt)
    }

    nonisolated private static func inferBuildNumbers(
        for commits: [UpdateTimelineCommit],
        currentBuildNumber: Int?,
        currentSHA: String?
    ) -> [UpdateTimelineCommit] {
        guard !commits.isEmpty else { return commits }
        var result = commits
        guard let currentBuildNumber else { return result }
        guard let currentSHA, !currentSHA.isPlaceholderCommit,
              let currentIndex = result.firstIndex(where: { $0.oid.lowercased().hasPrefix(currentSHA.lowercased()) }) else {
            return result
        }

        result[currentIndex].inferredBuildNumber = currentBuildNumber

        var build = currentBuildNumber
        if currentIndex > 0 {
            for index in stride(from: currentIndex - 1, through: 0, by: -1) {
                if result[index].hasXcodeCloudTrace {
                    build += 1
                }
                result[index].inferredBuildNumber = build
            }
        }

        build = currentBuildNumber
        if currentIndex + 1 < result.count {
            for index in (currentIndex + 1)..<result.count {
                if result[index].hasXcodeCloudTrace {
                    build = max(1, build - 1)
                }
                result[index].inferredBuildNumber = build
            }
        }
        return result
    }

    private func status(for state: UpdateTimelineState) -> UpdateTimelineStatus {
        if state.channel == .appStore {
            guard let remoteVersion = state.appStoreVersion,
                  let localVersion = Self.bundleMarketingVersion() else {
                return .unknown
            }
            return Self.isVersion(remoteVersion, newerThan: localVersion) ? .updateAvailable : .current
        }

        guard let latest = state.latestRemoteSHA?.lowercased(), !latest.isEmpty else { return .unknown }
        guard let current = state.storedCurrentSHA?.lowercased(), !current.isEmpty, !current.isPlaceholderCommit else {
            return .unknown
        }
        return latest.hasPrefix(current) || current.hasPrefix(latest) ? .current : .updateAvailable
    }

    private func notifyUpdateIfNeeded() async {
        guard autoCheckEnabled else { return }
        guard state.status == .updateAvailable,
              let latest = state.latestRemoteSHA,
              state.notifiedRemoteSHA != latest else {
            return
        }
        var updated = state
        updated.notifiedRemoteSHA = latest
        state = updated
        persistState()

        #if canImport(UserNotifications)
        let granted = await AppLocalNotificationCenter.shared.requestAuthorizationIfNeeded(options: [.alert, .sound, .badge])
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("发现 ETOS LLM Studio 更新", comment: "Update timeline notification title")
        content.body = NSLocalizedString("点按查看 Git 提交时间线和更新摘要。", comment: "Update timeline notification body")
        content.threadIdentifier = "updateTimeline"
        content.userInfo = AppLocalNotificationCenter.updateTimelineUserInfo()
        let request = UNNotificationRequest(
            identifier: "updateTimeline.\(latest)",
            content: content,
            trigger: nil
        )
        _ = await AppLocalNotificationCenter.shared.addNotificationRequest(request)
        #endif
    }

    private func shouldClearSummary(from oldState: UpdateTimelineState, to newState: UpdateTimelineState) -> Bool {
        summaryKey(for: oldState) != summaryKey(for: newState)
    }

    private func summaryKey(for state: UpdateTimelineState) -> String {
        [
            state.channel.rawValue,
            state.status.rawValue,
            state.storedPreviousSHA ?? "",
            state.storedCurrentSHA ?? "",
            state.latestRemoteSHA ?? ""
        ].joined(separator: "|")
    }

    private func summaryUserPrompt(for commits: [UpdateTimelineCommit]) -> String {
        let instruction: String
        switch (state.channel, state.status) {
        case (.appStore, .updateAvailable):
            instruction = NSLocalizedString("当前 App Store 版本不是最新。请只简洁说明有可用更新，并提醒用户前往更新，不要展开长篇摘要。", comment: "Update timeline prompt instruction")
        case (.appStore, .current):
            instruction = NSLocalizedString("当前 App Store 版本已是正式版最新。请优先详述本次已安装更新带来的变化，再用一小段简要报道 TestFlight/开发分支前瞻动态。", comment: "Update timeline prompt instruction")
        case (.testFlight, .updateAvailable):
            instruction = NSLocalizedString("当前 TestFlight 版本不是最新。请总结远端最新提交新增了什么，并引导用户更新。", comment: "Update timeline prompt instruction")
        case (.testFlight, .current):
            instruction = NSLocalizedString("当前 TestFlight 版本已是最新。请总结上一个版本到当前版本这个跨度带来的变化。", comment: "Update timeline prompt instruction")
        default:
            instruction = NSLocalizedString("请基于这些提交生成简洁清晰的更新摘要。", comment: "Update timeline prompt instruction")
        }

        let commitContext: String
        if state.channel == .appStore, state.status == .current {
            let previewCommits = previewCommitsAfterCurrentInstall()
            let installedSpanTitle = NSLocalizedString("本次已安装更新跨度:", comment: "Update timeline prompt installed span title")
            let previewSpanTitle = NSLocalizedString("TestFlight/开发分支前瞻跨度:", comment: "Update timeline prompt preview span title")
            commitContext = """
            \(installedSpanTitle)
            \(commitText(for: commits))

            \(previewSpanTitle)
            \(previewCommits.isEmpty ? NSLocalizedString("暂无前瞻提交。", comment: "Update timeline prompt no preview commits") : commitText(for: previewCommits))
            """
        } else {
            commitContext = commitText(for: commits)
        }
        let outputInstruction = NSLocalizedString("请使用项目当前界面语言输出，避免逐条复述 SHA，保留重要功能变化、修复和潜在影响。", comment: "Update timeline prompt output instruction")
        let commitsLabel = NSLocalizedString("Commit", comment: "Update timeline prompt commits label")

        return """
        \(instruction)

        \(outputInstruction)

        \(commitsLabel):
        \(commitContext)
        """
    }

    private func commitText(for commits: [UpdateTimelineCommit]) -> String {
        commits.prefix(120).map { commit in
            let build = commit.inferredBuildNumber.map {
                String(format: NSLocalizedString("Build %d", comment: "Update timeline prompt build number"), $0)
            } ?? NSLocalizedString("Build 未知", comment: "Update timeline prompt build unknown")
            return """
            - \(commit.shortOID) [\(build)]
            \(commit.fullMessage)
            """
        }.joined(separator: "\n\n")
    }

    private func previewCommitsAfterCurrentInstall() -> [UpdateTimelineCommit] {
        guard let current = state.storedCurrentSHA?.lowercased(), !current.isEmpty,
              let currentIndex = state.cachedCommits.firstIndex(where: { $0.oid.lowercased().hasPrefix(current) }) else {
            return []
        }
        return Array(state.cachedCommits.prefix(currentIndex))
    }

    private func setError(_ error: Error) {
        var updated = state
        updated.lastErrorMessage = localizedDescription(for: error)
        state = updated
        persistState()
    }

    private func localizedDescription(for error: Error) -> String {
        Self.localizedDescription(for: error)
    }

    private func persistState() {
        guard let data = try? encoder.encode(state) else { return }
        Persistence.writeAppConfig(key: Self.stateKey, data: data)
    }

    nonisolated private static func timelineJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated private static func localizedDescription(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func loadPersistedState(decoder: JSONDecoder) -> UpdateTimelineState {
        guard let data = Persistence.readAppConfigData(key: stateKey),
              let decoded = try? decoder.decode(UpdateTimelineState.self, from: data) else {
            return .empty
        }
        return decoded
    }

    private static func bundleCommitHash() -> String? {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "ETCommitHash") as? String
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func bundleBuildNumber() -> Int? {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let rawValue else { return nil }
        return Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func bundleMarketingVersion() -> String? {
        let rawValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func detectChannel() -> UpdateTimelineChannel {
        let receiptPath = Bundle.main.appStoreReceiptURL?.lastPathComponent.lowercased() ?? ""
        return receiptPath.contains("sandboxreceipt") ? .testFlight : .appStore
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    nonisolated private static var summarySystemPrompt: String {
        NSLocalizedString("你是 ETOS LLM Studio 的更新日志助手。你要从 Git 提交记录中提炼用户能理解的更新摘要，先讲重要变化，再讲修复与细节。不要编造提交里没有的信息。", comment: "Update timeline summary system prompt")
    }

    nonisolated private static let graphQLQuery = """
    query UpdateTimeline($pageSize: Int!, $after: String) {
      repository(owner: "\(repositoryOwner)", name: "\(repositoryName)") {
        ref(qualifiedName: "\(branchName)") {
          target {
            ... on Commit {
              history(first: $pageSize, after: $after) {
                pageInfo {
                  hasNextPage
                  endCursor
                }
                nodes {
                  oid
                  messageHeadline
                  message
                  committedDate
                  commitUrl
                  statusCheckRollup {
                    contexts(first: 30) {
                      nodes {
                        ... on CheckRun {
                          name
                          app {
                            name
                          }
                        }
                        ... on StatusContext {
                          context
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """
}

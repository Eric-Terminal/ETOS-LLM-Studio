// ============================================================================
// SessionHistoryModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 定义历史会话检索命中模型与检索辅助逻辑。
// ============================================================================

import Foundation

// MARK: - 历史会话检索

/// 历史会话检索命中来源
public enum SessionHistorySearchHitSource: Hashable, Sendable {
    case sessionName
    case topicPrompt
    case enhancedPrompt
    case userMessage
    case assistantMessage
    case systemMessage
    case toolMessage
    case errorMessage
}

/// 历史会话检索命中明细
public struct SessionHistorySearchMatch: Hashable, Sendable {
    public let source: SessionHistorySearchHitSource
    public let preview: String
    /// 命中消息序号（从 1 开始）。标题/提示词命中时为 nil。
    public let messageOrdinal: Int?

    public init(source: SessionHistorySearchHitSource, preview: String, messageOrdinal: Int? = nil) {
        self.source = source
        self.preview = preview
        self.messageOrdinal = messageOrdinal
    }
}

/// 历史会话检索结果项（按单条命中拆分）
public struct SessionHistorySearchResult: Identifiable, Hashable, Sendable {
    public let id: String
    public let sessionID: UUID
    public let sessionName: String
    public let match: SessionHistorySearchMatch
    public let matchIndexInSession: Int

    public var messageOrdinal: Int? {
        match.messageOrdinal
    }

    public init(sessionID: UUID, sessionName: String, match: SessionHistorySearchMatch, matchIndexInSession: Int) {
        self.id = "\(sessionID.uuidString)-\(matchIndexInSession)"
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.match = match
        self.matchIndexInSession = matchIndexInSession
    }
}

/// 历史会话检索命中结果
public struct SessionHistorySearchHit: Hashable, Sendable {
    public let sessionID: UUID
    public let source: SessionHistorySearchHitSource
    public let preview: String
    public let matches: [SessionHistorySearchMatch]

    public var matchCount: Int {
        matches.count
    }

    public init(sessionID: UUID, source: SessionHistorySearchHitSource, preview: String) {
        self.sessionID = sessionID
        self.source = source
        self.preview = preview
        self.matches = [
            SessionHistorySearchMatch(source: source, preview: preview)
        ]
    }

    public init(sessionID: UUID, matches: [SessionHistorySearchMatch]) {
        self.sessionID = sessionID
        if let first = matches.first {
            self.source = first.source
            self.preview = first.preview
            self.matches = matches
        } else {
            self.source = .sessionName
            self.preview = ""
            self.matches = []
        }
    }
}

/// 历史会话检索工具
public enum SessionHistorySearchSupport {
    private enum SearchMatcher {
        case plain(query: String, normalizedQuery: String)
        case regex(NSRegularExpression)
    }

    /// 归一化检索词，供 UI 层判断当前是否处于检索状态。
    public static func normalizedQuery(_ query: String) -> String {
        normalized(query)
    }

    /// 在会话名称、主题提示、增强提示词和消息正文中执行检索。
    public static func searchHits(
        sessions: [ChatSession],
        query: String,
        currentSessionID: UUID? = nil,
        currentSessionMessages: [ChatMessage] = [],
        messageLoader: (UUID) -> [ChatMessage]
    ) -> [UUID: SessionHistorySearchHit] {
        guard let matcher = makeMatcher(query) else { return [:] }

        var hits: [UUID: SessionHistorySearchHit] = [:]
        for session in sessions {
            let matches = allMatches(
                in: session,
                matcher: matcher,
                currentSessionID: currentSessionID,
                currentSessionMessages: currentSessionMessages,
                messageLoader: messageLoader
            )
            guard !matches.isEmpty else {
                continue
            }
            hits[session.id] = SessionHistorySearchHit(sessionID: session.id, matches: matches)
        }
        return hits
    }

    /// 将会话级命中结果拍平成逐条命中，保留原始会话顺序与每个会话内的命中顺序。
    public static func flattenedResults(
        sessions: [ChatSession],
        hits: [UUID: SessionHistorySearchHit]
    ) -> [SessionHistorySearchResult] {
        sessions.flatMap { session -> [SessionHistorySearchResult] in
            guard let hit = hits[session.id] else { return [] }
            return hit.matches.enumerated().map { matchIndex, match in
                SessionHistorySearchResult(
                    sessionID: session.id,
                    sessionName: session.name,
                    match: match,
                    matchIndexInSession: matchIndex
                )
            }
        }
    }

    private static func allMatches(
        in session: ChatSession,
        matcher: SearchMatcher,
        currentSessionID: UUID?,
        currentSessionMessages: [ChatMessage],
        messageLoader: (UUID) -> [ChatMessage]
    ) -> [SessionHistorySearchMatch] {
        var collectedMatches: [SessionHistorySearchMatch] = []

        if matches(session.name, with: matcher) {
            collectedMatches.append(
                SessionHistorySearchMatch(
                    source: .sessionName,
                    preview: previewText(session.name, matcher: matcher)
                )
            )
        }

        if let topicPrompt = nonEmptyTrimmed(session.topicPrompt),
           matches(topicPrompt, with: matcher) {
            collectedMatches.append(
                SessionHistorySearchMatch(
                    source: .topicPrompt,
                    preview: previewText(topicPrompt, matcher: matcher)
                )
            )
        }

        if let enhancedPrompt = nonEmptyTrimmed(session.enhancedPrompt),
           matches(enhancedPrompt, with: matcher) {
            collectedMatches.append(
                SessionHistorySearchMatch(
                    source: .enhancedPrompt,
                    preview: previewText(enhancedPrompt, matcher: matcher)
                )
            )
        }

        let sessionMessages = session.id == currentSessionID ? currentSessionMessages : messageLoader(session.id)
        for (messageIndex, message) in sessionMessages.enumerated() {
            for versionContent in message.getAllVersions() {
                guard let content = nonEmptyTrimmed(versionContent) else { continue }
                guard matches(content, with: matcher) else { continue }
                collectedMatches.append(
                    SessionHistorySearchMatch(
                        source: source(for: message.role),
                        preview: previewText(content, matcher: matcher),
                        messageOrdinal: messageIndex + 1
                    )
                )
                break
            }
        }
        return collectedMatches
    }

    private static func source(for role: MessageRole) -> SessionHistorySearchHitSource {
        switch role {
        case .user:
            return .userMessage
        case .assistant:
            return .assistantMessage
        case .system:
            return .systemMessage
        case .tool:
            return .toolMessage
        case .error:
            return .errorMessage
        }
    }

    private static func nonEmptyTrimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func makeMatcher(_ query: String) -> SearchMatcher? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let regex = try? NSRegularExpression(pattern: trimmed, options: [.caseInsensitive]) {
            return .regex(regex)
        }
        return .plain(query: collapsedPreviewText(trimmed), normalizedQuery: normalized(trimmed))
    }

    private static func matches(_ text: String, with matcher: SearchMatcher) -> Bool {
        switch matcher {
        case .plain(_, let normalizedQuery):
            return normalized(text).contains(normalizedQuery)
        case .regex(let regex):
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
    }

    private static func previewText(
        _ text: String,
        matcher: SearchMatcher,
        prefixLength: Int = 20,
        suffixLength: Int = 20
    ) -> String {
        let collapsed = collapsedPreviewText(text)
        guard let matchRange = firstMatchRange(in: collapsed, matcher: matcher) else {
            return compactPreviewText(
                collapsed,
                prefixLength: prefixLength,
                suffixLength: suffixLength
            )
        }

        let prefixStart = collapsed.index(
            matchRange.lowerBound,
            offsetBy: -prefixLength,
            limitedBy: collapsed.startIndex
        ) ?? collapsed.startIndex
        let suffixEnd = collapsed.index(
            matchRange.upperBound,
            offsetBy: suffixLength,
            limitedBy: collapsed.endIndex
        ) ?? collapsed.endIndex

        let visiblePrefix = String(collapsed[prefixStart..<matchRange.lowerBound])
        let visibleMatch = String(collapsed[matchRange])
        let visibleSuffix = String(collapsed[matchRange.upperBound..<suffixEnd])
        let leadingEllipsis = prefixStart > collapsed.startIndex ? "…" : ""
        let trailingEllipsis = suffixEnd < collapsed.endIndex ? "…" : ""

        return leadingEllipsis + visiblePrefix + visibleMatch + visibleSuffix + trailingEllipsis
    }

    private static func compactPreviewText(
        _ text: String,
        prefixLength: Int,
        suffixLength: Int
    ) -> String {
        let compactLimit = prefixLength + suffixLength
        guard text.count > compactLimit else { return text }
        return String(text.prefix(prefixLength)) + "…" + String(text.suffix(suffixLength))
    }

    private static func firstMatchRange(
        in text: String,
        matcher: SearchMatcher
    ) -> Range<String.Index>? {
        switch matcher {
        case .plain(let query, _):
            guard !query.isEmpty else { return nil }
            return text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        case .regex(let regex):
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let swiftRange = Range(match.range, in: text) else {
                return nil
            }
            return swiftRange
        }
    }

    private static func collapsedPreviewText(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

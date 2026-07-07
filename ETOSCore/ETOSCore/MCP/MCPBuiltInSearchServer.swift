// ============================================================================
// MCPBuiltInSearchServer.swift
// ============================================================================
// ETOS LLM Studio
//
// 应用内置的 MCP 搜索服务器。它通过设备网络抓取真实网页结果，并通过 MCP
// 标准 initialize / tools/list / tools/call 流程暴露给模型使用。
// ============================================================================

import Foundation
import Logging
import MCP

public enum MCPBuiltInSearchServer {
    public static let serverID = UUID(uuidString: "45544F53-0000-0000-0000-000053454152")!
    public static let toolID = "search_web"
    public static let endpoint = "builtin://search"

    public static func isBuiltInSearchServer(_ server: MCPServerConfiguration) -> Bool {
        server.id == serverID || server.transport == .builtInSearch
    }

    static func defaultConfiguration() -> MCPServerConfiguration {
        MCPServerConfiguration(
            id: serverID,
            displayName: NSLocalizedString("内置搜索", comment: "Built-in MCP search server display name"),
            notes: NSLocalizedString("应用内置的网页搜索 MCP 服务器，可按查询词返回真实网页结果。", comment: "Built-in MCP search server notes"),
            transport: .builtInSearch,
            isSelectedForChat: true,
            toolApprovalPolicies: [toolID: .alwaysAllow],
            sortIndex: 0
        )
    }

    static func prepareServersForManager(
        _ storedServers: [MCPServerConfiguration],
        deletedBuiltInServerIDs: Set<UUID> = []
    ) -> (
        servers: [MCPServerConfiguration],
        serverToPersist: MCPServerConfiguration?
    ) {
        var servers = storedServers
        let defaultServer = defaultConfiguration()
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            guard !deletedBuiltInServerIDs.contains(serverID) else {
                return (servers, nil)
            }
            servers.append(defaultServer)
            return (servers, defaultServer)
        }

        var server = servers[index]
        var shouldPersist = false
        if server.transport != .builtInSearch {
            server.transport = .builtInSearch
            shouldPersist = true
        }
        if server.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            server.displayName = defaultServer.displayName
            shouldPersist = true
        }
        if server.toolApprovalPolicies[toolID] == nil {
            server.toolApprovalPolicies[toolID] = .alwaysAllow
            shouldPersist = true
        }
        servers[index] = server
        return (servers, shouldPersist ? server : nil)
    }
}

public actor MCPBuiltInSearchTransport: Transport, MCPSDKTransportControl {
    private let engine: MCPBuiltInSearchServerEngine
    private let loggerInstance = Logger(
        label: "etos.mcp.transport.builtin-search",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var connected = false
    private var protocolVersion: String?

    public nonisolated var logger: Logger { loggerInstance }

    public init() {
        self.init(session: MCPBuiltInWebSearchClient.makeDefaultSession())
    }

    public init(session: URLSession) {
        self.engine = MCPBuiltInSearchServerEngine(session: session)
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    init(dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.engine = MCPBuiltInSearchServerEngine(dataLoader: dataLoader)
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        connected = true
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        continuation.finish()
    }

    public nonisolated func disconnect() {
        Task {
            await self.disconnect()
        }
    }

    public func send(_ data: Data) async throws {
        guard connected else {
            throw MCPClientError.notConnected
        }
        if isJSONRPCMessageWithoutExpectedResponse(data) {
            try await engine.handleNotification(data)
            return
        }
        let response = try await engine.handleMessage(data)
        continuation.yield(response)
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    public func currentResumptionToken() async -> String? {
        nil
    }

    public func updateResumptionToken(_ token: String?) async {}

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }

    public func terminateSession() async {
        await disconnect()
    }
}

public final class MCPBuiltInSearchLegacyTransport: MCPTransport, MCPProtocolVersionConfigurableTransport, @unchecked Sendable {
    private let engine: MCPBuiltInSearchServerEngine
    private var protocolVersion: String?

    public init() {
        self.engine = MCPBuiltInSearchServerEngine()
    }

    public init(session: URLSession) {
        self.engine = MCPBuiltInSearchServerEngine(session: session)
    }

    init(dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.engine = MCPBuiltInSearchServerEngine(dataLoader: dataLoader)
    }

    public func sendMessage(_ payload: Data) async throws -> Data {
        try await engine.handleMessage(payload)
    }

    public func sendNotification(_ payload: Data) async throws {
        try await engine.handleNotification(payload)
    }

    public func updateProtocolVersion(_ protocolVersion: String?) async {
        self.protocolVersion = protocolVersion
    }
}

actor MCPBuiltInSearchServerEngine {
    private let jsonrpcVersion = "2.0"
    private let searchClient: MCPBuiltInWebSearchClient

    init() {
        self.searchClient = MCPBuiltInWebSearchClient()
    }

    init(session: URLSession) {
        self.searchClient = MCPBuiltInWebSearchClient(session: session)
    }

    init(dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.searchClient = MCPBuiltInWebSearchClient(dataLoader: dataLoader)
    }

    func handleNotification(_ payload: Data) async throws {
        _ = try requestObject(from: payload)
    }

    func handleMessage(_ payload: Data) async throws -> Data {
        let request = try requestObject(from: payload)
        guard let id = request["id"] else {
            throw MCPClientError.invalidResponse
        }
        guard let method = request["method"] as? String else {
            return try errorResponse(id: id, code: -32600, message: "Invalid Request")
        }

        switch method {
        case "initialize":
            return try successResponse(id: id, result: initializeResult())
        case "tools/list":
            return try successResponse(id: id, result: toolsListResult())
        case "tools/call":
            return try successResponse(id: id, result: await toolCallResult(from: request["params"] as? [String: Any]))
        case "resources/list":
            return try successResponse(id: id, result: ["resources": []])
        case "resources/templates/list":
            return try successResponse(id: id, result: ["resourceTemplates": []])
        case "prompts/list":
            return try successResponse(id: id, result: ["prompts": []])
        default:
            return try errorResponse(id: id, code: -32601, message: "Method not found")
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": MCPProtocolVersion.current,
            "capabilities": [
                "tools": [
                    "listChanged": false
                ],
                "resources": [
                    "subscribe": false,
                    "listChanged": false
                ],
                "prompts": [
                    "listChanged": false
                ]
            ],
            "serverInfo": [
                "name": "ETOS Built-in Search",
                "version": "1.0.0"
            ]
        ]
    }

    private func toolsListResult() -> [String: Any] {
        [
            "tools": [
                [
                    "name": MCPBuiltInSearchServer.toolID,
                    "description": NSLocalizedString("使用设备网络搜索网页。如果 query 或 url 包含 URL / 域名，会优先抓取该页面标题和摘要，再补充搜索结果。", comment: "Built-in search MCP tool description"),
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": NSLocalizedString("要搜索的关键词或问题。", comment: "Built-in search query parameter description")
                            ],
                            "url": [
                                "type": "string",
                                "description": NSLocalizedString("可选。要直接抓取的网页 URL；提供后会优先作为查询目标。", comment: "Built-in search url parameter description")
                            ],
                            "max_results": [
                                "type": "integer",
                                "description": NSLocalizedString("返回结果数量，范围 1 到 8。", comment: "Built-in search max results parameter description"),
                                "minimum": 1,
                                "maximum": 8
                            ],
                            "timeout_seconds": [
                                "type": "number",
                                "description": NSLocalizedString("整次搜索或网页抓取最多等待的秒数，范围 3 到 30，默认 12。", comment: "Built-in search timeout parameter description"),
                                "minimum": 3,
                                "maximum": 30
                            ]
                        ],
                        "required": [],
                        "additionalProperties": false
                    ]
                ]
            ]
        ]
    }

    private func toolCallResult(from params: [String: Any]?) async -> [String: Any] {
        guard let params,
              let name = params["name"] as? String else {
            return errorToolResult(message: "Missing tool name")
        }
        guard name == MCPBuiltInSearchServer.toolID else {
            return errorToolResult(message: "Unknown built-in search tool: \(name)")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let queryArgument = normalizedTextArgument(arguments["query"])
        let urlArgument = normalizedTextArgument(arguments["url"])
        guard let query = queryArgument ?? urlArgument else {
            return errorToolResult(message: "query or url must be a non-empty string")
        }
        let directURL = urlArgument.flatMap(MCPBuiltInWebSearchClient.urlCandidate(in:))
        if queryArgument == nil, urlArgument != nil, directURL == nil {
            return errorToolResult(message: "url must be a valid http or https URL")
        }

        let maxResults = normalizedMaxResults(from: arguments["max_results"])
        let timeout = normalizedTimeout(from: arguments["timeout_seconds"])
        let structuredContent: [String: Any]
        do {
            structuredContent = try await searchClient.search(
                query: query,
                directURL: directURL,
                maxResults: maxResults,
                timeout: timeout
            )
        } catch {
            return errorToolResult(
                message: String(
                    format: NSLocalizedString("搜索请求失败：%@", comment: "Built-in search request failed"),
                    error.localizedDescription
                ),
                provider: MCPBuiltInWebSearchClient.providerID
            )
        }
        return [
            "content": [
                [
                    "type": "text",
                    "text": prettyPrintedJSON(structuredContent)
                ]
            ],
            "structuredContent": structuredContent,
            "isError": false
        ]
    }

    private func errorToolResult(message: String, provider: String = MCPBuiltInWebSearchClient.providerID) -> [String: Any] {
        let content: [String: Any] = [
            "error": message,
            "provider": provider
        ]
        return [
            "content": [
                [
                    "type": "text",
                    "text": prettyPrintedJSON(content)
                ]
            ],
            "structuredContent": content,
            "isError": true
        ]
    }

    private func normalizedMaxResults(from rawValue: Any?) -> Int {
        let fallback = 5
        let value: Int
        if let rawValue = rawValue as? Int {
            value = rawValue
        } else if let rawValue = rawValue as? NSNumber {
            value = rawValue.intValue
        } else if let rawValue = rawValue as? String,
                  let parsed = Int(rawValue) {
            value = parsed
        } else {
            value = fallback
        }
        return min(max(value, 1), 8)
    }

    private func normalizedTimeout(from rawValue: Any?) -> TimeInterval {
        let fallback = MCPBuiltInWebSearchClient.defaultTotalTimeout
        let value: TimeInterval
        if let rawValue = rawValue as? Double {
            value = rawValue
        } else if let rawValue = rawValue as? Int {
            value = TimeInterval(rawValue)
        } else if let rawValue = rawValue as? NSNumber {
            value = rawValue.doubleValue
        } else if let rawValue = rawValue as? String,
                  let parsed = Double(rawValue) {
            value = parsed
        } else {
            value = fallback
        }
        return min(max(value, 3), 30)
    }

    private func normalizedTextArgument(_ rawValue: Any?) -> String? {
        guard let text = rawValue as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func requestObject(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPClientError.invalidResponse
        }
        return object
    }

    private func successResponse(id: Any, result: [String: Any]) throws -> Data {
        try responseData([
            "jsonrpc": jsonrpcVersion,
            "id": id,
            "result": result
        ])
    }

    private func errorResponse(id: Any, code: Int, message: String) throws -> Data {
        try responseData([
            "jsonrpc": jsonrpcVersion,
            "id": id,
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func responseData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MCPClientError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func prettyPrintedJSON(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "\(object)"
        }
        return text
    }
}

private final class MCPBuiltInWebSearchClient {
    static let providerID = "etos_builtin_web_search"
    static let defaultTotalTimeout: TimeInterval = 12

    private static let searchEndpoint = URL(string: "https://html.duckduckgo.com/html/")!
    private static let maximumHTMLBytes = 512 * 1024
    private static let defaultRequestTimeout: TimeInterval = 8
    private static let minimumRequestTimeout: TimeInterval = 0.5
    private let dataLoader: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = defaultRequestTimeout
        configuration.timeoutIntervalForResource = defaultTotalTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    convenience init() {
        self.init(session: Self.makeDefaultSession())
    }

    init(session: URLSession) {
        self.dataLoader = { request in
            try await session.data(for: request)
        }
    }

    init(dataLoader: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.dataLoader = dataLoader
    }

    func search(query: String, directURL: URL?, maxResults: Int, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var items: [SearchItem] = []
        var seenURLs = Set<String>()

        if let directURL = directURL ?? Self.urlCandidate(in: query),
           let pageItem = try? await fetchPage(
               url: directURL,
               id: "page01",
               deadline: deadline,
               totalTimeout: timeout
           ) {
            items.append(pageItem)
            seenURLs.insert(Self.normalizedURLKey(pageItem.url))
        }

        if items.count < maxResults {
            let searchItems = try await searchDuckDuckGo(
                query: query,
                remainingCount: maxResults - items.count,
                deadline: deadline,
                totalTimeout: timeout
            )
            for item in searchItems {
                let key = Self.normalizedURLKey(item.url)
                guard !seenURLs.contains(key) else { continue }
                items.append(item)
                seenURLs.insert(key)
                if items.count >= maxResults { break }
            }
        }

        let answer: String
        if items.isEmpty {
            answer = String(
                format: NSLocalizedString("搜索完成，但没有找到「%@」的可用网页结果。", comment: "Built-in search no result answer"),
                query
            )
        } else {
            answer = String(
                format: NSLocalizedString("搜索完成，以下是「%@」的真实网页结果。", comment: "Built-in search answer"),
                query
            )
        }

        return [
            "query": query,
            "provider": Self.providerID,
            "answer": answer,
            "timeout_seconds": timeout,
            "items": items.map(\.jsonObject)
        ]
    }

    private func searchDuckDuckGo(
        query: String,
        remainingCount: Int,
        deadline: Date,
        totalTimeout: TimeInterval
    ) async throws -> [SearchItem] {
        guard remainingCount > 0 else { return [] }

        var components = URLComponents(url: Self.searchEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components.url else {
            throw SearchError.invalidURL
        }

        let html = try await fetchHTML(
            url: url,
            deadline: deadline,
            totalTimeout: totalTimeout,
            usesRangeRequest: false
        )
        let parsedItems = Self.parseDuckDuckGoResults(from: html)
        return Array(parsedItems.prefix(remainingCount).enumerated().map { offset, item in
            SearchItem(
                id: String(format: "web%02d", offset + 1),
                title: item.title,
                url: item.url,
                text: item.text,
                source: "duckduckgo_html"
            )
        })
    }

    private func fetchPage(url: URL, id: String, deadline: Date, totalTimeout: TimeInterval) async throws -> SearchItem {
        let html = try await fetchHTML(
            url: url,
            deadline: deadline,
            totalTimeout: totalTimeout,
            usesRangeRequest: true
        )
        let title = Self.htmlTitle(from: html)
            ?? url.host
            ?? NSLocalizedString("网页没有可读取的标题。", comment: "Built-in search page without title")
        let summary = Self.metaDescription(from: html)
            ?? Self.readableTextSummary(from: html)
            ?? NSLocalizedString("网页没有可读取的摘要。", comment: "Built-in search page without description")
        return SearchItem(
            id: id,
            title: title,
            url: url.absoluteString,
            text: summary,
            source: "direct_fetch"
        )
    }

    private func fetchHTML(
        url: URL,
        deadline: Date,
        totalTimeout: TimeInterval,
        usesRangeRequest: Bool
    ) async throws -> String {
        do {
            return try await loadHTML(
                url: url,
                timeout: Self.remainingRequestTimeout(until: deadline, totalTimeout: totalTimeout),
                usesRangeRequest: usesRangeRequest
            )
        } catch SearchError.httpStatus(let statusCode, _) where usesRangeRequest && (statusCode == 400 || statusCode == 416) {
            return try await loadHTML(
                url: url,
                timeout: Self.remainingRequestTimeout(until: deadline, totalTimeout: totalTimeout),
                usesRangeRequest: false
            )
        }
    }

    private func loadHTML(url: URL, timeout: TimeInterval, usesRangeRequest: Bool) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "Accept-Language")
        if usesRangeRequest {
            request.setValue("bytes=0-\(Self.maximumHTMLBytes - 1)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await dataLoader(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SearchError.invalidResponse(url)
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw SearchError.httpStatus(httpResponse.statusCode, url)
        }

        let limitedData = data.count > Self.maximumHTMLBytes
            ? Data(data.prefix(Self.maximumHTMLBytes))
            : data
        return Self.string(fromHTMLData: limitedData)
    }

    private static func remainingRequestTimeout(until deadline: Date, totalTimeout: TimeInterval) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > minimumRequestTimeout else {
            throw SearchError.timedOut(totalTimeout)
        }
        return min(defaultRequestTimeout, remaining)
    }

    private static func string(fromHTMLData data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func urlCandidate(in query: String) -> URL? {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'`()[]{}<>「」『』，,。；;"))
        return query
            .components(separatedBy: separators)
            .compactMap { rawToken -> URL? in
                let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { return nil }
                if token.hasPrefix("https://") || token.hasPrefix("http://") {
                    return URL(string: token)
                }
                guard looksLikeDomain(token) else { return nil }
                return URL(string: "https://\(token)")
            }
            .first
    }

    private static func looksLikeDomain(_ token: String) -> Bool {
        let host = token
            .split(separator: "/", maxSplits: 1)
            .first?
            .split(separator: ":", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        return host.contains(".")
            && !host.hasPrefix(".")
            && !host.hasSuffix(".")
            && host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func parseDuckDuckGoResults(from html: String) -> [ParsedSearchResult] {
        let anchorPattern = #"(?is)<a\b(?=[^>]*class=["'][^"']*(?:result__a|result-link)[^"']*["'])[^>]*href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        let matches = regexMatches(pattern: anchorPattern, in: html)
        return matches.enumerated().compactMap { offset, match in
            guard match.groups.count >= 2,
                  let url = normalizedResultURL(match.groups[0]) else {
                return nil
            }

            let title = cleanedHTMLText(match.groups[1])
            guard !title.isEmpty else { return nil }

            let nextStart = matches.indices.contains(offset + 1) ? matches[offset + 1].range.lowerBound : html.endIndex
            let segment = String(html[match.range.upperBound..<nextStart])
            let snippet = firstSnippet(in: segment)
                ?? hostSummary(from: url)
                ?? url
            return ParsedSearchResult(title: title, url: url, text: snippet)
        }
    }

    private static func firstSnippet(in html: String) -> String? {
        let snippetPattern = #"(?is)<(?:a|div|td|span)\b(?=[^>]*class=["'][^"']*(?:result__snippet|result-snippet)[^"']*["'])[^>]*>(.*?)</(?:a|div|td|span)>"#
        guard let rawSnippet = firstRegexGroup(pattern: snippetPattern, in: html) else { return nil }
        let snippet = cleanedHTMLText(rawSnippet)
        return snippet.isEmpty ? nil : snippet
    }

    private static func normalizedResultURL(_ rawHref: String) -> String? {
        var href = decodeHTMLEntities(rawHref).trimmingCharacters(in: .whitespacesAndNewlines)
        if href.hasPrefix("//") {
            href = "https:\(href)"
        } else if href.hasPrefix("/") {
            href = "https://duckduckgo.com\(href)"
        }
        guard let url = URL(string: href) else { return nil }
        if url.host?.localizedCaseInsensitiveContains("duckduckgo.com") == true,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let decoded = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let decodedURL = URL(string: decoded) {
            return decodedURL.absoluteString
        }
        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        return url.absoluteString
    }

    private static func htmlTitle(from html: String) -> String? {
        guard let rawTitle = firstRegexGroup(pattern: #"(?is)<title[^>]*>(.*?)</title>"#, in: html) else {
            return nil
        }
        let title = cleanedHTMLText(rawTitle)
        return title.isEmpty ? nil : title
    }

    private static func metaDescription(from html: String) -> String? {
        let metaPattern = #"(?is)<meta\b[^>]*>"#
        for match in regexMatches(pattern: metaPattern, in: html) {
            let tag = String(html[match.range])
            let name = attributeValue("name", in: tag) ?? attributeValue("property", in: tag)
            guard name?.lowercased() == "description" || name?.lowercased() == "og:description" else {
                continue
            }
            guard let content = attributeValue("content", in: tag) else { continue }
            let description = cleanedHTMLText(content)
            if !description.isEmpty {
                return description
            }
        }
        return nil
    }

    private static func readableTextSummary(from html: String) -> String? {
        let withoutScripts = replacingRegex(pattern: #"(?is)<script\b[^>]*>.*?</script>|<style\b[^>]*>.*?</style>"#, in: html, with: " ")
        let text = cleanedHTMLText(withoutScripts)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(280))
    }

    private static func attributeValue(_ name: String, in tag: String) -> String? {
        let pattern = #"(?is)\b\#(NSRegularExpression.escapedPattern(for: name))\s*=\s*["']([^"']*)["']"#
        return firstRegexGroup(pattern: pattern, in: tag)
    }

    private static func cleanedHTMLText(_ html: String) -> String {
        let noTags = replacingRegex(pattern: #"(?is)<[^>]+>"#, in: html, with: " ")
        let decoded = decodeHTMLEntities(noTags)
        return decoded
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        let pattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
        for match in matches {
            guard let entityRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range, in: result) else {
                continue
            }
            let rawValue = String(result[entityRange])
            let radix = rawValue.hasPrefix("x") ? 16 : 10
            let scalarText = rawValue.hasPrefix("x") ? String(rawValue.dropFirst()) : rawValue
            guard let value = UInt32(scalarText, radix: radix),
                  let scalar = UnicodeScalar(value) else {
                continue
            }
            result.replaceSubrange(fullRange, with: String(scalar))
        }
        return result
    }

    private static func hostSummary(from urlString: String) -> String? {
        URL(string: urlString)?.host.map {
            String(
                format: NSLocalizedString("来自 %@ 的网页结果。", comment: "Built-in search host fallback snippet"),
                $0
            )
        }
    }

    private static func normalizedURLKey(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString.lowercased() }
        components.fragment = nil
        return (components.url?.absoluteString ?? urlString).lowercased()
    }

    private static func regexMatches(pattern: String, in text: String) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
                guard let groupRange = Range(match.range(at: index), in: text) else { return nil }
                return String(text[groupRange])
            }
            return RegexMatch(range: range, groups: groups)
        }
    }

    private static func firstRegexGroup(pattern: String, in text: String) -> String? {
        regexMatches(pattern: pattern, in: text).first?.groups.first
    }

    private static func replacingRegex(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    private struct SearchItem {
        let id: String
        let title: String
        let url: String
        let text: String
        let source: String

        var jsonObject: [String: Any] {
            [
                "id": id,
                "title": title,
                "url": url,
                "text": text,
                "source": source
            ]
        }
    }

    private struct ParsedSearchResult {
        let title: String
        let url: String
        let text: String
    }

    private struct RegexMatch {
        let range: Range<String.Index>
        let groups: [String]
    }

    private enum SearchError: LocalizedError {
        case invalidURL
        case invalidResponse(URL)
        case httpStatus(Int, URL)
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return NSLocalizedString("无法构造搜索请求 URL。", comment: "Built-in search invalid URL error")
            case .invalidResponse(let url):
                return String(
                    format: NSLocalizedString("搜索响应无效：%@", comment: "Built-in search invalid response error"),
                    url.absoluteString
                )
            case .httpStatus(let statusCode, let url):
                return String(
                    format: NSLocalizedString("搜索请求返回 HTTP %d：%@", comment: "Built-in search HTTP status error"),
                    statusCode,
                    url.absoluteString
                )
            case .timedOut(let timeout):
                return String(
                    format: NSLocalizedString("搜索请求超时（%.1f 秒）。", comment: "Built-in search timeout error"),
                    timeout
                )
            }
        }
    }
}

// ============================================================================
// MCPClient.swift
// ============================================================================
// ETOS LLM Studio
//
// 应用内 MCP 客户端适配层。标准协议交互交给官方 MCP Swift SDK，
// 本类型只负责维持 ETOS 现有模型、缓存和 UI 所需的稳定接口。
// ============================================================================

import Foundation
import Logging
import MCP
import os.log

private let mcpClientLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPClient")

public final class MCPClient {
    private var sdkClient: Client
    private let transport: any Transport
    private weak var notificationDelegate: MCPNotificationDelegate?
    private weak var samplingHandler: MCPSamplingHandler?
    private weak var elicitationHandler: MCPElicitationHandler?

    public private(set) var negotiatedProtocolVersion: String?

    public init(
        transport: any Transport,
        notificationDelegate: MCPNotificationDelegate? = nil,
        samplingHandler: MCPSamplingHandler? = nil,
        elicitationHandler: MCPElicitationHandler? = nil,
        clientInfo: MCPClientInfo = .appDefault,
        capabilities: MCPClientCapabilities = .standard
    ) {
        self.transport = transport
        self.notificationDelegate = notificationDelegate
        self.samplingHandler = samplingHandler
        self.elicitationHandler = elicitationHandler
        self.sdkClient = Client(
            name: clientInfo.name,
            version: clientInfo.version,
            capabilities: MCPSDKBridge.clientCapabilities(from: capabilities),
            configuration: .default
        )
    }

    public convenience init(transport: MCPTransport) {
        self.init(transport: MCPTransportAdapter(transport: transport))
    }

    // MARK: - 生命周期

    public func initialize(
        protocolVersion: String = MCPProtocolVersion.current,
        clientInfo: MCPClientInfo = .appDefault,
        capabilities: MCPClientCapabilities = .standard
    ) async throws -> MCPServerInfo {
        sdkClient = Client(
            name: clientInfo.name,
            version: clientInfo.version,
            capabilities: MCPSDKBridge.clientCapabilities(from: capabilities),
            configuration: .default
        )
        await configureClientHandlers(capabilities: capabilities)
        do {
            let result = try await sdkClient.connect(transport: transport)
            let resolvedProtocolVersion = result.protocolVersion
            guard MCPProtocolVersion.isSupported(resolvedProtocolVersion) else {
                throw MCPClientError.unsupportedProtocolVersion(resolvedProtocolVersion)
            }
            negotiatedProtocolVersion = resolvedProtocolVersion
            return MCPSDKBridge.serverInfo(from: result)
        } catch let error as MCPClientError {
            throw error
        } catch {
            throw mapSDKError(error)
        }
    }

    public func disconnect() async {
        await sdkClient.disconnect()
    }

    // MARK: - 能力查询

    public func listTools() async throws -> [MCPToolDescription] {
        try await collectPaginatedItems { cursor in
            let page = try await sdkClient.listTools(cursor: cursor)
            return (page.tools.map(MCPSDKBridge.toolDescription), page.nextCursor)
        }
    }

    public func listResources() async throws -> [MCPResourceDescription] {
        try await collectPaginatedItems { cursor in
            let page = try await sdkClient.listResources(cursor: cursor)
            return (page.resources.map(MCPSDKBridge.resourceDescription), page.nextCursor)
        }
    }

    public func listResourceTemplates() async throws -> [MCPResourceTemplate] {
        try await collectPaginatedItems { cursor in
            let page = try await sdkClient.listResourceTemplates(cursor: cursor)
            return (page.templates.map(MCPSDKBridge.resourceTemplate), page.nextCursor)
        }
    }

    public func listPrompts() async throws -> [MCPPromptDescription] {
        try await collectPaginatedItems { cursor in
            let page = try await sdkClient.listPrompts(cursor: cursor)
            return (page.prompts.map(MCPSDKBridge.promptDescription), page.nextCursor)
        }
    }

    public func listRoots() async throws -> [MCPRoot] {
        do {
            let context = try await sdkClient.send(ListRoots.request())
            let result = try await context.value
            return result.roots.map(MCPSDKBridge.root)
        } catch {
            throw mapSDKError(error)
        }
    }

    // MARK: - 调用

    public func executeTool(
        toolId: String,
        inputs: [String: JSONValue],
        options: MCPToolCallOptions = MCPToolCallOptions()
    ) async throws -> JSONValue {
        var metadata = Metadata(progressToken: MCPSDKBridge.progressToken(from: options.progressToken))
        if options.includeTimeoutInMeta, let timeout = options.timeout, timeout > 0 {
            metadata.fields["timeout"] = .int(Int((timeout * 1000).rounded()))
        }
        let hasMetadata = !metadata.fields.isEmpty
        let request = CallTool.request(
            .init(
                name: toolId,
                arguments: inputs.mapValues(MCPSDKBridge.value),
                meta: hasMetadata ? metadata : nil
            )
        )
        let context: RequestContext<CallTool.Result>
        do {
            context = try await sdkClient.send(request)
        } catch {
            throw mapSDKError(error)
        }

        return try await withTaskCancellationHandler {
            do {
                let result = try await waitForToolResult(
                    context: context,
                    method: CallTool.name,
                    timeout: options.timeout
                )
                return try MCPSDKBridge.jsonValue(fromToolResult: result)
            } catch {
                throw mapSDKError(error)
            }
        } onCancel: {
            Task {
                try? await sdkClient.cancelRequest(
                    context.requestID,
                    reason: options.cancellationReason ?? "客户端已取消请求"
                )
            }
        }
    }

    public func readResource(resourceId: String, query: [String: JSONValue]?) async throws -> JSONValue {
        do {
            if let query, !query.isEmpty {
                let request = ReadResourceWithArguments.request(
                    .init(
                        uri: resourceId,
                        arguments: query.mapValues(MCPSDKBridge.value)
                    )
                )
                let context = try await sdkClient.send(request)
                return try MCPSDKBridge.jsonValue(fromToolResult: try await context.value)
            } else {
                let contents = try await sdkClient.readResource(uri: resourceId)
                return try MCPSDKBridge.jsonValue(fromToolResult: ReadResource.Result(contents: contents))
            }
        } catch {
            throw mapSDKError(error)
        }
    }

    public func getPrompt(name: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        do {
            let result = try await sdkClient.getPrompt(name: name, arguments: arguments)
            return MCPSDKBridge.promptResult(description: result.description, messages: result.messages)
        } catch {
            throw mapSDKError(error)
        }
    }

    public func complete(
        reference: MCPCompletionReference,
        argument: MCPCompletionArgument,
        context: MCPCompletionContext? = nil,
        options: MCPCompletionOptions = MCPCompletionOptions()
    ) async throws -> MCPCompletion {
        do {
            let metadata = Metadata(progressToken: MCPSDKBridge.progressToken(from: options.progressToken))
            let request = CompleteWithMetadata.request(
                .init(
                    ref: MCPSDKBridge.completionReference(from: reference),
                    argument: .init(name: argument.name, value: argument.value),
                    context: context?.arguments.map { .init(arguments: $0) },
                    meta: metadata.fields.isEmpty ? nil : metadata
                )
            )
            let context = try await sdkClient.send(request)
            let result = try await context.value.completion
            return MCPCompletion(values: result.values, total: result.total, hasMore: result.hasMore)
        } catch {
            throw mapSDKError(error)
        }
    }

    public func setLogLevel(_ level: MCPLogLevel) async throws {
        do {
            try await sdkClient.setLoggingLevel(MCPSDKBridge.logLevel(from: level))
        } catch {
            throw mapSDKError(error)
        }
    }
}

private enum ReadResourceWithArguments: MCP.Method {
    static let name = ReadResource.name

    struct Parameters: Hashable, Codable, Sendable {
        let uri: String
        let arguments: [String: Value]?
    }

    typealias Result = ReadResource.Result
}

private enum CompleteWithMetadata: MCP.Method {
    static let name = Complete.name

    struct Parameters: Hashable, Codable, Sendable {
        let ref: CompletionReference
        let argument: Complete.Parameters.Argument
        let context: Complete.Parameters.Context?
        let _meta: Metadata?

        init(
            ref: CompletionReference,
            argument: Complete.Parameters.Argument,
            context: Complete.Parameters.Context?,
            meta: Metadata?
        ) {
            self.ref = ref
            self.argument = argument
            self.context = context
            self._meta = meta
        }
    }

    typealias Result = Complete.Result
}

private actor MCPTransportAdapter: Transport {
    private let wrapped: MCPTransport
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    nonisolated let logger = Logging.Logger(label: "etos.mcp.transport.adapter")

    init(transport: MCPTransport) {
        self.wrapped = transport
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        if isNotification(data) {
            try await wrapped.sendNotification(data)
            return
        }
        Task {
            do {
                let response = try await wrapped.sendMessage(data)
                continuation.yield(response)
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    private func isNotification(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["method"] != nil && object["id"] == nil
    }
}

// MARK: - 处理器

private extension MCPClient {
    func configureClientHandlers(capabilities: MCPClientCapabilities) async {
        await sdkClient.onNotification(ToolListChangedNotification.self) { [weak self] _ in
            self?.relayNotification(.toolsListChanged)
        }
        await sdkClient.onNotification(ResourceListChangedNotification.self) { [weak self] _ in
            self?.relayNotification(.resourcesListChanged)
        }
        await sdkClient.onNotification(ResourceUpdatedNotification.self) { [weak self] message in
            let params = JSONValue.dictionary(["uri": .string(message.params.uri)])
            self?.relayNotification(.resourceUpdated, params: params)
        }
        await sdkClient.onNotification(PromptListChangedNotification.self) { [weak self] _ in
            self?.relayNotification(.promptsListChanged)
        }
        await sdkClient.onNotification(ProgressNotification.self) { [weak self] message in
            let progress = MCPSDKBridge.progressParams(from: message.params)
            guard let delegate = self?.notificationDelegate else { return }
            await MainActor.run {
                delegate.didReceiveProgress(progress)
            }
        }
        await sdkClient.onNotification(LogMessageNotification.self) { [weak self] message in
            let entry = MCPSDKBridge.logEntry(from: message.params)
            guard let delegate = self?.notificationDelegate else { return }
            await MainActor.run {
                delegate.didReceiveLogMessage(entry)
            }
        }
        await sdkClient.onNotification(CancelledNotification.self) { [weak self] message in
            let params: JSONValue?
            if let requestId = message.params.requestId {
                params = .dictionary([
                    "requestId": self?.jsonValue(from: requestId) ?? .null,
                    "reason": message.params.reason.map(JSONValue.string) ?? .null
                ])
            } else {
                params = message.params.reason.map { .dictionary(["reason": .string($0)]) }
            }
            self?.relayNotification(.cancelled, params: params)
        }
        await sdkClient.onNotification(ElicitationCompleteNotification.self) { [weak self] message in
            self?.relayNotification(
                .elicitationComplete,
                params: .dictionary(["elicitationId": .string(message.params.elicitationId)])
            )
        }

        if capabilities.sampling != nil {
            await sdkClient.withSamplingHandler { [weak self] params in
                guard let self, let samplingHandler = self.samplingHandler else {
                    throw MCPError.internalError("客户端未启用 Sampling 能力")
                }
                let request = MCPSDKBridge.samplingRequest(from: params)
                let response = try await samplingHandler.handleSamplingRequest(request)
                return MCPSDKBridge.samplingResult(from: response)
            }
        }

        if capabilities.elicitation != nil {
            await sdkClient.withElicitationHandler { [weak self] params in
                guard let self, let elicitationHandler = self.elicitationHandler else {
                    return CreateElicitation.Result(action: .decline)
                }
                let request = MCPSDKBridge.elicitationRequest(from: params)
                let response = try await elicitationHandler.handleElicitationRequest(request)
                return MCPSDKBridge.elicitationResult(from: response)
            }
        }
    }

    func relayNotification(_ type: MCPNotificationType, params: JSONValue? = nil) {
        let notification = MCPSDKBridge.notification(method: type.rawValue, params: params)
        Task { @MainActor [weak self] in
            self?.notificationDelegate?.didReceiveNotification(notification)
        }
    }

    func waitForToolResult(
        context: RequestContext<CallTool.Result>,
        method: String,
        timeout: TimeInterval?
    ) async throws -> CallTool.Result {
        guard let timeout, timeout > 0 else {
            return try await context.value
        }
        return try await withThrowingTaskGroup(of: CallTool.Result.self) { group in
            group.addTask {
                try await context.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MCPClientError.requestTimedOut(method: method, timeout: timeout)
            }
            do {
                guard let first = try await group.next() else {
                    throw MCPClientError.invalidResponse
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func collectPaginatedItems<Item>(
        fetch: (String?) async throws -> (items: [Item], nextCursor: String?)
    ) async throws -> [Item] {
        var items: [Item] = []
        var cursor: String?
        var seenCursors = Set<String>()
        while true {
            let page: (items: [Item], nextCursor: String?)
            do {
                page = try await fetch(cursor)
            } catch {
                throw mapSDKError(error)
            }
            items.append(contentsOf: page.items)
            guard let rawCursor = page.nextCursor else { break }
            let nextCursor = rawCursor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nextCursor.isEmpty else { break }
            guard !seenCursors.contains(nextCursor) else {
                mcpClientLogger.error("MCP 分页游标出现循环：cursor=\(nextCursor, privacy: .public)")
                break
            }
            seenCursors.insert(nextCursor)
            cursor = nextCursor
        }
        return items
    }

    func mapSDKError(_ error: Error) -> Error {
        if let error = error as? MCPClientError {
            return error
        }
        if let error = error as? MCPError {
            return MCPClientError.rpcError(
                JSONRPCError(
                    code: error.code,
                    message: error.errorDescription ?? error.localizedDescription,
                    data: nil
                )
            )
        }
        return error
    }

    func jsonValue(from id: ID) -> JSONValue {
        switch id {
        case .string(let value):
            return .string(value)
        case .number(let value):
            return .int(value)
        }
    }
}

public struct MCPToolCallOptions: Sendable {
    public var timeout: TimeInterval?
    public var progressToken: MCPProgressToken?
    public var cancellationReason: String?
    public var includeTimeoutInMeta: Bool

    public init(
        timeout: TimeInterval? = nil,
        progressToken: MCPProgressToken? = nil,
        cancellationReason: String? = nil,
        includeTimeoutInMeta: Bool = true
    ) {
        self.timeout = timeout
        self.progressToken = progressToken
        self.cancellationReason = cancellationReason
        self.includeTimeoutInMeta = includeTimeoutInMeta
    }

    public init(
        timeout: TimeInterval? = nil,
        progressToken: String?,
        cancellationReason: String? = nil,
        includeTimeoutInMeta: Bool = true
    ) {
        self.init(
            timeout: timeout,
            progressToken: progressToken.map(MCPProgressToken.string),
            cancellationReason: cancellationReason,
            includeTimeoutInMeta: includeTimeoutInMeta
        )
    }

    public init(
        timeout: TimeInterval? = nil,
        progressToken: Int?,
        cancellationReason: String? = nil,
        includeTimeoutInMeta: Bool = true
    ) {
        self.init(
            timeout: timeout,
            progressToken: progressToken.map(MCPProgressToken.int),
            cancellationReason: cancellationReason,
            includeTimeoutInMeta: includeTimeoutInMeta
        )
    }
}

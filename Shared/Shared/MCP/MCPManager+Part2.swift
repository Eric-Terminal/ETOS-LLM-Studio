import Foundation
import Combine
import GRDB
import os.log
#if canImport(UserNotifications)
import UserNotifications
#endif

extension MCPManager {
    public func readResource(on serverID: UUID, resourceId: String, query: [String: JSONValue]?) {
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)
        appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试读取资源：\(resourceId)")

        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                let result = try await client.readResource(resourceId: resourceId, query: query)
                self.lastOperationOutput = result.prettyPrinted()
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试资源读取成功：\(resourceId)")
            } catch {
                self.lastOperationError = error.localizedDescription
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .error, category: .toolCall, serverID: serverID, message: "调试资源读取失败：\(resourceId)，错误=\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Prompts

    public func getPrompt(on serverID: UUID, name: String, arguments: [String: String]?) {
        lastOperationError = nil
        lastOperationOutput = nil
        setDebugBusy(true)
        appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试获取提示词：\(name)")

        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                let result = try await client.getPrompt(name: name, arguments: arguments)
                self.lastOperationOutput = self.formatPromptResult(result)
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .info, category: .toolCall, serverID: serverID, message: "调试提示词获取成功：\(name)")
            } catch {
                self.lastOperationError = error.localizedDescription
                self.setDebugBusy(false)
                self.appendGovernanceLog(level: .error, category: .toolCall, serverID: serverID, message: "调试提示词获取失败：\(name)，错误=\(error.localizedDescription)")
            }
        }
    }

    public func getPromptFromChat(promptName: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        guard let routed = routedPrompts[promptName] else {
            throw MCPChatBridgeError.unknownPrompt
        }
        let client = try await ensureClientReady(serverID: routed.server.id, refreshMetadataIfCacheMissing: false)
        return try await client.getPrompt(name: routed.prompt.name, arguments: arguments)
    }

    func formatPromptResult(_ result: MCPGetPromptResult) -> String {
        var output = ""
        if let desc = result.description {
            output += "描述：\(desc)\n\n"
        }
        output += "消息：\n"
        for (index, message) in result.messages.enumerated() {
            output += "[\(index + 1)] \(message.role):\n"
            switch message.content {
            case .text(let text):
                output += text
            case .image(let data, let mimeType):
                output += "[图片: \(mimeType), \(data.count) bytes]"
            case .resource(let uri, let mimeType, let text):
                output += "[资源: \(uri)"
                if let mimeType { output += ", \(mimeType)" }
                if let text { output += "]\n\(text)" } else { output += "]" }
            }
            output += "\n\n"
        }
        return output
    }

    // MARK: - Logging

    public func setLogLevel(on serverID: UUID, level: MCPLogLevel) {
        Task {
            do {
                let client = try await self.ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
                try await client.setLogLevel(level)
                self.updateStatus(for: serverID) {
                    $0.logLevel = level
                }
                self.appendGovernanceLog(level: .info, category: .lifecycle, serverID: serverID, message: "日志级别已更新为 \(level.rawValue)。")
            } catch {
                self.lastOperationError = error.localizedDescription
                self.appendGovernanceLog(level: .error, category: .lifecycle, serverID: serverID, message: "更新日志级别失败：\(error.localizedDescription)")
            }
        }
    }

    public func clearLogEntries() {
        logEntries.removeAll()
    }

    public func clearGovernanceLogEntries() {
        governanceLogEntries.removeAll()
    }

    public func invalidateMetadataCache(for serverID: UUID, reason: String, refreshIfConnected: Bool = true) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        MCPServerStore.saveMetadata(nil, for: serverID)
        updateStatus(for: serverID) {
            $0.tools = []
            $0.resources = []
            $0.resourceTemplates = []
            $0.prompts = []
            $0.roots = []
            $0.metadataCachedAt = nil
        }
        appendGovernanceLog(level: .warning, category: .cache, serverID: serverID, message: "元数据缓存已失效：\(reason)")
        if refreshIfConnected, case .ready = status(for: server).connectionState {
            refreshMetadata(for: server)
        }
    }

    public func invalidateAllMetadataCaches(reason: String, refreshIfConnected: Bool = true) {
        let serverIDs = servers.map(\.id)
        for serverID in serverIDs {
            invalidateMetadataCache(for: serverID, reason: reason, refreshIfConnected: refreshIfConnected)
        }
    }

    // MARK: - Chat Integration

    public func setChatToolsEnabled(_ isEnabled: Bool) {
        guard chatToolsEnabled != isEnabled else { return }
        chatToolsEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: Self.chatToolsEnabledUserDefaultsKey)
        appendGovernanceLog(level: .info, category: .routing, message: "MCP 聊天工具总开关已\(isEnabled ? "开启" : "关闭")。")
    }

    public func chatToolsForLLM() -> [InternalToolDefinition] {
        guard chatToolsEnabled else { return [] }
        let chatTools: [InternalToolDefinition] = tools.compactMap { available -> InternalToolDefinition? in
            if available.server.approvalPolicy(for: available.tool.toolId) == .alwaysDeny {
                return nil
            }
            let description: String
            if let desc = available.tool.description, !desc.isEmpty {
                description = "[\(available.server.displayName)] \(desc)"
            } else {
                let fallback = String(
                    format: NSLocalizedString("MCP 工具 %@", comment: "MCP tool fallback description sent to model"),
                    available.tool.toolId
                )
                description = "[\(available.server.displayName)] \(fallback)"
            }
            let parameters = available.tool.inputSchema ?? .dictionary([
                "type": .string("object"),
                "additionalProperties": .bool(true)
            ])
            return InternalToolDefinition(name: available.internalName, description: ModelPromptLanguage.appendingToolArgumentInstruction(to: description), parameters: parameters, isBlocking: true)
        }
        return chatTools
    }

    public func executeToolFromChat(toolName: String, argumentsJSON: String) async throws -> String {
        guard chatToolsEnabled else {
            throw MCPChatBridgeError.toolGroupDisabled("MCP 工具")
        }
        guard let routed = routedTools[toolName] else {
            throw MCPChatBridgeError.unknownTool
        }
        if routed.server.approvalPolicy(for: routed.tool.toolId) == .alwaysDeny {
            throw MCPChatBridgeError.toolDeniedByPolicy(displayName(for: routed))
        }
        let startedAt = Date()
        appendGovernanceLog(level: .info, category: .toolCall, serverID: routed.server.id, message: "开始执行聊天工具：\(routed.tool.toolId)")
        let inputs = try decodeJSONDictionary(from: argumentsJSON)
        let callID = UUID()
        do {
            let result = try await executeManagedToolCall(
                callID: callID,
                serverID: routed.server.id,
                toolId: routed.tool.toolId,
                inputs: inputs,
                options: defaultManagedToolCallOptions(
                    timeout: defaultChatToolCallTimeout,
                    reason: "聊天工具调用超时"
                )
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            appendGovernanceLog(level: .info, category: .toolCall, serverID: routed.server.id, message: "聊天工具执行成功：\(routed.tool.toolId)，耗时 \(String(format: "%.2f", elapsed)) 秒。")
            return result.prettyPrinted()
        } catch is CancellationError {
            appendGovernanceLog(level: .warning, category: .toolCall, serverID: routed.server.id, message: "聊天工具执行已取消：\(routed.tool.toolId)")
            throw MCPChatBridgeError.toolCancelled(displayName(for: routed))
        } catch {
            appendGovernanceLog(level: .error, category: .toolCall, serverID: routed.server.id, message: "聊天工具执行失败：\(routed.tool.toolId)，错误=\(error.localizedDescription)")
            throw error
        }
    }

    public func internalName(for tool: MCPAvailableTool) -> String {
        tool.internalName
    }

    public func displayLabel(for toolName: String) -> String? {
        guard let routed = routedTools[toolName] else { return nil }
        return "[\(routed.server.displayName)] \(routed.tool.toolId)"
    }

    public func isToolEnabled(serverID: UUID, toolId: String) -> Bool {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return true
        }
        return server.isToolEnabled(toolId)
    }

    public func setToolEnabled(serverID: UUID, toolId: String, isEnabled: Bool) {
        guard var server = servers.first(where: { $0.id == serverID }) else { return }
        server.setToolEnabled(toolId, isEnabled: isEnabled)
        appendGovernanceLog(level: .info, category: .routing, serverID: serverID, message: "工具 \(toolId) 已\(isEnabled ? "启用" : "禁用")。")
        save(server: server)
    }

    public func approvalPolicy(serverID: UUID, toolId: String) -> MCPToolApprovalPolicy {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return .askEveryTime
        }
        return server.approvalPolicy(for: toolId)
    }

    public func approvalPolicy(for toolName: String) -> MCPToolApprovalPolicy? {
        guard chatToolsEnabled else { return .alwaysDeny }
        guard let routed = routedTools[toolName] else { return nil }
        return routed.server.approvalPolicy(for: routed.tool.toolId)
    }

    public func setToolApprovalPolicy(serverID: UUID, toolId: String, policy: MCPToolApprovalPolicy) {
        guard var server = servers.first(where: { $0.id == serverID }) else { return }
        server.setApprovalPolicy(policy, for: toolId)
        appendGovernanceLog(level: .info, category: .routing, serverID: serverID, message: "工具 \(toolId) 审批策略已更新为 \(policy.rawValue)。")
        save(server: server)
    }

    public func currentResumptionToken(for serverID: UUID) async -> String? {
        guard let transport = streamingTransports[serverID] as? MCPResumptionControllableTransport else {
            return nil
        }
        return await transport.currentResumptionToken()
    }

    public func updateResumptionToken(_ token: String?, for serverID: UUID) async {
        guard let transport = streamingTransports[serverID] as? MCPResumptionControllableTransport else {
            return
        }
        await transport.updateResumptionToken(token)
        persistResumptionToken(for: serverID)
    }

    public func terminateRemoteSession(for serverID: UUID) async {
        guard let transport = streamingTransports[serverID] as? MCPResumptionControllableTransport else {
            return
        }
        await transport.terminateSession()
        persistResumptionToken(for: serverID)
    }

    public func connectedServers() -> [MCPServerConfiguration] {
        servers.filter {
            if let status = serverStatuses[$0.id] {
                if case .ready = status.connectionState { return true }
            }
            return false
        }
    }

    public func selectedServers() -> [MCPServerConfiguration] {
        servers.filter {
            guard let status = serverStatuses[$0.id], status.isSelectedForChat else { return false }
            return true
        }
    }

    // MARK: - Private helpers

    func startConfigObservationIfNeeded() {
        guard configObservationCancellable == nil else { return }
        configObservationCancellable = MCPServerStore.observeConfigurationSignature(
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appendGovernanceLog(
                        level: .warning,
                        category: .lifecycle,
                        message: "MCP 配置监听失败，将保留当前状态：\(error.localizedDescription)"
                    )
                }
            },
            onChange: { [weak self] latestSignature in
                Task { @MainActor [weak self] in
                    self?.handleConfigObservationSignature(latestSignature)
                }
            }
        )
        if configObservationCancellable == nil {
            appendGovernanceLog(
                level: .warning,
                category: .lifecycle,
                message: "MCP 配置监听未启用：将仅在应用内触发保存时刷新。"
            )
        }
    }

    func handleConfigObservationSignature(_ latestSignature: String) {
        guard latestSignature != configSnapshotSignature else { return }
        appendGovernanceLog(
            level: .info,
            category: .lifecycle,
            message: "检测到 MCP 配置数据库变化，自动刷新。"
        )
        reloadServers()
    }

    func status(for id: UUID) -> MCPServerStatus {
        serverStatuses[id] ?? MCPServerStatus()
    }

    func isMetadataStale(_ cachedAt: Date?) -> Bool {
        guard let cachedAt else { return true }
        return Date().timeIntervalSince(cachedAt) > metadataCacheTTL
    }

    func displayName(for serverID: UUID?) -> String? {
        guard let serverID else { return nil }
        return servers.first(where: { $0.id == serverID })?.displayName
    }

    func displayName(for routed: RoutedTool) -> String {
        "[\(routed.server.displayName)] \(routed.tool.toolId)"
    }

    func updateStatus(for id: UUID, _ update: (inout MCPServerStatus) -> Void) {
        var statuses = serverStatuses
        var status = statuses[id] ?? MCPServerStatus()
        update(&status)
        statuses[id] = status
        serverStatuses = statuses
        rebuildAggregates()
        updateBusyFlag()
    }

    func rebuildAggregates() {
        var aggregatedTools: [MCPAvailableTool] = []
        var aggregatedResources: [MCPAvailableResource] = []
        var aggregatedResourceTemplates: [MCPAvailableResourceTemplate] = []
        var aggregatedPrompts: [MCPAvailablePrompt] = []
        var newToolRouting: [String: RoutedTool] = [:]
        var newPromptRouting: [String: RoutedPrompt] = [:]

        for server in servers {
            guard let status = serverStatuses[server.id], status.isSelectedForChat else { continue }
            let hasMetadataCache = !status.tools.isEmpty || !status.resources.isEmpty || !status.resourceTemplates.isEmpty || !status.prompts.isEmpty || !status.roots.isEmpty
            switch status.connectionState {
            case .ready:
                break
            case .idle, .connecting, .reconnecting, .failed:
                guard hasMetadataCache, !isMetadataStale(status.metadataCachedAt) else { continue }
            @unknown default:
                continue
            }

            for tool in status.tools {
                guard server.isToolEnabled(tool.toolId) else { continue }
                guard server.approvalPolicy(for: tool.toolId) != .alwaysDeny else { continue }
                let fullName = internalToolName(for: server, tool: tool)
                let shortNameCandidate = shortToolName(for: server, tool: tool)
                let shortName = newToolRouting[shortNameCandidate] == nil ? shortNameCandidate : fullName

                aggregatedTools.append(MCPAvailableTool(server: server, tool: tool, internalName: shortName))
                newToolRouting[shortName] = RoutedTool(internalName: shortName, server: server, tool: tool)

                if shortName != fullName {
                    newToolRouting[fullName] = RoutedTool(internalName: fullName, server: server, tool: tool)
                }
            }

            for resource in status.resources {
                let name = internalResourceName(for: server, resource: resource)
                aggregatedResources.append(MCPAvailableResource(server: server, resource: resource, internalName: name))
            }

            for resourceTemplate in status.resourceTemplates {
                let name = internalResourceTemplateName(for: server, resourceTemplate: resourceTemplate)
                aggregatedResourceTemplates.append(
                    MCPAvailableResourceTemplate(
                        server: server,
                        resourceTemplate: resourceTemplate,
                        internalName: name
                    )
                )
            }

            for prompt in status.prompts {
                let name = internalPromptName(for: server, prompt: prompt)
                aggregatedPrompts.append(MCPAvailablePrompt(server: server, prompt: prompt, internalName: name))
                newPromptRouting[name] = RoutedPrompt(internalName: name, server: server, prompt: prompt)
            }
        }

        tools = aggregatedTools
        resources = aggregatedResources
        resourceTemplates = aggregatedResourceTemplates
        prompts = aggregatedPrompts
        routedTools = newToolRouting
        routedPrompts = newPromptRouting
    }

    func setDebugBusy(_ active: Bool) {
        if active {
            debugBusyCount += 1
        } else {
            debugBusyCount = max(0, debugBusyCount - 1)
        }
        updateBusyFlag()
    }

    func updateBusyFlag() {
        let serverBusy = serverStatuses.values.contains(where: { $0.isBusy })
        let toolCallBusy = !activeToolCalls.isEmpty
        isBusy = serverBusy || debugBusyCount > 0 || toolCallBusy
    }

    func appendGovernanceLog(
        level: MCPLogLevel,
        category: MCPGovernanceLogCategory,
        serverID: UUID? = nil,
        message: String,
        payload: JSONValue? = nil
    ) {
        let entry = MCPGovernanceLogEntry(
            level: level,
            category: category,
            serverID: serverID,
            serverDisplayName: displayName(for: serverID),
            message: message,
            payload: payload
        )
        governanceLogEntries.append(entry)
        if governanceLogEntries.count > governanceLogLimit {
            governanceLogEntries.removeFirst(governanceLogEntries.count - governanceLogLimit)
        }
    }

    func persistSelection(for serverID: UUID, isSelected: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        guard servers[index].isSelectedForChat != isSelected else { return }
        var updatedServer = servers[index]
        updatedServer.isSelectedForChat = isSelected
        var updatedServers = servers
        updatedServers[index] = updatedServer
        servers = updatedServers
        MCPServerStore.save(updatedServer)
        appendGovernanceLog(level: .info, category: .routing, serverID: serverID, message: "聊天路由已\(isSelected ? "加入" : "移除")服务器。")
    }

    func internalToolName(for server: MCPServerConfiguration, tool: MCPToolDescription) -> String {
        "\(Self.toolNamePrefix)\(server.id.uuidString)/\(tool.toolId)"
    }

    func shortToolName(for server: MCPServerConfiguration, tool: MCPToolDescription) -> String {
        let shortID = server.id.uuidString.prefix(8)
        return "\(Self.toolAliasPrefix)\(shortID)_\(tool.toolId)"
    }

    func internalResourceName(for server: MCPServerConfiguration, resource: MCPResourceDescription) -> String {
        "\(Self.resourceNamePrefix)\(server.id.uuidString)/\(resource.resourceId)"
    }

    nonisolated static var resourceTemplateNamePrefix: String { "mcprestpl://" }

    func internalResourceTemplateName(for server: MCPServerConfiguration, resourceTemplate: MCPResourceTemplate) -> String {
        "\(Self.resourceTemplateNamePrefix)\(server.id.uuidString)/\(resourceTemplate.uriTemplate)"
    }

    nonisolated static var promptNamePrefix: String { "mcpprompt://" }

    func internalPromptName(for server: MCPServerConfiguration, prompt: MCPPromptDescription) -> String {
        "\(Self.promptNamePrefix)\(server.id.uuidString)/\(prompt.name)"
    }

    func decodeJSONDictionary(from text: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        let data = Data(trimmed.utf8)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    func defaultManagedToolCallOptions(timeout: TimeInterval, reason: String) -> MCPManagedToolCallOptions {
        MCPManagedToolCallOptions(
            timeout: timeout,
            maxTotalTimeout: timeout,
            resetTimeoutOnProgress: true,
            cancellationReason: reason,
            includeTimeoutInMeta: true
        )
    }

    func executeManagedToolCall(
        callID: UUID,
        serverID: UUID,
        toolId: String,
        inputs: [String: JSONValue],
        options: MCPManagedToolCallOptions
    ) async throws -> JSONValue {
        let client = try await ensureClientReady(serverID: serverID, refreshMetadataIfCacheMissing: false)
        let startedAt = Date()
        let resolvedProgressToken = options.progressToken ?? .string(UUID().uuidString)
        let tokenKey = resolvedProgressToken.canonicalValue
        let serverDisplayName = displayName(for: serverID) ?? serverID.uuidString

        activeToolCalls[callID] = MCPActiveToolCall(
            id: callID,
            serverID: serverID,
            serverDisplayName: serverDisplayName,
            toolId: toolId,
            startedAt: startedAt,
            progressToken: resolvedProgressToken,
            timeout: options.timeout,
            maxTotalTimeout: options.maxTotalTimeout ?? options.timeout.map { $0 * 2 },
            resetTimeoutOnProgress: options.resetTimeoutOnProgress,
            state: .running
        )
        trackedToolCallTokenKeys[callID] = tokenKey
        progressTimestampsByToken[tokenKey] = startedAt
        if let onProgress = options.onProgress {
            trackedToolCallObservers[callID] = onProgress
        }

        let clientOptions = MCPToolCallOptions(
            timeout: nil,
            progressToken: resolvedProgressToken,
            cancellationReason: options.cancellationReason,
            includeTimeoutInMeta: options.includeTimeoutInMeta
        )
        let task = Task<JSONValue, Error> {
            try await client.executeTool(
                toolId: toolId,
                inputs: inputs,
                options: clientOptions
            )
        }
        trackedToolCallTasks[callID] = task
        appendGovernanceLog(
            level: .info,
            category: .toolCall,
            serverID: serverID,
            message: "工具调用已注册：\(toolId)，token=\(tokenKey)"
        )

        do {
            let result = try await awaitManagedToolCallResult(
                task: task,
                callID: callID,
                serverID: serverID,
                toolId: toolId,
                startedAt: startedAt,
                tokenKey: tokenKey,
                options: options
            )
            completeTrackedToolCall(callID: callID, state: .succeeded)
            return result
        } catch is CancellationError {
            completeTrackedToolCall(callID: callID, state: .cancelled(reason: options.cancellationReason))
            throw CancellationError()
        } catch {
            completeTrackedToolCall(callID: callID, state: .failed(reason: error.localizedDescription))
            throw error
        }
    }

    func awaitManagedToolCallResult(
        task: Task<JSONValue, Error>,
        callID: UUID,
        serverID: UUID,
        toolId: String,
        startedAt: Date,
        tokenKey: String,
        options: MCPManagedToolCallOptions
    ) async throws -> JSONValue {
        let idleTimeout = options.timeout
        let maxTotalTimeout = options.maxTotalTimeout ?? idleTimeout.map { $0 * 2 }
        guard idleTimeout != nil || maxTotalTimeout != nil else {
            return try await task.value
        }

        let watchdogNanos = UInt64(toolCallWatchdogInterval * 1_000_000_000)
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await task.value
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: watchdogNanos)
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    let now = Date()
                    if let maxTotalTimeout,
                       now.timeIntervalSince(startedAt) > maxTotalTimeout {
                        await self?.markToolCallCancelling(
                            callID: callID,
                            serverID: serverID,
                            message: "工具调用触发最大超时：\(toolId)"
                        )
                        task.cancel()
                        throw MCPClientError.requestTimedOut(method: "tools/call", timeout: maxTotalTimeout)
                    }
                    if let idleTimeout {
                        let anchor: Date
                        if options.resetTimeoutOnProgress {
                            let latestProgressAt = await self?.latestProgressTimestamp(for: tokenKey)
                            anchor = latestProgressAt ?? startedAt
                        } else {
                            anchor = startedAt
                        }
                        if now.timeIntervalSince(anchor) > idleTimeout {
                            await self?.markToolCallCancelling(
                                callID: callID,
                                serverID: serverID,
                                message: "工具调用触发空闲超时：\(toolId)"
                            )
                            task.cancel()
                            throw MCPClientError.requestTimedOut(method: "tools/call", timeout: idleTimeout)
                        }
                    }
                }
                throw CancellationError()
            }

            do {
                guard let firstResult = try await group.next() else {
                    throw MCPClientError.invalidResponse
                }
                group.cancelAll()
                return firstResult
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func latestProgressTimestamp(for tokenKey: String) -> Date? {
        progressTimestampsByToken[tokenKey]
    }

    func markToolCallCancelling(callID: UUID, serverID: UUID, message: String) {
        if var call = activeToolCalls[callID] {
            call.state = .cancelling
            activeToolCalls[callID] = call
        }
        appendGovernanceLog(
            level: .warning,
            category: .toolCall,
            serverID: serverID,
            message: message
        )
    }

    func completeTrackedToolCall(callID: UUID, state: MCPToolCallState) {
        if var call = activeToolCalls[callID] {
            call.state = state
            activeToolCalls[callID] = call
        }
        trackedToolCallTasks[callID] = nil
        trackedToolCallObservers[callID] = nil
        if let tokenKey = trackedToolCallTokenKeys.removeValue(forKey: callID),
           !trackedToolCallTokenKeys.values.contains(tokenKey) {
            progressTimestampsByToken.removeValue(forKey: tokenKey)
            progressByToken.removeValue(forKey: tokenKey)
        }
        Task { [weak self] in
            guard let self else { return }
            await self.pruneCompletedToolCall(callID: callID)
        }
    }

    func pruneCompletedToolCall(callID: UUID) async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        activeToolCalls.removeValue(forKey: callID)
    }

    func cancelTrackedToolCalls(for serverID: UUID, reason: String) {
        let callIDs = activeToolCalls
            .filter { $0.value.serverID == serverID }
            .map(\.key)
        for callID in callIDs {
            cancelToolCall(callID: callID, reason: reason)
        }
    }

    func persistResumptionToken(for serverID: UUID) {
        guard let transport = streamingTransports[serverID] as? MCPResumptionControllableTransport else {
            return
        }
        Task { [weak self] in
            let token = await transport.currentResumptionToken()
            guard let self else { return }
            self.persistResumptionToken(token, for: serverID)
        }
    }

    func persistResumptionToken(_ token: String?, for serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        var server = servers[index]
        let previous = server.streamResumptionToken
        server.setResumptionToken(token)
        guard previous != server.streamResumptionToken else { return }
        var updatedServers = servers
        updatedServers[index] = server
        servers = updatedServers
        MCPServerStore.save(server)
        appendGovernanceLog(
            level: .info,
            category: .lifecycle,
            serverID: serverID,
            message: "流式重连令牌已更新。"
        )
    }

    func clientCapabilitiesForCurrentHandlers() -> MCPClientCapabilities {
        var capabilities = MCPClientCapabilities(roots: MCPClientRootsCapabilities(listChanged: true))
        if samplingHandler != nil {
            capabilities.sampling = MCPClientSamplingCapabilities()
        }
        if elicitationHandler != nil {
            capabilities.elicitation = MCPClientElicitationCapabilities(
                form: MCPClientElicitationFormCapability(),
                url: MCPClientElicitationURLCapability()
            )
        }
        return capabilities
    }

    func transportLabel(for server: MCPServerConfiguration) -> String {
        switch server.transport {
        case .http:
            return "streamable_http"
        case .httpSSE:
            return "sse"
        case .oauth:
            return "oauth"
        }
    }
}

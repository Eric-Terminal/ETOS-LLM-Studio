// ============================================================================
// MCPManagerSupport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件保存 MCP 管理器跨功能复用的状态辅助、名称构造、
// 日志聚合与工具调用支持方法。
// ============================================================================

import Foundation

extension MCPManager {
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

    func decodeCancelled(from value: JSONValue) throws -> MCPCancelledParams {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(MCPCancelledParams.self, from: data)
    }

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
}

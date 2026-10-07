import Foundation

extension MCPManager {
    /// 独立返回读取结果，避免不同窗口借用 lastOperationOutput 时相互覆盖。
    public func readResourceAsync(on server: MCPServerConfiguration, resourceID: String, query: [String: JSONValue]?) async throws -> JSONValue {
        try validateReadSource(server)
        setDebugBusy(true)
        let usage = beginMacStdioUse(serverID: server.id)
        defer { endMacStdioUse(serverID: server.id, usage: usage); setDebugBusy(false) }
        let client = try await ensureClientReady(serverID: server.id)
        try validateReadSource(server)
        let result = try await client.readResource(resourceId: resourceID, query: query)
        try validateReadSource(server)
        return result
    }

    public func getPromptAsync(on server: MCPServerConfiguration, name: String, arguments: [String: String]?) async throws -> MCPGetPromptResult {
        try validateReadSource(server)
        setDebugBusy(true)
        let usage = beginMacStdioUse(serverID: server.id)
        defer { endMacStdioUse(serverID: server.id, usage: usage); setDebugBusy(false) }
        let client = try await ensureClientReady(serverID: server.id)
        try validateReadSource(server)
        let result = try await client.getPrompt(name: name, arguments: arguments)
        try validateReadSource(server)
        return result
    }

    private func validateReadSource(_ server: MCPServerConfiguration) throws {
        try Task.checkCancellation()
        guard !isRestoringDatabase else { throw CancellationError() }
        guard servers.first(where: { $0.id == server.id }) == server else { throw MCPConfigurationWriteError.changedExternally }
    }
}

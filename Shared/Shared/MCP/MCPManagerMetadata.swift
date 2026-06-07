// ============================================================================
// MCPManagerMetadata.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 MCP 服务器工具、资源、资源模板和提示词的元数据刷新。
// ============================================================================

import Foundation
import os.log

extension MCPManager {
    public func refreshMetadata() {
        for server in servers {
            refreshMetadata(for: server)
        }
    }

    public func refreshMetadata(for server: MCPServerConfiguration) {
        guard let client = clients[server.id], case .ready = status(for: server).connectionState else {
            return
        }
        mcpManagerLogger.info("刷新 MCP 元数据：\(server.displayName, privacy: .public)")
        appendGovernanceLog(level: .info, category: .cache, serverID: server.id, message: NSLocalizedString("开始刷新元数据。", comment: "MCP governance metadata refresh started"))
        updateStatus(for: server.id) { $0.isBusy = true }
        let currentInfo = status(for: server).info
        Task {
            await refreshMetadata(for: server.id, client: client, serverInfo: currentInfo)
        }
    }

    func refreshMetadata(for serverID: UUID, client: MCPClient, serverInfo: MCPServerInfo?) async {
        do {
            let tools = try await client.listTools()
            let resources = try await listResourcesIfSupported(client: client)
            let resourceTemplates = try await listResourceTemplatesIfSupported(client: client)
            let prompts = try await listPromptsIfSupported(client: client)
            // roots/list 是服务器向客户端发起的请求，不属于可主动拉取的服务器元数据。
            let roots: [MCPRoot] = []
            if let server = servers.first(where: { $0.id == serverID }) {
                mcpManagerLogger.info("MCP 元数据加载完成：\(server.displayName, privacy: .public)，tools=\(tools.count)，resources=\(resources.count)，resourceTemplates=\(resourceTemplates.count)，prompts=\(prompts.count)，roots=\(roots.count)")
            } else {
                mcpManagerLogger.info("MCP 元数据加载完成：server=\(serverID.uuidString, privacy: .public)，tools=\(tools.count)，resources=\(resources.count)，resourceTemplates=\(resourceTemplates.count)，prompts=\(prompts.count)，roots=\(roots.count)")
            }

            let resolvedInfo: MCPServerInfo?
            if let serverInfo {
                resolvedInfo = serverInfo
            } else {
                resolvedInfo = status(for: serverID).info
            }
            let cache = MCPServerMetadataCache(
                cachedAt: Date(),
                info: resolvedInfo,
                tools: tools,
                resources: resources,
                resourceTemplates: resourceTemplates,
                prompts: prompts,
                roots: roots
            )
            MCPServerStore.saveMetadata(cache, for: serverID)

            updateStatus(for: serverID) {
                $0.tools = tools
                $0.resources = resources
                $0.resourceTemplates = resourceTemplates
                $0.prompts = prompts
                $0.roots = roots
                $0.metadataCachedAt = cache.cachedAt
                $0.isBusy = false
            }
            appendGovernanceLog(
                level: .info,
                category: .cache,
                serverID: serverID,
                message: String(
                    format: NSLocalizedString("元数据刷新成功：tools=%d, resources=%d, prompts=%d", comment: "MCP governance metadata refresh succeeded"),
                    tools.count,
                    resources.count,
                    prompts.count
                )
            )
            persistResumptionToken(for: serverID)
        } catch {
            if let server = servers.first(where: { $0.id == serverID }) {
                mcpManagerLogger.error("MCP 元数据刷新失败：\(server.displayName, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            } else {
                mcpManagerLogger.error("MCP 元数据刷新失败：server=\(serverID.uuidString, privacy: .public)，错误=\(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled || isAutoConnectSuppressed(serverID) {
                updateStatus(for: serverID) {
                    $0.isBusy = false
                }
                appendGovernanceLog(level: .info, category: .cache, serverID: serverID, message: NSLocalizedString("元数据刷新已取消，未安排自动重连。", comment: "MCP governance metadata refresh cancelled"))
                return
            }
            updateStatus(for: serverID) {
                $0.isBusy = false
                $0.connectionState = .failed(reason: error.localizedDescription)
            }
            lastOperationError = error.localizedDescription
            lastOperationOutput = nil
            if isSelectedForAutoConnect(serverID) {
                scheduleAutoConnectRetry(for: serverID, preserveSelection: true)
            }
            appendGovernanceLog(level: .error, category: .cache, serverID: serverID, message: String(format: NSLocalizedString("元数据刷新失败：%@", comment: "MCP governance metadata refresh failed"), error.localizedDescription))
        }
    }

    private func listResourcesIfSupported(client: MCPClient) async throws -> [MCPResourceDescription] {
        do {
            return try await client.listResources()
        } catch let MCPClientError.rpcError(error) where error.code == -32601 {
            return []
        }
    }

    private func listResourceTemplatesIfSupported(client: MCPClient) async throws -> [MCPResourceTemplate] {
        do {
            return try await client.listResourceTemplates()
        } catch let MCPClientError.rpcError(error) where error.code == -32601 {
            return []
        }
    }

    private func listPromptsIfSupported(client: MCPClient) async throws -> [MCPPromptDescription] {
        do {
            return try await client.listPrompts()
        } catch let MCPClientError.rpcError(error) where error.code == -32601 {
            return []
        }
    }

}

// ============================================================================
// MCPServerStore.swift
// ============================================================================
// 管理 MCP Server 配置文件的增删改查。
// ============================================================================

import Foundation
import os.log

private let mcpStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "MCPServerStore")

public struct MCPServerStore {
    
    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    private static var serversDirectory: URL {
        documentsDirectory.appendingPathComponent("MCPServers")
    }
    
    @discardableResult
    public static func setupDirectoryIfNeeded() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: serversDirectory.path) {
            do {
                try fm.createDirectory(at: serversDirectory, withIntermediateDirectories: true)
                mcpStoreLogger.info("MCPServers 目录已创建: \(serversDirectory.path, privacy: .public)")
            } catch {
                mcpStoreLogger.error("创建 MCPServers 目录失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        return serversDirectory
    }
    
    public static func loadServers() -> [MCPServerConfiguration] {
        setupDirectoryIfNeeded()
        let fm = FileManager.default
        var result: [MCPServerConfiguration] = []
        do {
            let files = try fm.contentsOfDirectory(at: serversDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: file)
                    let server = try JSONDecoder().decode(MCPServerConfiguration.self, from: data)
                    result.append(server)
                } catch {
                    mcpStoreLogger.error("解析 MCP Server 文件失败 \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            mcpStoreLogger.error("读取 MCPServers 目录失败: \(error.localizedDescription, privacy: .public)")
        }
        return result.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }
    
    public static func save(_ server: MCPServerConfiguration) {
        setupDirectoryIfNeeded()
        let url = serversDirectory.appendingPathComponent("\(server.id.uuidString).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(server)
            try data.write(to: url, options: [.atomicWrite, .completeFileProtection])
            mcpStoreLogger.info("已保存 MCP Server: \(server.displayName, privacy: .public)")
        } catch {
            mcpStoreLogger.error("保存 MCP Server 失败: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    public static func delete(_ server: MCPServerConfiguration) {
        let fm = FileManager.default
        let url = serversDirectory.appendingPathComponent("\(server.id.uuidString).json")
        do {
            try fm.removeItem(at: url)
            mcpStoreLogger.info("已删除 MCP Server: \(server.displayName, privacy: .public)")
        } catch {
            mcpStoreLogger.error("删除 MCP Server 失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}

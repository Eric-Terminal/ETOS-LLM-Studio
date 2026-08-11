// ============================================================================
// BrowserAgentStorage.swift
// ============================================================================
// ETOS LLM Studio
//
// 浏览器截图和下载写入独立的 Documents/BrowserAgent 会话目录，不依赖 Linux 工作区。
// ============================================================================

import Foundation

enum BrowserAgentStorage {
    static func downloadDirectoryURI(sessionID: UUID) -> String {
        "app://BrowserAgent/\(sessionID.uuidString)/Downloads/"
    }

    static func destinationURL(
        sessionID: UUID,
        directoryName: String,
        proposedFilename: String,
        destinationDirectory: URL? = nil
    ) throws -> URL {
        let directory: URL
        if let destinationDirectory {
            directory = destinationDirectory
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            directory = documents
                .appendingPathComponent("BrowserAgent", isDirectory: true)
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let sanitized = proposedFilename
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let name = sanitized.isEmpty ? UUID().uuidString : sanitized
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    static func appURI(for url: URL) throws -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let rootPath = documents.standardizedFileURL.path
        let resolvedPath = url.standardizedFileURL.path
        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw BrowserAgentError.unsupported(
                NSLocalizedString("浏览器文件不在应用文档目录中。", comment: "Browser Agent file outside Documents")
            )
        }
        let relativePath = String(resolvedPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "app://" + relativePath
    }
}

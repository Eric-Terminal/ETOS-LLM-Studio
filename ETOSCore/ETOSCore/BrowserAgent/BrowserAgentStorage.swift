// ============================================================================
// BrowserAgentStorage.swift
// ============================================================================
// ETOS LLM Studio
//
// 浏览器截图和下载只写入当前会话或调用方明确提供的工作区目录。
// ============================================================================

import Foundation

enum BrowserAgentStorage {
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
}

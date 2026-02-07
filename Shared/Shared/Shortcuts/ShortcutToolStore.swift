// ============================================================================
// ShortcutToolStore.swift
// ============================================================================
// 快捷指令工具持久化
// ============================================================================

import Foundation
import os.log

private let shortcutStoreLogger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ShortcutToolStore")

public struct ShortcutToolStore {

    private struct StoredEnvelope: Codable {
        var schemaVersion: Int
        var tools: [ShortcutToolDefinition]
    }

    public static let currentSchemaVersion = 1

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static var storageDirectory: URL {
        documentsDirectory.appendingPathComponent("ShortcutTools")
    }

    private static var toolsFileURL: URL {
        storageDirectory.appendingPathComponent("tools.json")
    }

    @discardableResult
    public static func setupDirectoryIfNeeded() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: storageDirectory.path) {
            do {
                try fm.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
                shortcutStoreLogger.info("ShortcutTools 目录已创建: \(storageDirectory.path, privacy: .public)")
            } catch {
                shortcutStoreLogger.error("创建 ShortcutTools 目录失败: \(error.localizedDescription, privacy: .public)")
            }
        }
        return storageDirectory
    }

    public static func loadTools() -> [ShortcutToolDefinition] {
        setupDirectoryIfNeeded()
        do {
            let data = try Data(contentsOf: toolsFileURL)
            let decoder = JSONDecoder()
            if let envelope = try? decoder.decode(StoredEnvelope.self, from: data) {
                return envelope.tools
            }
            return try decoder.decode([ShortcutToolDefinition].self, from: data)
        } catch {
            shortcutStoreLogger.info("加载快捷指令工具失败或为空，返回空数组: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public static func saveTools(_ tools: [ShortcutToolDefinition]) {
        setupDirectoryIfNeeded()
        let envelope = StoredEnvelope(schemaVersion: currentSchemaVersion, tools: tools)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: toolsFileURL, options: [.atomicWrite, .completeFileProtection])
            shortcutStoreLogger.info("已保存快捷指令工具: \(tools.count)")
        } catch {
            shortcutStoreLogger.error("保存快捷指令工具失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}

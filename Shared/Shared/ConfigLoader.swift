// ============================================================================
// ConfigLoader.swift
// ============================================================================
// ETOS LLM Studio - Provider 配置加载与管理
//
// 功能特性:
// - 提供商配置优先存储在 SQLite，失败时回退 `Providers` 目录 JSON。
// - App首次启动时，自动从 Bundle 的 `Providers_template` 目录中拷贝模板配置。
// - 提供加载、保存、删除提供商配置的静态方法。
// ============================================================================

import Foundation
import GRDB
import os.log

let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConfigLoader")

public struct ConfigLoader {
    
    // MARK: - 目录管理
    
    struct DownloadOnceFetchResult {
        let didWriteFiles: Bool
        let isComplete: Bool
    }

    struct DownloadOnceEntry: Decodable {
        let path: String
        let url: String
    }
    
    struct DownloadOnceEnvelope: Decodable {
        let downloads: [DownloadOnceEntry]
    }

    enum DownloadFileResult {
        case downloaded
        case alreadyPresent
        case failed
    }

    static let downloadOnceURLString = "https://notify.els.ericterminal.com/download_once.json"
    static let downloadOnceTimeout: TimeInterval = 8
    static let downloadOnceCompletedFlagKey = "com.ETOS.LLM.Studio.download_once.completed"
    static let toolCapabilityMigrationFlagKey = "com.ETOS.LLM.Studio.modelCapability.toolCalling.migrated"
    static let legacyToolCapabilityMigrationFlagKey = "com.ETOS.LLM.Studio.modelCapability.toolCalling.migrated.v1"
    static let providersBlobKey = "providers"
    static let legacyProvidersBlobKeys = [providersBlobKey, "providers_v1"]
    static let downloadOnceStateQueue = DispatchQueue(label: "com.ETOS.LLM.Studio.downloadOnce")
    static var downloadOnceInProgress = false
    static let jsonDecoder = JSONDecoder()
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    static var providersDirectory: URL {
        documentsDirectory.appendingPathComponent("Providers")
    }
}

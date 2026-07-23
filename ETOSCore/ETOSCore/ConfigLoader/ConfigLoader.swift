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

public extension Notification.Name {
    /// 官方数据写入完成后通知运行中的服务刷新对应配置。
    static let officialDataDidUpdate = Notification.Name("com.ETOS.LLM.Studio.officialDataDidUpdate")
}

public struct OfficialDataSyncResult: Sendable {
    public let downloadedCount: Int
    public let totalCount: Int
    public let isComplete: Bool
    public let isAlreadyRunning: Bool

    public var didWriteFiles: Bool {
        downloadedCount > 0
    }
}

public struct ConfigLoader {
    static let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConfigLoader")
    
    // MARK: - 目录管理
    
    struct OfficialDataEntry: Decodable, Sendable {
        let name: String?
        let path: String
        let url: String
        let fileName: String
        let sha256: String
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case path
            case url
            case fileName = "file_name"
            case sha256
            case size
        }
    }
    
    struct OfficialDataManifest: Decodable, Sendable {
        let version: Int
        let downloads: [OfficialDataEntry]
    }

    enum DownloadFileResult {
        case downloaded
        case alreadyPresent
        case failed
    }

    static let officialDataManifestURLString = "https://feedback.els.ericterminal.com/v1/distribution/manifest"
    static let officialDataTimeout: TimeInterval = 30
    static let downloadOnceCompletedFlagKey = "com.ETOS.LLM.Studio.download_once.completed"
    static let toolCapabilityMigrationFlagKey = "com.ETOS.LLM.Studio.modelCapability.toolCalling.migrated"
    static let legacyToolCapabilityMigrationFlagKey = "com.ETOS.LLM.Studio.modelCapability.toolCalling.migrated.v1"
    private static let providersBlobKey = "providers"
    static let legacyProvidersBlobKeys = [providersBlobKey, "providers_v1"]
    static let downloadOnceStateQueue = DispatchQueue(label: "com.ETOS.LLM.Studio.downloadOnce")
    static var downloadOnceInProgress = false

    struct CredentialHydrationResult {
        let apiKeys: [String]
        let shouldRewriteProviderFile: Bool
    }

    struct LegacyProviderLoadResult {
        let providers: [Provider]
        let didScanProviderDirectory: Bool
    }

    static let jsonDecoder = JSONDecoder()
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// 获取用户专属的根目录 URL
    static var documentsDirectory: URL {
        StorageUtility.documentsDirectory
    }
    
    /// 获取存放提供商配置的目录 URL
    static var providersDirectory: URL {
        documentsDirectory.appendingPathComponent("Providers")
    }

    /// 检查并初始化提供商配置目录。
    /// 如果 `Providers` 目录不存在，则创建它。
    public static func setupInitialProviderConfigs() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: providersDirectory.path) else {
            // 目录已存在，无需任何操作。
            return
        }
        
        logger.warning("用户提供商配置目录不存在。正在创建...")
        
        do {
            // 1. 创建 Providers 目录
            try fileManager.createDirectory(at: providersDirectory, withIntermediateDirectories: true, attributes: nil)
            logger.info("  - 成功创建目录: \(providersDirectory.path)")
        } catch {
            logger.error("初始化提供商配置目录失败: \(error.localizedDescription)")
        }
    }
    
}

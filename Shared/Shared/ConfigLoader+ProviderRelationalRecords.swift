import Foundation
import GRDB
import os.log

extension ConfigLoader {
    static func changedFieldsForProviderUpdate(old: Provider?, new: Provider) -> [String] {
        guard let old else { return ["首次保存"] }

        var fields: [String] = []
        if old.name != new.name {
            fields.append("名称")
        }
        if old.baseURL != new.baseURL {
            fields.append("Base URL")
        }
        if old.apiFormat != new.apiFormat {
            fields.append("API 格式")
        }
        if old.models != new.models {
            fields.append("模型列表")
        }
        if old.headerOverrides != new.headerOverrides {
            fields.append("请求头覆写")
        }
        if old.proxyConfiguration != new.proxyConfiguration {
            fields.append("代理配置")
        }
        if old.apiKeys != new.apiKeys {
            fields.append("API Key 列表")
        }

        return fields.isEmpty ? ["无字段变化（覆盖保存）"] : fields
    }

    static func providersShareSamePersistentConfiguration(_ lhs: Provider, _ rhs: Provider) -> Bool {
        lhs.name == rhs.name &&
        lhs.baseURL == rhs.baseURL &&
        lhs.apiFormat == rhs.apiFormat &&
        lhs.models == rhs.models &&
        lhs.headerOverrides == rhs.headerOverrides &&
        lhs.proxyConfiguration == rhs.proxyConfiguration
    }

    static func hydrateProviderCredentials(for provider: Provider) -> CredentialHydrationResult {
        let normalizedFileAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
        let storedAPIKeys = ProviderCredentialStore.shared.loadAPIKeys(for: provider.id)
        let didNormalizeFile = normalizedFileAPIKeys != provider.apiKeys

        if !normalizedFileAPIKeys.isEmpty {
            if !storedAPIKeys.isEmpty {
                _ = ProviderCredentialStore.shared.deleteAPIKeys(for: provider.id)
            }
            return CredentialHydrationResult(
                apiKeys: normalizedFileAPIKeys,
                shouldRewriteProviderFile: didNormalizeFile
            )
        }

        let migratedAPIKeys = ProviderCredentialStore.normalizeAPIKeys(storedAPIKeys)
        let didMigrateFromCredentialStore = !migratedAPIKeys.isEmpty

        if didMigrateFromCredentialStore {
            logger.info("  - 已将提供商 \(provider.name) 的 API Key 从旧凭据存储迁移到主存储。")
        }
        if !storedAPIKeys.isEmpty {
            _ = ProviderCredentialStore.shared.deleteAPIKeys(for: provider.id)
        }

        return CredentialHydrationResult(
            apiKeys: migratedAPIKeys,
            shouldRewriteProviderFile: didNormalizeFile || didMigrateFromCredentialStore
        )
    }

    static func mergeAPIKeysPreservingOrder(_ primary: [String], _ additional: [String]) -> [String] {
        ProviderCredentialStore.normalizeAPIKeys(primary + additional)
    }

    // MARK: - GRDB 关系模型

    struct RelationalProviderRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "providers"

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case baseURL = "base_url"
            case apiFormat = "api_format"
            case proxyIsEnabled = "proxy_is_enabled"
            case proxyType = "proxy_type"
            case proxyHost = "proxy_host"
            case proxyPort = "proxy_port"
            case proxyUsername = "proxy_username"
            case proxyPassword = "proxy_password"
            case updatedAt = "updated_at"
        }

        var id: String
        var name: String
        var baseURL: String
        var apiFormat: String
        var proxyIsEnabled: Int?
        var proxyType: String?
        var proxyHost: String?
        var proxyPort: Int?
        var proxyUsername: String?
        var proxyPassword: String?
        var updatedAt: Double
    }

    struct RelationalProviderAPIKeyRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_api_keys"

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case keyIndex = "key_index"
            case apiKey = "api_key"
        }

        enum Columns {
            static let providerID = Column(CodingKeys.providerID.rawValue)
        }

        var providerID: String
        var keyIndex: Int
        var apiKey: String
    }

    struct RelationalProviderHeaderOverrideRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_header_overrides"

        enum CodingKeys: String, CodingKey {
            case providerID = "provider_id"
            case headerKey = "header_key"
            case headerValue = "header_value"
        }

        enum Columns {
            static let providerID = Column(CodingKeys.providerID.rawValue)
        }

        var providerID: String
        var headerKey: String
        var headerValue: String
    }

    struct RelationalProviderModelRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_models"

        enum CodingKeys: String, CodingKey {
            case id
            case providerID = "provider_id"
            case modelName = "model_name"
            case displayName = "display_name"
            case isActivated = "is_activated"
            case kind
            case inputModalitiesJSON = "input_modalities_json"
            case outputModalitiesJSON = "output_modalities_json"
            case requestBodyOverrideMode = "request_body_override_mode"
            case rawRequestBodyJSON = "raw_request_body_json"
            case sortIndex = "sort_index"
            case updatedAt = "updated_at"
        }

        enum Columns {
            static let providerID = Column(CodingKeys.providerID.rawValue)
        }

        var id: String
        var providerID: String
        var modelName: String
        var displayName: String
        var isActivated: Int
        var kind: String?
        var inputModalitiesJSON: String?
        var outputModalitiesJSON: String?
        var requestBodyOverrideMode: String?
        var rawRequestBodyJSON: String?
        var sortIndex: Int
        var updatedAt: Double
    }

    struct RelationalProviderModelCapabilityRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_model_capabilities"

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case capability
            case sortIndex = "sort_index"
        }

        enum Columns {
            static let modelID = Column(CodingKeys.modelID.rawValue)
        }

        var modelID: String
        var capability: String
        var sortIndex: Int
    }

    struct RelationalProviderModelOverrideParameterRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
        static let databaseTableName = "provider_model_override_parameters"

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case paramKey = "param_key"
            case valueType = "value_type"
            case stringValue = "string_value"
            case numberValue = "number_value"
            case boolValue = "bool_value"
            case jsonValueText = "json_value_text"
        }

        enum Columns {
            static let modelID = Column(CodingKeys.modelID.rawValue)
        }

        var modelID: String
        var paramKey: String
        var valueType: String
        var stringValue: String?
        var numberValue: Double?
        var boolValue: Int?
        var jsonValueText: String?
    }
    
    // MARK: - 背景图片管理

    /// 获取存放背景图片的目录 URL
    public static func getBackgroundsDirectory() -> URL {
        documentsDirectory.appendingPathComponent("Backgrounds")
    }

    /// 检查并初始化背景图片目录。
    /// 如果 `Backgrounds` 目录不存在，则创建它。
    public static func setupBackgroundsDirectory() {
        let backgroundsDirectory = getBackgroundsDirectory()
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: backgroundsDirectory.path) else {
            return
        }
        
        logger.warning("用户背景图片目录不存在。正在创建...")
        
        do {
            try fileManager.createDirectory(at: backgroundsDirectory, withIntermediateDirectories: true, attributes: nil)
            logger.info("  - 成功创建目录: \(backgroundsDirectory.path)")
        } catch {
            logger.error("初始化背景图片目录失败: \(error.localizedDescription)")
        }
    }

    /// 从 `Backgrounds` 目录加载所有图片的文件名。
    /// - Returns: 一个包含所有图片文件名的数组。
    public static func loadBackgroundImages() -> [String] {
        logger.info("正在从 \(getBackgroundsDirectory().path) 加载所有背景图片...")
        let fileManager = FileManager.default
        var imageNames: [String] = []

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: getBackgroundsDirectory(), includingPropertiesForKeys: nil)
            // 支持常见的图片格式
            let supportedExtensions = ["png", "jpg", "jpeg", "webp"]
            for url in fileURLs {
                if supportedExtensions.contains(url.pathExtension.lowercased()) {
                    imageNames.append(url.lastPathComponent)
                }
            }
        } catch {
            logger.error("无法读取 Backgrounds 目录: \(error.localizedDescription)")
        }
        
        logger.info("总共加载了 \(imageNames.count) 个背景图片。")
        return imageNames
    }
    
    // MARK: - Download-once 支持
    
    static func beginDownloadOnce() -> Bool {
        downloadOnceStateQueue.sync {
            if downloadOnceInProgress {
                return false
            }
            downloadOnceInProgress = true
            return true
        }
    }

    static func endDownloadOnce() {
        downloadOnceStateQueue.sync {
            downloadOnceInProgress = false
        }
    }
    
    static func isDownloadOnceCompleted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: downloadOnceCompletedFlagKey)
    }

    static func setDownloadOnceCompleted(_ completed: Bool, defaults: UserDefaults = .standard) {
        defaults.set(completed, forKey: downloadOnceCompletedFlagKey)
    }

    static func isDownloadOnceFileReady(at fileURL: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    static func fetchAndStoreDownloadOnceConfigs(from url: URL) async -> DownloadOnceFetchResult {
        logger.info("正在获取 download_once.json...")
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = downloadOnceTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                logger.error("download_once.json 响应无效")
                return DownloadOnceFetchResult(didWriteFiles: false, isComplete: false)
            }
            
            let entries = parseDownloadOncePayload(data)
            guard !entries.isEmpty else {
                logger.warning("download_once.json 内容为空或格式不受支持")
                return DownloadOnceFetchResult(didWriteFiles: false, isComplete: false)
            }
            
            var didWriteFiles = false
            var allEntriesReady = true
            
            for entry in entries {
                guard let remoteURL = URL(string: entry.url) else {
                    logger.error("下载地址无效: \(entry.url)")
                    allEntriesReady = false
                    continue
                }
                
                guard let destinationDir = resolveDownloadDestination(for: entry.path) else {
                    logger.error("下载路径无效: \(entry.path)")
                    allEntriesReady = false
                    continue
                }
                
                switch await downloadFile(from: remoteURL, to: destinationDir) {
                case .downloaded:
                    didWriteFiles = true
                case .alreadyPresent:
                    break
                case .failed:
                    allEntriesReady = false
                }
            }
            
            return DownloadOnceFetchResult(
                didWriteFiles: didWriteFiles,
                isComplete: allEntriesReady
            )
        } catch {
            logger.error("下载 download_once.json 失败: \(error.localizedDescription)")
            return DownloadOnceFetchResult(didWriteFiles: false, isComplete: false)
        }
    }
    
    static func parseDownloadOncePayload(_ data: Data) -> [DownloadOnceEntry] {
        let decoder = JSONDecoder()
        
        if let envelope = try? decoder.decode(DownloadOnceEnvelope.self, from: data) {
            return envelope.downloads
        }
        
        if let entries = try? decoder.decode([DownloadOnceEntry].self, from: data) {
            return entries
        }
        
        if let mapping = try? decoder.decode([String: String].self, from: data) {
            return mapping.map { DownloadOnceEntry(path: $0.key, url: $0.value) }
        }
        
        return []
    }
    
    static func resolveDownloadDestination(for rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        
        if normalized.hasPrefix("/Documents/") {
            let relativePath = String(normalized.dropFirst("/Documents/".count))
            return documentsDirectory.appendingPathComponent(relativePath)
        }
        
        if normalized == "/Documents" {
            return documentsDirectory
        }
        
        if normalized.hasPrefix("Documents/") {
            let relativePath = String(normalized.dropFirst("Documents/".count))
            return documentsDirectory.appendingPathComponent(relativePath)
        }
        
        if normalized == "Documents" {
            return documentsDirectory
        }
        
        if normalized.hasPrefix("/") {
            return nil
        }
        
        return documentsDirectory.appendingPathComponent(normalized)
    }
    
    static func downloadFile(from remoteURL: URL, to directory: URL) async -> DownloadFileResult {
        let fileName = remoteURL.lastPathComponent
        guard !fileName.isEmpty else {
            logger.error("下载地址缺少文件名: \(remoteURL.absoluteString)")
            return .failed
        }
        
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("创建下载目录失败: \(directory.path) - \(error.localizedDescription)")
            return .failed
        }
        
        let destinationURL = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            if isDownloadOnceFileReady(at: destinationURL, fileManager: fileManager) {
                logger.info("下载文件已存在且有效，跳过: \(destinationURL.lastPathComponent)")
                return .alreadyPresent
            }
            do {
                try fileManager.removeItem(at: destinationURL)
                logger.warning("检测到无效下载文件，已删除并准备重下: \(destinationURL.lastPathComponent)")
            } catch {
                logger.error("清理无效下载文件失败: \(destinationURL.path) - \(error.localizedDescription)")
                return .failed
            }
        }
        
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = downloadOnceTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                logger.error("下载文件响应无效: \(remoteURL.absoluteString)")
                return .failed
            }

            guard !data.isEmpty else {
                logger.error("下载文件返回空数据: \(remoteURL.absoluteString)")
                return .failed
            }
            
            try data.write(to: destinationURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("下载完成: \(destinationURL.lastPathComponent)")
            return .downloaded
        } catch {
            logger.error("下载文件失败: \(remoteURL.absoluteString) - \(error.localizedDescription)")
            return .failed
        }
    }
}

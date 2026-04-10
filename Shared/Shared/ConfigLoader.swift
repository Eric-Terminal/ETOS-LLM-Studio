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
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConfigLoader")

public struct ConfigLoader {
    
    // MARK: - 目录管理
    
    private struct DownloadOnceFetchResult {
        let didWriteFiles: Bool
        let isComplete: Bool
    }

    private struct DownloadOnceEntry: Decodable {
        let path: String
        let url: String
    }
    
    private struct DownloadOnceEnvelope: Decodable {
        let downloads: [DownloadOnceEntry]
    }

    private enum DownloadFileResult {
        case downloaded
        case alreadyPresent
        case failed
    }

    private static let downloadOnceURLString = "https://notify.els.ericterminal.com/download_once.json"
    private static let downloadOnceTimeout: TimeInterval = 8
    private static let downloadOnceCompletedFlagKey = "com.ETOS.LLM.Studio.download_once.completed"
    private static let toolCapabilityMigrationFlagKey = "com.ETOS.LLM.Studio.modelCapability.toolCalling.migrated.v1"
    private static let providersBlobKey = "providers_v1"
    private static let downloadOnceStateQueue = DispatchQueue(label: "com.ETOS.LLM.Studio.downloadOnce")
    private static var downloadOnceInProgress = false

    private struct CredentialHydrationResult {
        let apiKeys: [String]
        let shouldRewriteProviderFile: Bool
    }

    private struct LegacyProviderLoadResult {
        let providers: [Provider]
        let didScanProviderDirectory: Bool
    }

    /// 获取用户专属的根目录 URL
    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    /// 获取存放提供商配置的目录 URL
    private static var providersDirectory: URL {
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
    
    /// 当下载一次任务尚未完成时，从远端拉取下载清单并写入本地。
    /// 失败时仅记录日志，不能影响应用启动。
    public static func fetchDownloadOnceConfigsIfNeeded(onDownload: (() -> Void)? = nil) {
        guard !isDownloadOnceCompleted() else { return }
        guard beginDownloadOnce() else { return }
        guard let url = URL(string: downloadOnceURLString) else {
            logger.error("download_once.json URL 无效: \(downloadOnceURLString)")
            endDownloadOnce()
            return
        }
        
        Task {
            let result = await fetchAndStoreDownloadOnceConfigs(from: url)
            if result.isComplete {
                setDownloadOnceCompleted(true)
            }
            endDownloadOnce()
            
            if result.didWriteFiles {
                await MainActor.run {
                    onDownload?()
                }
            }
        }
    }

    // MARK: - 增删改查操作

    /// 从 `Providers` 目录加载所有提供商的配置。
    /// - Returns: 一个包含所有已加载 `Provider` 对象的数组。
    public static func loadProviders() -> [Provider] {
        let shouldMigrateToolCapability = !UserDefaults.standard.bool(forKey: toolCapabilityMigrationFlagKey)
        if var providers = loadProvidersFromSQLite() {
            if providers.isEmpty {
                let legacyResult = loadProvidersFromLegacyFiles(shouldMigrateToolCapability: shouldMigrateToolCapability)
                if !legacyResult.providers.isEmpty {
                    if saveProvidersToSQLite(legacyResult.providers) {
                        cleanupLegacyProviderFiles()
                    }
                    logger.info("从旧版 JSON 导入 \(legacyResult.providers.count) 个提供商到 SQLite。")
                    return legacyResult.providers
                }
            }

            var didRepair = false
            if shouldMigrateToolCapability {
                for index in providers.indices {
                    if migrateToolCallingCapabilityIfNeeded(for: &providers[index]) {
                        didRepair = true
                    }
                }
                UserDefaults.standard.set(true, forKey: toolCapabilityMigrationFlagKey)
            }

            if didRepair {
                _ = saveProvidersToSQLite(providers)
            }

            logger.info("正在从 SQLite 加载所有提供商，共 \(providers.count) 个。")
            return providers
        }

        logger.info("正在从 \(providersDirectory.path) 加载所有提供商...")
        let legacyResult = loadProvidersFromLegacyFiles(shouldMigrateToolCapability: shouldMigrateToolCapability)
        if shouldMigrateToolCapability, legacyResult.didScanProviderDirectory {
            UserDefaults.standard.set(true, forKey: toolCapabilityMigrationFlagKey)
        }

        if !legacyResult.providers.isEmpty, saveProvidersToSQLite(legacyResult.providers) {
            cleanupLegacyProviderFiles()
            logger.info("提供商配置已迁移到 SQLite。")
        }

        logger.info("总共加载了 \(legacyResult.providers.count) 个提供商。")
        return legacyResult.providers
    }

    private static func loadProvidersFromLegacyFiles(shouldMigrateToolCapability: Bool) -> LegacyProviderLoadResult {
        setupInitialProviderConfigs()
        let fileManager = FileManager.default
        var providers: [Provider] = []
        var seenProviderIndexByID: [UUID: Int] = [:]
        var seenProviderSourceByID: [UUID: URL] = [:]
        var didScanProviderDirectory = false

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: providersDirectory, includingPropertiesForKeys: nil)
            didScanProviderDirectory = true
            for url in fileURLs.filter({ $0.pathExtension == "json" }) {
                do {
                    let data = try Data(contentsOf: url)
                    var provider = try JSONDecoder().decode(Provider.self, from: data)
                    let fileAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
                    var didRepair = false

                    if shouldMigrateToolCapability,
                       migrateToolCallingCapabilityIfNeeded(for: &provider) {
                        didRepair = true
                        logger.info("  - 已为旧模型补齐“工具”能力默认值: \(url.lastPathComponent)")
                    }

                    if deduplicateModelIDs(for: &provider) {
                        didRepair = true
                        logger.warning("  - 检测到重复模型 ID，已自动修复: \(url.lastPathComponent)")
                    }

                    if let existingIndex = seenProviderIndexByID[provider.id] {
                        let existingProvider = providers[existingIndex]
                        let existingSource = seenProviderSourceByID[provider.id]
                        let canonicalURL = canonicalProviderFileURL(for: provider.id)
                        let currentIsCanonical = isSameFileURL(url, canonicalURL)
                        let existingIsCanonical = existingSource.map { isSameFileURL($0, canonicalURL) } ?? false

                        if providersShareSamePersistentConfiguration(existingProvider, provider) {
                            let mergedAPIKeys = mergeAPIKeysPreservingOrder(
                                existingProvider.apiKeys,
                                fileAPIKeys
                            )
                            let didMergeAPIKeys = mergedAPIKeys != existingProvider.apiKeys
                            if didMergeAPIKeys {
                                providers[existingIndex].apiKeys = mergedAPIKeys
                            }

                            if !currentIsCanonical {
                                removeFileIfExists(at: url)
                                logger.warning("  - 发现重复配置并已清理冗余文件: \(url.lastPathComponent)")
                            } else if !existingIsCanonical, let existingSource {
                                removeFileIfExists(at: existingSource)
                                seenProviderSourceByID[provider.id] = url
                                logger.warning("  - 发现重复配置，已保留规范文件并清理旧文件。")
                            }

                            if didMergeAPIKeys {
                                var normalizedProvider = providers[existingIndex]
                                normalizedProvider.apiKeys = mergedAPIKeys
                                persistNormalizedProvider(normalizedProvider, sourceURL: canonicalURL)
                                seenProviderSourceByID[provider.id] = canonicalURL
                            }
                            continue
                        }

                        let oldID = provider.id
                        provider.id = UUID()
                        didRepair = true
                        logger.warning("  - 提供商 ID 冲突，已重建 ID: \(oldID.uuidString) -> \(provider.id.uuidString)")
                    }

                    let hydration = hydrateProviderCredentials(for: provider)
                    provider.apiKeys = hydration.apiKeys
                    providers.append(provider)
                    seenProviderIndexByID[provider.id] = providers.count - 1

                    let canonicalURL = canonicalProviderFileURL(for: provider.id)
                    if didRepair || hydration.shouldRewriteProviderFile || !isSameFileURL(url, canonicalURL) {
                        persistNormalizedProvider(provider, sourceURL: url)
                        seenProviderSourceByID[provider.id] = canonicalURL
                    } else {
                        seenProviderSourceByID[provider.id] = url
                    }

                    logger.info("  - 成功加载: \(url.lastPathComponent)")
                } catch {
                    logger.error("  - 解析文件失败 \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("无法读取 Providers 目录: \(error.localizedDescription)")
        }

        return LegacyProviderLoadResult(providers: providers, didScanProviderDirectory: didScanProviderDirectory)
    }

    // 将提供商配置统一保存到 <provider.id>.json，并在必要时清理旧文件。
    private static func persistNormalizedProvider(_ provider: Provider, sourceURL: URL) {
        persistProviderToFileOnly(provider)
        let canonicalURL = canonicalProviderFileURL(for: provider.id)
        if !isSameFileURL(sourceURL, canonicalURL) {
            removeFileIfExists(at: sourceURL)
        }
    }

    private static func persistProviderToFileOnly(_ provider: Provider) {
        setupInitialProviderConfigs()
        let fileURL = canonicalProviderFileURL(for: provider.id)
        do {
            let normalizedAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
            var persistedProvider = provider
            persistedProvider.apiKeys = normalizedAPIKeys

            try? FileManager.default.removeItem(at: fileURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(persistedProvider)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
        } catch {
            logger.error("写入旧版 Provider 文件失败: \(error.localizedDescription)")
        }
    }

    private static func canonicalProviderFileURL(for providerID: UUID) -> URL {
        providersDirectory.appendingPathComponent("\(providerID.uuidString).json")
    }

    private static func isSameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func removeFileIfExists(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadProvidersFromSQLite() -> [Provider]? {
        guard Persistence.auxiliaryBlobExists(forKey: providersBlobKey) else {
            return nil
        }
        return Persistence.loadAuxiliaryBlob([Provider].self, forKey: providersBlobKey) ?? []
    }

    @discardableResult
    private static func saveProvidersToSQLite(_ providers: [Provider]) -> Bool {
        Persistence.saveAuxiliaryBlob(providers, forKey: providersBlobKey)
    }

    private static func cleanupLegacyProviderFiles() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: providersDirectory.path) else { return }

        do {
            let files = try fileManager.contentsOfDirectory(at: providersDirectory, includingPropertiesForKeys: nil)
            for fileURL in files where fileURL.pathExtension.lowercased() == "json" {
                try? fileManager.removeItem(at: fileURL)
            }
            let remaining = try fileManager.contentsOfDirectory(atPath: providersDirectory.path)
            if remaining.isEmpty {
                try? fileManager.removeItem(at: providersDirectory)
            }
        } catch {
            logger.error("清理旧版 Provider JSON 文件失败: \(error.localizedDescription)")
        }
    }

    /// 返回是否发生了修复。
    private static func deduplicateModelIDs(for provider: inout Provider) -> Bool {
        var seenModelIDs = Set<UUID>()
        var didRepair = false
        for index in provider.models.indices {
            let modelID = provider.models[index].id
            if seenModelIDs.contains(modelID) {
                provider.models[index].id = UUID()
                didRepair = true
            }
            seenModelIDs.insert(provider.models[index].id)
        }
        return didRepair
    }

    /// 旧版本没有“工具”能力开关，需要在首次迁移时补齐默认值（开启）。
    private static func migrateToolCallingCapabilityIfNeeded(for provider: inout Provider) -> Bool {
        let orderedCapabilities: [Model.Capability] = [.chat, .toolCalling, .speechToText, .textToSpeech, .embedding, .imageGeneration]
        var didRepair = false
        for index in provider.models.indices {
            var capabilitySet = Set(provider.models[index].capabilities)
            guard !capabilitySet.contains(.toolCalling) else { continue }
            capabilitySet.insert(.toolCalling)
            provider.models[index].capabilities = orderedCapabilities.filter { capabilitySet.contains($0) }
            didRepair = true
        }
        return didRepair
    }
    
    /// 将单个提供商的配置保存（或更新）到其对应的 JSON 文件。
    /// - Parameter provider: 需要保存的 `Provider` 对象。
    public static func saveProvider(_ provider: Provider) {
        let normalizedAPIKeys = ProviderCredentialStore.normalizeAPIKeys(provider.apiKeys)
        var persistedProvider = provider
        persistedProvider.apiKeys = normalizedAPIKeys

        var providers = loadProviders()
        let previousProvider = providers.first(where: { $0.id == persistedProvider.id })
        if let index = providers.firstIndex(where: { $0.id == persistedProvider.id }) {
            providers[index] = persistedProvider
        } else {
            providers.append(persistedProvider)
        }

        if saveProvidersToSQLite(providers) {
            cleanupLegacyProviderFiles()
            logger.info("已保存提供商 \(persistedProvider.name) 到 SQLite。")
        } else {
            let fileURL = providersDirectory.appendingPathComponent("\(persistedProvider.id.uuidString).json")
            logger.info("正在回退保存提供商 \(persistedProvider.name) 到 \(fileURL.path)")
            persistProviderToFileOnly(persistedProvider)
            logger.info("  - 回退保存成功。")
        }

        let changedFields = changedFieldsForProviderUpdate(old: previousProvider, new: persistedProvider)
        let action = previousProvider == nil ? "新增提供商配置" : "更新提供商配置"
        var payload: [String: String] = [
            "providerID": persistedProvider.id.uuidString,
            "providerName": persistedProvider.name,
            "apiFormat": persistedProvider.apiFormat,
            "baseURL": persistedProvider.baseURL,
            "modelCount": "\(persistedProvider.models.count)",
            "headerCount": "\(persistedProvider.headerOverrides.count)",
            "apiKeyCount": "\(normalizedAPIKeys.count)",
            "changedFields": changedFields.joined(separator: "、")
        ]
        if !persistedProvider.headerOverrides.isEmpty {
            let sortedHeaderKeys = persistedProvider.headerOverrides.keys.sorted().joined(separator: ", ")
            payload["headerKeys"] = sortedHeaderKeys
        }

        AppLog.userOperation(
            category: "配置",
            action: action,
            payload: payload
        )
        AppLog.developer(
            category: "config",
            action: action,
            message: "提供商配置已保存：\(persistedProvider.name)",
            payload: payload
        )
    }
    
    /// 删除指定提供商的配置文件。
    /// - Parameter provider: 需要删除的 `Provider` 对象。
    public static func deleteProvider(_ provider: Provider) {
        var providers = loadProviders()
        providers.removeAll { $0.id == provider.id }

        if saveProvidersToSQLite(providers) {
            cleanupLegacyProviderFiles()
            logger.info("已从 SQLite 删除提供商 \(provider.name)。")
        } else {
            let fileURL = providersDirectory.appendingPathComponent("\(provider.id.uuidString).json")
            logger.info("正在删除提供商 \(provider.name) 的配置文件: \(fileURL.path)")
            removeFileIfExists(at: fileURL)
        }
        _ = ProviderCredentialStore.shared.deleteAPIKeys(for: provider.id)
        logger.info("  - 删除成功。")
        let payload: [String: String] = [
            "providerID": provider.id.uuidString,
            "providerName": provider.name,
            "apiFormat": provider.apiFormat,
            "baseURL": provider.baseURL,
            "modelCount": "\(provider.models.count)"
        ]
        AppLog.userOperation(
            category: "配置",
            action: "删除提供商配置",
            payload: payload
        )
        AppLog.developer(
            category: "config",
            action: "删除提供商配置",
            message: "提供商配置已删除：\(provider.name)",
            payload: payload
        )
    }

    private static func changedFieldsForProviderUpdate(old: Provider?, new: Provider) -> [String] {
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

    private static func providersShareSamePersistentConfiguration(_ lhs: Provider, _ rhs: Provider) -> Bool {
        lhs.name == rhs.name &&
        lhs.baseURL == rhs.baseURL &&
        lhs.apiFormat == rhs.apiFormat &&
        lhs.models == rhs.models &&
        lhs.headerOverrides == rhs.headerOverrides &&
        lhs.proxyConfiguration == rhs.proxyConfiguration
    }

    private static func hydrateProviderCredentials(for provider: Provider) -> CredentialHydrationResult {
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

    private static func mergeAPIKeysPreservingOrder(_ primary: [String], _ additional: [String]) -> [String] {
        ProviderCredentialStore.normalizeAPIKeys(primary + additional)
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
    
    private static func beginDownloadOnce() -> Bool {
        downloadOnceStateQueue.sync {
            if downloadOnceInProgress {
                return false
            }
            downloadOnceInProgress = true
            return true
        }
    }

    private static func endDownloadOnce() {
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

    private static func fetchAndStoreDownloadOnceConfigs(from url: URL) async -> DownloadOnceFetchResult {
        logger.info("正在获取 download_once.json...")
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = downloadOnceTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
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
    
    private static func parseDownloadOncePayload(_ data: Data) -> [DownloadOnceEntry] {
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
    
    private static func resolveDownloadDestination(for rawPath: String) -> URL? {
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
    
    private static func downloadFile(from remoteURL: URL, to directory: URL) async -> DownloadFileResult {
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
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
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

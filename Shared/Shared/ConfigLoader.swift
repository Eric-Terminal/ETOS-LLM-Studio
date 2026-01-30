// ============================================================================
// ConfigLoader.swift
// ============================================================================
// ETOS LLM Studio - Provider 配置加载与管理
//
// 功能特性:
// - 管理用户专属的 `Providers` 目录。
// - App首次启动时，自动从 Bundle 的 `Providers_template` 目录中拷贝模板配置。
// - 提供加载、保存、删除单个提供商配置文件的静态方法。
// ============================================================================

import Foundation
import os.log

private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ConfigLoader")

public struct ConfigLoader {
    
    // MARK: - 目录管理
    
    private struct DownloadOnceEntry: Decodable {
        let path: String
        let url: String
    }
    
    private struct DownloadOnceEnvelope: Decodable {
        let downloads: [DownloadOnceEntry]
    }

    private static let downloadOnceURLString = "https://notify.els.ericterminal.com/download_once.json"
    private static let downloadOnceTimeout: TimeInterval = 8
    private static let downloadOnceStateQueue = DispatchQueue(label: "com.ETOS.LLM.Studio.downloadOnce")
    private static var downloadOnceInProgress = false

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
    
    /// 首次启动且无提供商配置时，从远端拉取下载清单并写入本地。
    /// 失败时仅记录日志，不能影响应用启动。
    public static func fetchDownloadOnceConfigsIfNeeded(onDownload: (() -> Void)? = nil) {
        guard beginDownloadOnce() else { return }
        guard !hasAnyJsonConfigs() else {
            endDownloadOnce()
            return
        }
        guard let url = URL(string: downloadOnceURLString) else {
            logger.error("download_once.json URL 无效: \(downloadOnceURLString)")
            endDownloadOnce()
            return
        }
        
        Task {
            let didDownload = await fetchAndStoreDownloadOnceConfigs(from: url)
            endDownloadOnce()
            
            if didDownload {
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
        logger.info("正在从 \(providersDirectory.path) 加载所有提供商...")
        let fileManager = FileManager.default
        var providers: [Provider] = []

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: providersDirectory, includingPropertiesForKeys: nil)
            for url in fileURLs.filter({ $0.pathExtension == "json" }) {
                do {
                    let data = try Data(contentsOf: url)
                    let provider = try JSONDecoder().decode(Provider.self, from: data)
                    providers.append(provider)
                    logger.info("  - 成功加载: \(url.lastPathComponent)")
                } catch {
                    logger.error("  - 解析文件失败 \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            logger.error("无法读取 Providers 目录: \(error.localizedDescription)")
        }
        
        logger.info("总共加载了 \(providers.count) 个提供商。")
        return providers
    }
    
    /// 将单个提供商的配置保存（或更新）到其对应的 JSON 文件。
    /// - Parameter provider: 需要保存的 `Provider` 对象。
    public static func saveProvider(_ provider: Provider) {
        // 使用 provider 的 ID 作为文件名以确保唯一性
        let fileURL = providersDirectory.appendingPathComponent("\(provider.id.uuidString).json")
        logger.info("正在保存提供商 \(provider.name) 到 \(fileURL.path)")
        
        do {
            // 使用“先删再写”模式，确保能覆盖文件
            try? FileManager.default.removeItem(at: fileURL)
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(provider)
            try data.write(to: fileURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("  - 保存成功。")
        } catch {
            logger.error("  - 保存失败: \(error.localizedDescription)")
        }
    }
    
    /// 删除指定提供商的配置文件。
    /// - Parameter provider: 需要删除的 `Provider` 对象。
    public static func deleteProvider(_ provider: Provider) {
        let fileURL = providersDirectory.appendingPathComponent("\(provider.id.uuidString).json")
        logger.info("正在删除提供商 \(provider.name) 的配置文件: \(fileURL.path)")

        do {
            try FileManager.default.removeItem(at: fileURL)
            logger.info("  - 删除成功。")
        } catch {
            logger.error("  - 删除失败: \(error.localizedDescription)")
        }
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
    
    private static func hasAnyJsonConfigs() -> Bool {
        let fileManager = FileManager.default
        let documentsPath = documentsDirectory.path
        guard fileManager.fileExists(atPath: documentsPath) else { return false }
        
        guard let enumerator = fileManager.enumerator(
            at: documentsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "json" {
                return true
            }
        }
        
        return false
    }

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
    
    private static func fetchAndStoreDownloadOnceConfigs(from url: URL) async -> Bool {
        logger.info("正在获取 download_once.json...")
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = downloadOnceTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                logger.error("download_once.json 响应无效")
                return false
            }
            
            let entries = parseDownloadOncePayload(data)
            guard !entries.isEmpty else {
                logger.warning("download_once.json 内容为空或格式不受支持")
                return false
            }
            
            var didDownload = false
            
            for entry in entries {
                guard let remoteURL = URL(string: entry.url) else {
                    logger.error("下载地址无效: \(entry.url)")
                    continue
                }
                
                guard let destinationDir = resolveDownloadDestination(for: entry.path) else {
                    logger.error("下载路径无效: \(entry.path)")
                    continue
                }
                
                if await downloadFile(from: remoteURL, to: destinationDir) {
                    didDownload = true
                }
            }
            
            return didDownload
        } catch {
            logger.error("下载 download_once.json 失败: \(error.localizedDescription)")
            return false
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
    
    private static func downloadFile(from remoteURL: URL, to directory: URL) async -> Bool {
        let fileName = remoteURL.lastPathComponent
        guard !fileName.isEmpty else {
            logger.error("下载地址缺少文件名: \(remoteURL.absoluteString)")
            return false
        }
        
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("创建下载目录失败: \(directory.path) - \(error.localizedDescription)")
            return false
        }
        
        let destinationURL = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            logger.info("下载文件已存在，跳过: \(destinationURL.lastPathComponent)")
            return false
        }
        
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = downloadOnceTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                logger.error("下载文件响应无效: \(remoteURL.absoluteString)")
                return false
            }
            
            try data.write(to: destinationURL, options: [.atomicWrite, .completeFileProtection])
            logger.info("下载完成: \(destinationURL.lastPathComponent)")
            return true
        } catch {
            logger.error("下载文件失败: \(remoteURL.absoluteString) - \(error.localizedDescription)")
            return false
        }
    }
}

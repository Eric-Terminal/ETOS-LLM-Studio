// ============================================================================
// ConfigLoaderBackgroundsAndDownloadOnce.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责背景图片目录管理与 download_once 远程配置支持。
// ============================================================================

import Foundation
import GRDB
import os.log

extension ConfigLoader {
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

    private static func fetchAndStoreDownloadOnceConfigs(from url: URL) async -> DownloadOnceFetchResult {
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

// ============================================================================
// ConfigLoaderBackgroundsAndDownloadOnce.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责背景图片目录管理与官方数据同步支持。
// ============================================================================

import Foundation
import CryptoKit
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

    public static let supportedBackgroundImageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    public static let supportedBackgroundVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 判断指定文件名是否为可用的视频背景。
    public static func isVideoBackgroundFile(_ fileName: String) -> Bool {
        supportedBackgroundVideoExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    }

    /// 判断指定文件名是否为可用的背景媒体。
    public static func isSupportedBackgroundMediaFile(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return supportedBackgroundImageExtensions.contains(ext) || supportedBackgroundVideoExtensions.contains(ext)
    }

    /// 从 `Backgrounds` 目录加载所有图片和视频背景的文件名。
    /// - Returns: 一个包含所有背景媒体文件名的数组。
    public static func loadBackgroundImages() -> [String] {
        logger.info("正在从 \(getBackgroundsDirectory().path) 加载所有背景媒体...")
        let fileManager = FileManager.default
        var imageNames: [String] = []

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: getBackgroundsDirectory(), includingPropertiesForKeys: nil)
            for url in fileURLs {
                if isSupportedBackgroundMediaFile(url.lastPathComponent) {
                    imageNames.append(url.lastPathComponent)
                }
            }
        } catch {
            logger.error("无法读取 Backgrounds 目录: \(error.localizedDescription)")
        }

        logger.info("总共加载了 \(imageNames.count) 个背景媒体。")
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
        guard defaults === UserDefaults.standard else {
            return defaults.bool(forKey: downloadOnceCompletedFlagKey)
        }
        return AppConfigStore.boolValue(
            for: .configLoaderDownloadOnceCompleted,
            legacyUserDefaultsKey: downloadOnceCompletedFlagKey
        )
    }

    static func setDownloadOnceCompleted(_ completed: Bool, defaults: UserDefaults = .standard) {
        guard defaults === UserDefaults.standard else {
            defaults.set(completed, forKey: downloadOnceCompletedFlagKey)
            return
        }
        _ = AppConfigStore.persistSynchronously(
            .bool(completed),
            for: .configLoaderDownloadOnceCompleted,
            quickSync: false
        )
    }

    public static func fetchDownloadOnceConfigsIfNeeded() {
        guard !isDownloadOnceCompleted() else { return }

        Task {
            _ = await synchronizeOfficialData(overwriteExisting: false)
        }
    }

    /// 从官方服务同步下发数据。手动触发时覆盖同名文件，自动初始化时保留已就绪文件。
    public static func synchronizeOfficialData(
        overwriteExisting: Bool = true
    ) async -> OfficialDataSyncResult {
        guard beginDownloadOnce() else {
            return OfficialDataSyncResult(
                downloadedCount: 0,
                totalCount: 0,
                isComplete: false,
                isAlreadyRunning: true
            )
        }
        defer { endDownloadOnce() }

        guard let url = URL(string: officialDataManifestURLString) else {
            logger.error("官方数据清单 URL 无效: \(officialDataManifestURLString)")
            return OfficialDataSyncResult(
                downloadedCount: 0,
                totalCount: 0,
                isComplete: false,
                isAlreadyRunning: false
            )
        }

        let result = await fetchAndStoreOfficialData(
            from: url,
            overwriteExisting: overwriteExisting
        )
        if result.isComplete {
            setDownloadOnceCompleted(true)
        }
        if result.didWriteFiles {
            await MainActor.run {
                NotificationCenter.default.post(name: .officialDataDidUpdate, object: nil)
            }
        }
        return result
    }

    private static func fetchAndStoreOfficialData(
        from manifestURL: URL,
        overwriteExisting: Bool
    ) async -> OfficialDataSyncResult {
        logger.info("正在获取官方数据清单...")

        do {
            var request = URLRequest(url: manifestURL)
            request.timeoutInterval = officialDataTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                logger.error("官方数据清单响应无效")
                return OfficialDataSyncResult(
                    downloadedCount: 0,
                    totalCount: 0,
                    isComplete: false,
                    isAlreadyRunning: false
                )
            }

            let decodedManifest = await Task.detached(priority: .utility) {
                try? JSONDecoder().decode(OfficialDataManifest.self, from: data)
            }.value
            guard let manifest = decodedManifest,
                  manifest.version == 1 else {
                logger.error("官方数据清单格式或版本不受支持")
                return OfficialDataSyncResult(
                    downloadedCount: 0,
                    totalCount: 0,
                    isComplete: false,
                    isAlreadyRunning: false
                )
            }

            var downloadedCount = 0
            var allEntriesReady = true

            for entry in manifest.downloads {
                guard let remoteURL = URL(string: entry.url, relativeTo: manifestURL)?.absoluteURL,
                      remoteURL.scheme == manifestURL.scheme,
                      remoteURL.host == manifestURL.host else {
                    logger.error("下载地址无效: \(entry.url)")
                    allEntriesReady = false
                    continue
                }

                guard let destinationDir = resolveDownloadDestination(for: entry.path) else {
                    logger.error("下载路径无效: \(entry.path)")
                    allEntriesReady = false
                    continue
                }

                switch await downloadOfficialDataFile(
                    entry,
                    from: remoteURL,
                    to: destinationDir,
                    overwriteExisting: overwriteExisting
                ) {
                case .downloaded:
                    downloadedCount += 1
                case .alreadyPresent:
                    break
                case .failed:
                    allEntriesReady = false
                }
            }

            return OfficialDataSyncResult(
                downloadedCount: downloadedCount,
                totalCount: manifest.downloads.count,
                isComplete: allEntriesReady,
                isAlreadyRunning: false
            )
        } catch {
            logger.error("下载官方数据清单失败: \(error.localizedDescription)")
            return OfficialDataSyncResult(
                downloadedCount: 0,
                totalCount: 0,
                isComplete: false,
                isAlreadyRunning: false
            )
        }
    }

    static func resolveDownloadDestination(for rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        let relativePath: String
        switch normalized {
        case "/Documents", "Documents":
            relativePath = ""
        default:
            if normalized.hasPrefix("/Documents/") {
                relativePath = String(normalized.dropFirst("/Documents/".count))
            } else if normalized.hasPrefix("Documents/") {
                relativePath = String(normalized.dropFirst("Documents/".count))
            } else if normalized.hasPrefix("/") {
                return nil
            } else {
                relativePath = normalized
            }
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) || relativePath.isEmpty else {
            return nil
        }

        let destination = relativePath.isEmpty
            ? documentsDirectory
            : documentsDirectory.appendingPathComponent(relativePath)
        let documentsPath = documentsDirectory.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath == documentsPath ||
              destinationPath.hasPrefix(documentsPath + "/") else {
            return nil
        }
        return destination
    }

    static func officialDataMatches(
        _ data: Data,
        expectedSize: Int64,
        expectedSHA256: String
    ) -> Bool {
        guard expectedSize > 0, Int64(data.count) == expectedSize else { return false }
        let checksum = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return checksum.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    private static func downloadOfficialDataFile(
        _ entry: OfficialDataEntry,
        from remoteURL: URL,
        to directory: URL,
        overwriteExisting: Bool
    ) async -> DownloadFileResult {
        let fileName = entry.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              fileName != ".",
              fileName != "..",
              entry.size > 0,
              entry.sha256.count == 64 else {
            logger.error("官方数据文件信息无效: \(entry.name ?? entry.url)")
            return .failed
        }

        let destinationURL = directory.appendingPathComponent(fileName)
        let existingFileIsReady = await Task.detached(priority: .utility) {
            guard let existingData = try? Data(contentsOf: destinationURL) else {
                return false
            }
            return officialDataMatches(
                existingData,
                expectedSize: entry.size,
                expectedSHA256: entry.sha256
            )
        }.value
        if !overwriteExisting, existingFileIsReady {
            logger.info("官方数据文件已存在且校验通过，跳过: \(destinationURL.lastPathComponent)")
            return .alreadyPresent
        }

        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = officialDataTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                logger.error("下载文件响应无效: \(remoteURL.absoluteString)")
                return .failed
            }

            let downloadedFileIsValid = await Task.detached(priority: .utility) {
                officialDataMatches(
                    data,
                    expectedSize: entry.size,
                    expectedSHA256: entry.sha256
                )
            }.value
            guard downloadedFileIsValid else {
                logger.error("官方数据文件大小或 SHA-256 校验失败: \(remoteURL.absoluteString)")
                return .failed
            }

            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try data.write(to: destinationURL, options: [.atomicWrite, .completeFileProtection])
            }.value
            logger.info("官方数据下载完成: \(destinationURL.lastPathComponent)")
            return .downloaded
        } catch {
            logger.error("下载官方数据失败: \(remoteURL.absoluteString) - \(error.localizedDescription)")
            return .failed
        }
    }
}

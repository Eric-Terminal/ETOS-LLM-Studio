// ============================================================================
// VideoFrameDerivedCache.swift
// ============================================================================
// ETOS LLM Studio
//
// 将视频抽帧结果作为可清理的派生数据缓存，避免后续对话重复解码原视频。
// ============================================================================

import CryptoKit
import Foundation
import os.log

private let videoFrameCacheLogger = Logger(
    subsystem: "com.ETOS.LLM.Studio",
    category: "VideoFrameDerivedCache"
)

actor VideoFrameDerivedCache {
    static let shared = VideoFrameDerivedCache()

    private static let currentAlgorithmVersion = 1
    private static let fingerprintSampleSize = 64 * 1024

    private struct Manifest: Codable, Sendable {
        let algorithmVersion: Int
        let duration: Double
        let frames: [Frame]
    }

    private struct Frame: Codable, Sendable {
        let storedFileName: String
        let mimeType: String
        let timestamp: Double
    }

    private struct MemoryEntry {
        let result: VideoFrameExtractionResult
        let byteCount: Int
        var lastAccess: Date
    }

    private struct DiskEntry {
        let url: URL
        let byteCount: Int64
        let lastAccess: Date
    }

    private let directoryURL: URL
    private let algorithmVersion: Int
    private let maximumDiskUsage: Int64
    private let maximumMemoryUsage: Int
    private var memoryEntries: [String: MemoryEntry] = [:]
    private var memoryUsage = 0
    private var inFlightExtractions: [String: Task<VideoFrameExtractionResult, Error>] = [:]

    init(
        rootDirectory: URL? = nil,
        algorithmVersion: Int = VideoFrameDerivedCache.currentAlgorithmVersion,
        maximumDiskUsage: Int64? = nil,
        maximumMemoryUsage: Int? = nil
    ) {
        let root = rootDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directoryURL = root
            .appendingPathComponent("VideoFrameDerivedCache", isDirectory: true)
            .appendingPathComponent("v\(algorithmVersion)", isDirectory: true)
        self.algorithmVersion = algorithmVersion
#if os(watchOS)
        self.maximumDiskUsage = maximumDiskUsage ?? 96 * 1024 * 1024
        self.maximumMemoryUsage = maximumMemoryUsage ?? 24 * 1024 * 1024
#else
        self.maximumDiskUsage = maximumDiskUsage ?? 512 * 1024 * 1024
        self.maximumMemoryUsage = maximumMemoryUsage ?? 96 * 1024 * 1024
#endif
    }

    func result(
        for attachment: FileAttachment,
        configuration: VideoFrameExtractionConfiguration,
        producer: @escaping @Sendable () async throws -> VideoFrameExtractionResult
    ) async throws -> VideoFrameExtractionResult {
        let cacheKey = Self.cacheKey(
            for: attachment,
            configuration: configuration,
            algorithmVersion: algorithmVersion
        )
        if let cached = memoryEntries[cacheKey] {
            memoryEntries[cacheKey]?.lastAccess = Date()
            videoFrameCacheLogger.debug("复用内存中的视频派生帧: \(attachment.fileName)")
            return Self.normalizedFileNames(in: cached.result, sourceFileName: attachment.fileName)
        }
        if let extraction = inFlightExtractions[cacheKey] {
            return try await extraction.value
        }

        // 把磁盘查询也纳入共享任务，避免并发查询都未命中时重复抽帧。
        let extraction = Task { [self] in
            if let cached = await loadResult(forKey: cacheKey) {
                remember(cached, forKey: cacheKey)
                videoFrameCacheLogger.info("复用磁盘中的视频派生帧: \(attachment.fileName)")
                return Self.normalizedFileNames(
                    in: cached,
                    sourceFileName: attachment.fileName
                )
            }

            let produced = try await producer()
            let result = Self.normalizedFileNames(
                in: produced,
                sourceFileName: attachment.fileName
            )
            remember(result, forKey: cacheKey)
            await persist(result, forKey: cacheKey)
            return result
        }
        inFlightExtractions[cacheKey] = extraction

        do {
            let result = try await extraction.value
            inFlightExtractions.removeValue(forKey: cacheKey)
            return result
        } catch {
            inFlightExtractions.removeValue(forKey: cacheKey)
            throw error
        }
    }

    private func loadResult(forKey key: String) async -> VideoFrameExtractionResult? {
        let entryURL = directoryURL.appendingPathComponent(key, isDirectory: true)
        let expectedVersion = algorithmVersion
        return await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: entryURL.path) else {
                return nil
            }
            do {
                let manifestURL = entryURL.appendingPathComponent("manifest.plist")
                let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
                let manifest = try PropertyListDecoder().decode(Manifest.self, from: manifestData)
                guard manifest.algorithmVersion == expectedVersion,
                      manifest.duration.isFinite,
                      manifest.duration > 0,
                      !manifest.frames.isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let frames = try manifest.frames.enumerated().map { index, frame in
                    guard frame.timestamp.isFinite, frame.timestamp >= 0 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let data = try Data(
                        contentsOf: entryURL.appendingPathComponent(frame.storedFileName),
                        options: .mappedIfSafe
                    )
                    return ExtractedVideoFrame(
                        attachment: ImageAttachment(
                            data: data,
                            mimeType: frame.mimeType,
                            fileName: "cached-video-frame-\(index + 1).jpg"
                        ),
                        timestamp: frame.timestamp
                    )
                }
                try? fileManager.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: entryURL.path
                )
                return VideoFrameExtractionResult(frames: frames, duration: manifest.duration)
            } catch {
                try? fileManager.removeItem(at: entryURL)
                videoFrameCacheLogger.warning("视频派生帧缓存损坏，已丢弃并准备重建。")
                return nil
            }
        }.value
    }

    private func persist(_ result: VideoFrameExtractionResult, forKey key: String) async {
        let cacheDirectory = directoryURL
        let expectedVersion = algorithmVersion
        let diskLimit = maximumDiskUsage
        do {
            try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                try fileManager.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true
                )
                var resourceValues = URLResourceValues()
                resourceValues.isExcludedFromBackup = true
                var mutableCacheDirectory = cacheDirectory
                try? mutableCacheDirectory.setResourceValues(resourceValues)

                let stagingURL = cacheDirectory.appendingPathComponent(
                    ".\(key)-\(UUID().uuidString)",
                    isDirectory: true
                )
                defer { try? fileManager.removeItem(at: stagingURL) }
                try fileManager.createDirectory(
                    at: stagingURL,
                    withIntermediateDirectories: true
                )

                var manifestFrames: [Frame] = []
                manifestFrames.reserveCapacity(result.frames.count)
                for (index, frame) in result.frames.enumerated() {
                    let storedFileName = String(format: "frame-%03d.jpg", index + 1)
                    try frame.attachment.data.write(
                        to: stagingURL.appendingPathComponent(storedFileName),
                        options: [.atomic, .completeFileProtection]
                    )
                    manifestFrames.append(Frame(
                        storedFileName: storedFileName,
                        mimeType: frame.attachment.mimeType,
                        timestamp: frame.timestamp
                    ))
                }

                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let manifestData = try encoder.encode(Manifest(
                    algorithmVersion: expectedVersion,
                    duration: result.duration,
                    frames: manifestFrames
                ))
                try manifestData.write(
                    to: stagingURL.appendingPathComponent("manifest.plist"),
                    options: [.atomic, .completeFileProtection]
                )

                let finalURL = cacheDirectory.appendingPathComponent(key, isDirectory: true)
                if fileManager.fileExists(atPath: finalURL.path) {
                    try fileManager.removeItem(at: finalURL)
                }
                try fileManager.moveItem(at: stagingURL, to: finalURL)
                try Self.trimDiskCache(
                    at: cacheDirectory,
                    byteLimit: diskLimit,
                    preserving: key
                )
            }.value
            videoFrameCacheLogger.info("已保存视频派生帧缓存，共 \(result.frames.count) 帧。")
        } catch {
            // 缓存写入失败不应影响本次已经完成的视频发送。
            videoFrameCacheLogger.warning("保存视频派生帧缓存失败: \(error.localizedDescription)")
        }
    }

    private func remember(_ result: VideoFrameExtractionResult, forKey key: String) {
        let byteCount = result.frames.reduce(0) { $0 + $1.attachment.data.count }
        guard maximumMemoryUsage > 0, byteCount <= maximumMemoryUsage else {
            return
        }
        if let existing = memoryEntries.removeValue(forKey: key) {
            memoryUsage -= existing.byteCount
        }
        memoryEntries[key] = MemoryEntry(
            result: result,
            byteCount: byteCount,
            lastAccess: Date()
        )
        memoryUsage += byteCount

        while memoryUsage > maximumMemoryUsage,
              let oldest = memoryEntries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            memoryUsage -= oldest.value.byteCount
            memoryEntries.removeValue(forKey: oldest.key)
        }
    }

    private static func cacheKey(
        for attachment: FileAttachment,
        configuration: VideoFrameExtractionConfiguration,
        algorithmVersion: Int
    ) -> String {
        var hasher = SHA256()
        let identity = [
            "version=\(algorithmVersion)",
            "name=\(attachment.fileName)",
            "mime=\(attachment.mimeType.lowercased())",
            "bytes=\(attachment.data.count)",
            "mode=\(configuration.mode.rawValue)",
            "fps=\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), configuration.fixedFPS))",
            "maximum=\(configuration.maximumFrameCount)"
        ].joined(separator: "\n")
        hasher.update(data: Data(identity.utf8))

        let sampleSize = min(fingerprintSampleSize, attachment.data.count)
        if sampleSize > 0 {
            hasher.update(data: attachment.data.prefix(sampleSize))
            if attachment.data.count > sampleSize {
                hasher.update(data: attachment.data.suffix(sampleSize))
            }
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func normalizedFileNames(
        in result: VideoFrameExtractionResult,
        sourceFileName: String
    ) -> VideoFrameExtractionResult {
        let baseName = ((sourceFileName as NSString).deletingPathExtension as NSString)
            .lastPathComponent
        let frames = result.frames.enumerated().map { index, frame in
            let totalSeconds = max(0, Int(frame.timestamp.rounded()))
            let timestampLabel = String(
                format: "%02dm%02ds",
                totalSeconds / 60,
                totalSeconds % 60
            )
            return ExtractedVideoFrame(
                attachment: ImageAttachment(
                    data: frame.attachment.data,
                    mimeType: frame.attachment.mimeType,
                    fileName: "\(baseName)_frame_\(String(format: "%03d", index + 1))_\(timestampLabel).jpg"
                ),
                timestamp: frame.timestamp
            )
        }
        return VideoFrameExtractionResult(frames: frames, duration: result.duration)
    }

    private static func trimDiskCache(
        at directoryURL: URL,
        byteLimit: Int64,
        preserving preservedKey: String
    ) throws {
        guard byteLimit > 0 else { return }
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [DiskEntry] = []
        var totalSize: Int64 = 0
        for url in urls {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            )
            guard values.isDirectory == true else { continue }
            let byteCount = directorySize(at: url)
            totalSize += byteCount
            entries.append(DiskEntry(
                url: url,
                byteCount: byteCount,
                lastAccess: values.contentModificationDate ?? .distantPast
            ))
        }

        for entry in entries.sorted(by: { $0.lastAccess < $1.lastAccess })
        where totalSize > byteLimit && entry.url.lastPathComponent != preservedKey {
            try? fileManager.removeItem(at: entry.url)
            totalSize -= entry.byteCount
        }
    }

    private static func directorySize(at directoryURL: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var result: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }
            result += Int64(values.fileSize ?? 0)
        }
        return result
    }
}

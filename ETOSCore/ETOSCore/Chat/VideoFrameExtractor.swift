// ============================================================================
// VideoFrameExtractor.swift
// ============================================================================
// ETOS LLM Studio
//
// 将非原生视频输入转换为按时间排序的图片附件。
// ============================================================================

import Foundation
#if !os(watchOS)
import AVFoundation
import CoreGraphics
import ImageIO
#endif

public struct VideoFrameExtractionConfiguration: Sendable, Equatable {
    public let mode: VideoFrameExtractionMode
    public let fixedFPS: Double
    public let maximumFrameCount: Int

    public init(
        mode: VideoFrameExtractionMode,
        fixedFPS: Double,
        maximumFrameCount: Int
    ) {
        self.mode = mode
        self.fixedFPS = min(max(fixedFPS.isFinite ? fixedFPS : 1, 0.1), 5)
        self.maximumFrameCount = min(max(maximumFrameCount, 4), 120)
    }
}

public struct ExtractedVideoFrame: Sendable {
    public let attachment: ImageAttachment
    public let timestamp: Double

    public init(attachment: ImageAttachment, timestamp: Double) {
        self.attachment = attachment
        self.timestamp = timestamp
    }
}

public struct VideoFrameExtractionResult: Sendable {
    public let frames: [ExtractedVideoFrame]
    public let duration: Double

    public init(frames: [ExtractedVideoFrame], duration: Double) {
        self.frames = frames
        self.duration = duration
    }
}

public enum VideoFrameExtractionError: LocalizedError {
    case unsupportedVideo
    case frameGenerationFailed
    case imageEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedVideo:
            return NSLocalizedString("无法读取视频时长或画面。", comment: "Unsupported video extraction error")
        case .frameGenerationFailed:
            return NSLocalizedString("没有从视频中提取到可用画面。", comment: "Video frame generation failed")
        case .imageEncodingFailed:
            return NSLocalizedString("视频画面编码失败。", comment: "Video frame image encoding failed")
        }
    }
}

public enum VideoAttachmentSupport {
    public static func isVideo(_ attachment: FileAttachment) -> Bool {
        isVideo(fileName: attachment.fileName, mimeType: attachment.mimeType)
    }

    public static func isVideo(fileName: String, mimeType: String? = nil) -> Bool {
        if mimeType?.lowercased().hasPrefix("video/") == true {
            return true
        }
        return videoFileExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    public static func usesNativeInput(for targetModel: RunnableModel) -> Bool {
        targetModel.provider.apiFormat
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "gemini"
            && targetModel.model.supportsNativeVideoInput
    }

    private static let videoFileExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mpeg", "mpg", "avi", "3gp", "3gpp"
    ]
}

public struct VideoFrameExtractor: Sendable {
#if !os(watchOS)
    private struct CandidateFrame {
        let timestamp: Double
        let image: CGImage
        let hash: UInt64
        let brightness: Double
        let sceneScore: Int
    }
#endif

    public init() {}

    public func extractFrames(
        from attachment: FileAttachment,
        configuration: VideoFrameExtractionConfiguration
    ) async throws -> VideoFrameExtractionResult {
        try await VideoFrameDerivedCache.shared.result(
            for: attachment,
            configuration: configuration
        ) {
            try await extractFramesWithoutCache(
                from: attachment,
                configuration: configuration
            )
        }
    }

    private func extractFramesWithoutCache(
        from attachment: FileAttachment,
        configuration: VideoFrameExtractionConfiguration
    ) async throws -> VideoFrameExtractionResult {
#if os(watchOS)
        return try await VideoFrameExtractionRelay.shared.extractFrames(
            from: attachment,
            configuration: configuration
        )
#else
        try await Task.detached(priority: .userInitiated) {
            try await extractFramesLocally(from: attachment, configuration: configuration)
        }.value
#endif
    }

    public static func plannedTimestamps(
        duration: Double,
        configuration: VideoFrameExtractionConfiguration
    ) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        switch configuration.mode {
        case .fixedFPS:
            let requestedCount = max(1, Int(ceil(duration * configuration.fixedFPS)))
            let count = min(requestedCount, configuration.maximumFrameCount)
            guard count > 1 else { return [0] }
            let interval = duration / Double(count)
            return (0..<count).map { min(Double($0) * interval, max(0, duration - 0.001)) }
        case .smart:
            let targetCount = adaptiveSmartFrameCount(
                duration: duration,
                maximumFrameCount: configuration.maximumFrameCount
            )
            let candidateCount = min(max(targetCount * 4, 24), 240)
            guard candidateCount > 1 else { return [0] }
            let interval = duration / Double(candidateCount)
            return (0..<candidateCount).map { min(Double($0) * interval, max(0, duration - 0.001)) }
        }
    }

    public static func adaptiveSmartFrameCount(duration: Double, maximumFrameCount: Int) -> Int {
        let durationLimit: Int
        switch duration {
        case ...30:
            durationLimit = 12
        case ...60:
            durationLimit = 20
        case ...180:
            durationLimit = 30
        case ...600:
            durationLimit = 45
        default:
            durationLimit = 60
        }
        return min(max(maximumFrameCount, 4), durationLimit)
    }

#if !os(watchOS)
    private func extractFramesLocally(
        from attachment: FileAttachment,
        configuration: VideoFrameExtractionConfiguration
    ) async throws -> VideoFrameExtractionResult {
        let fileExtension = normalizedVideoFileExtension(for: attachment)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("etos-video-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try attachment.data.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let asset = AVURLAsset(url: temporaryURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else {
            throw VideoFrameExtractionError.unsupportedVideo
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let timestamps = Self.plannedTimestamps(duration: duration, configuration: configuration)
        var candidates: [CandidateFrame] = []
        candidates.reserveCapacity(timestamps.count)
        var previousHash: UInt64?

        for timestamp in timestamps {
            let requestedTime = CMTime(seconds: timestamp, preferredTimescale: 600)
            guard let generated = try? await generator.image(at: requestedTime),
                  let image = Optional(generated.image),
                  let signature = imageSignature(image) else {
                continue
            }
            let sceneScore = previousHash.map { Self.hammingDistance($0, signature.hash) } ?? 64
            previousHash = signature.hash
            candidates.append(CandidateFrame(
                timestamp: timestamp,
                image: image,
                hash: signature.hash,
                brightness: signature.brightness,
                sceneScore: sceneScore
            ))
        }

        guard !candidates.isEmpty else {
            throw VideoFrameExtractionError.frameGenerationFailed
        }

        let selectedCandidates: [CandidateFrame]
        switch configuration.mode {
        case .fixedFPS:
            selectedCandidates = candidates
        case .smart:
            let targetCount = Self.adaptiveSmartFrameCount(
                duration: duration,
                maximumFrameCount: configuration.maximumFrameCount
            )
            selectedCandidates = selectSmartFrames(candidates, targetCount: targetCount)
        }

        let baseName = ((attachment.fileName as NSString).deletingPathExtension as NSString)
            .lastPathComponent
        let frames = try selectedCandidates.enumerated().map { index, candidate in
            guard let data = jpegData(from: candidate.image) else {
                throw VideoFrameExtractionError.imageEncodingFailed
            }
            let timestampLabel = Self.timestampLabel(candidate.timestamp)
            let fileName = "\(baseName)_frame_\(String(format: "%03d", index + 1))_\(timestampLabel).jpg"
            return ExtractedVideoFrame(
                attachment: ImageAttachment(data: data, mimeType: "image/jpeg", fileName: fileName),
                timestamp: candidate.timestamp
            )
        }
        return VideoFrameExtractionResult(frames: frames, duration: duration)
    }

    private func selectSmartFrames(
        _ candidates: [CandidateFrame],
        targetCount: Int
    ) -> [CandidateFrame] {
        let visible = candidates.filter { $0.brightness >= 10.0 / 255.0 }
        let source = visible.isEmpty ? candidates : visible
        var deduplicated: [CandidateFrame] = []
        for candidate in source {
            if let previous = deduplicated.last,
               Self.hammingDistance(previous.hash, candidate.hash) <= 5 {
                continue
            }
            deduplicated.append(candidate)
        }
        guard deduplicated.count > targetCount else { return deduplicated }

        var selectedIndexes: Set<Int> = [0, deduplicated.count - 1]
        let coverageCount = min(max(2, targetCount / 3), targetCount)
        if coverageCount > 1 {
            for index in 0..<coverageCount {
                let position = Double(index) * Double(deduplicated.count - 1) / Double(coverageCount - 1)
                selectedIndexes.insert(Int(position.rounded()))
            }
        }

        let rankedIndexes = deduplicated.indices.sorted {
            if deduplicated[$0].sceneScore == deduplicated[$1].sceneScore {
                return deduplicated[$0].timestamp < deduplicated[$1].timestamp
            }
            return deduplicated[$0].sceneScore > deduplicated[$1].sceneScore
        }
        for index in rankedIndexes where selectedIndexes.count < targetCount {
            selectedIndexes.insert(index)
        }
        return selectedIndexes.sorted().map { deduplicated[$0] }
    }

    private func imageSignature(_ image: CGImage) -> (hash: UInt64, brightness: Double)? {
        let width = 9
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                if pixels[y * width + x] > pixels[y * width + x + 1] {
                    hash |= UInt64(1) << bit
                }
                bit += 1
            }
        }
        let brightness = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        return (hash, Double(brightness) / 255)
    }

    private func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func normalizedVideoFileExtension(for attachment: FileAttachment) -> String {
        let originalExtension = (attachment.fileName as NSString).pathExtension.lowercased()
        if !originalExtension.isEmpty {
            return originalExtension
        }
        switch attachment.mimeType.lowercased() {
        case "video/quicktime":
            return "mov"
        case "video/webm":
            return "webm"
        default:
            return "mp4"
        }
    }

    private static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    private static func timestampLabel(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        return String(format: "%02dm%02ds", totalSeconds / 60, totalSeconds % 60)
    }
#endif
}

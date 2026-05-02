// ============================================================================
// ChatViewModel.swift
// ============================================================================ 
// ETOS LLM Studio Watch App 核心视图模型文件 (已重构)
//
// 功能特性:
// - 驱动主视图 (ContentView) 的所有业务逻辑
// - 管理应用状态，包括消息、会话、设置等
// - 处理网络请求、数据操作和用户交互
// ============================================================================

import Foundation
import SwiftUI
@preconcurrency import MarkdownUI
import WatchKit
import os.log
import Combine
import Shared
import AVFoundation
import AVFAudio
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "ChatViewModel")

enum WatchBackgroundOpacitySetting {
    static let defaultValue: Double = 0.7
    static let allowedRange: ClosedRange<Double> = 0.1...1.0

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, allowedRange.lowerBound), allowedRange.upperBound)
    }
}


struct ETPreparedMarkdownRenderPayload: Equatable, @unchecked Sendable {
    let sourceText: String
    let normalizedText: String
    let markdownContent: MarkdownContent
    let mathSegments: [ETMathContentSegment]
    let containsMathContent: Bool
    let containsMermaidContent: Bool
    let thinkingTitle: String?

    nonisolated static func build(from sourceText: String) async -> ETPreparedMarkdownRenderPayload {
        let normalizedText = normalizedMarkdownForStreaming(sourceText)
        let mathSegments = ETMathContentParser.parseSegments(in: normalizedText)
        let containsMath = mathSegments.contains { segment in
            switch segment {
            case .text:
                return false
            case .inlineMath, .blockMath:
                return true
            }
        }
        return ETPreparedMarkdownRenderPayload(
            sourceText: sourceText,
            normalizedText: normalizedText,
            markdownContent: MarkdownContent(normalizedText),
            mathSegments: mathSegments,
            containsMathContent: containsMath,
            containsMermaidContent: containsMermaidFence(in: normalizedText),
            thinkingTitle: extractThinkingTitle(from: normalizedText)
        )
    }

    nonisolated static func normalizedMarkdownForStreaming(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var normalizedLines: [String] = []
        normalizedLines.reserveCapacity(lines.count)
        var openedFence: (marker: Character, count: Int, infoToken: String?)?

        for line in lines {
            guard let fence = parseFenceLine(line) else {
                normalizedLines.append(line)
                continue
            }
            if let currentFence = openedFence {
                let isSameFenceFamily = currentFence.marker == fence.marker
                    && fence.count >= currentFence.count
                let trimmedTail = fence.tail.trimmingCharacters(in: .whitespacesAndNewlines)
                let isStrictClosingFence = trimmedTail.isEmpty
                let isRepeatedInfoClosingFence = !trimmedTail.isEmpty
                    && fence.infoToken == currentFence.infoToken

                if isSameFenceFamily && (isStrictClosingFence || isRepeatedInfoClosingFence) {
                    let closingFence = String(repeating: String(currentFence.marker), count: max(3, currentFence.count))
                    normalizedLines.append(closingFence)
                    openedFence = nil
                } else {
                    normalizedLines.append(line)
                }
            } else {
                openedFence = (marker: fence.marker, count: fence.count, infoToken: fence.infoToken)
                normalizedLines.append(line)
            }
        }

        var normalizedText = normalizedLines.joined(separator: "\n")
        guard let openedFence else { return normalizedText }

        let closingFence = String(repeating: String(openedFence.marker), count: max(3, openedFence.count))
        if normalizedText.hasSuffix("\n") {
            normalizedText += closingFence
        } else {
            normalizedText += "\n" + closingFence
        }
        return normalizedText
    }

    nonisolated static func extractThinkingTitle(from text: String) -> String? {
        for line in text.components(separatedBy: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 {
                let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
                let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
                let title = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return title
                }
            }

            let headingPrefix = trimmed.prefix { $0 == "#" }
            if !headingPrefix.isEmpty,
               headingPrefix.count <= 6,
               trimmed.dropFirst(headingPrefix.count).first?.isWhitespace == true {
                let title = trimmed
                    .dropFirst(headingPrefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return title
                }
            }
        }
        return nil
    }

    nonisolated static func containsMermaidFence(in text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            guard let fence = parseFenceLine(line) else { continue }
            let infoToken = fence.tail
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .first?
                .lowercased()
            if infoToken == "mermaid" || infoToken == "mmd" {
                return true
            }
        }
        return false
    }

    nonisolated static func parseFenceLine(_ line: String) -> (marker: Character, count: Int, tail: String, infoToken: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }

        var count = 0
        for character in trimmed {
            guard character == marker else { break }
            count += 1
        }
        guard count >= 3 else { return nil }

        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: count)
        let tail = String(trimmed[startIndex...])
        let infoToken = tail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map { String($0).lowercased() }
        return (marker: marker, count: count, tail: tail, infoToken: infoToken)
    }
}


enum WatchAttachmentImportKind: Equatable, Sendable {
    case audio
    case image
    case file
}


enum WatchAttachmentSourceResolution: Equatable, Sendable {
    case remote(URL)
    case local(URL)
}


struct WatchAttachmentImportPayload: Equatable, Sendable {
    let kind: WatchAttachmentImportKind
    let data: Data
    let mimeType: String
    let fileName: String
    let audioFormat: String
}


enum WatchAttachmentImportError: LocalizedError {
    case emptySource
    case unsupportedScheme
    case invalidURL
    case invalidPath
    case missingLocalFile(String)
    case directoryPath(String)
    case invalidHTTPStatus(Int)
    case emptyData
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySource:
            return NSLocalizedString("请输入链接或文件路径。", comment: "")
        case .unsupportedScheme:
            return NSLocalizedString("仅支持 http、https、file 链接或本地文件路径。", comment: "")
        case .invalidURL:
            return NSLocalizedString("链接格式无效。", comment: "")
        case .invalidPath:
            return NSLocalizedString("文件路径无效。", comment: "")
        case .missingLocalFile(let path):
            return String(format: NSLocalizedString("未找到文件“%@”。", comment: ""), path)
        case .directoryPath(let path):
            return String(format: NSLocalizedString("路径“%@”是目录，不能作为附件发送。", comment: ""), path)
        case .invalidHTTPStatus(let statusCode):
            return String(format: NSLocalizedString("下载失败，服务器返回 HTTP %d。", comment: ""), statusCode)
        case .emptyData:
            return NSLocalizedString("附件内容为空，无法发送。", comment: "")
        case .readFailed(let message):
            return String(format: NSLocalizedString("无法加载文件：%@", comment: ""), message)
        }
    }
}


extension ChatViewModel {
    nonisolated static func hasSendableContent(
        text: String,
        hasAudio: Bool,
        imageCount: Int,
        fileCount: Int,
        isSending: Bool
    ) -> Bool {
        guard !isSending else { return false }
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || hasAudio || imageCount > 0 || fileCount > 0
    }

    nonisolated static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    nonisolated static func resolveAttachmentSource(
        _ rawSource: String,
        documentsDirectory: URL = ChatViewModel.documentsDirectory()
    ) throws -> WatchAttachmentSourceResolution {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw WatchAttachmentImportError.emptySource }

        if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                guard url.host?.isEmpty == false else { throw WatchAttachmentImportError.invalidURL }
                return .remote(url)
            case "file":
                return try validatedLocalAttachmentURL(url)
            default:
                throw WatchAttachmentImportError.unsupportedScheme
            }
        }

        let localURL: URL
        if source.hasPrefix("/") {
            localURL = URL(fileURLWithPath: source)
        } else {
            let root = documentsDirectory.standardizedFileURL
            localURL = root.appendingPathComponent(source).standardizedFileURL
            guard isFileURL(localURL, containedIn: root) else {
                throw WatchAttachmentImportError.invalidPath
            }
        }
        return try validatedLocalAttachmentURL(localURL)
    }

    nonisolated static func resolvedAttachmentMimeType(fileName: String, responseMimeType: String? = nil) -> String {
        if let responseMimeType = responseMimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
           !responseMimeType.isEmpty {
            let loweredResponseMimeType = responseMimeType.lowercased()
            if loweredResponseMimeType != "application/octet-stream" {
                return loweredResponseMimeType
            }
        }

        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return "application/octet-stream" }
#if canImport(UniformTypeIdentifiers)
        if let type = UTType(filenameExtension: ext), let mimeType = type.preferredMIMEType {
            return mimeType.lowercased()
        }
#endif
        switch ext {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        case "txt":
            return "text/plain"
        case "json":
            return "application/json"
        case "pdf":
            return "application/pdf"
        default:
            return "application/octet-stream"
        }
    }

    nonisolated static func makeAttachmentImportPayload(
        data: Data,
        mimeType: String,
        fileName: String
    ) throws -> WatchAttachmentImportPayload {
        guard !data.isEmpty else { throw WatchAttachmentImportError.emptyData }
        let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let effectiveMimeType = normalizedMimeType.isEmpty ? resolvedAttachmentMimeType(fileName: fileName) : normalizedMimeType
        let normalizedFileName = normalizedAttachmentFileName(fileName, mimeType: effectiveMimeType)
        let kind: WatchAttachmentImportKind
        if effectiveMimeType.hasPrefix("audio/") {
            kind = .audio
        } else if effectiveMimeType.hasPrefix("image/") {
            kind = .image
        } else {
            kind = .file
        }

        return WatchAttachmentImportPayload(
            kind: kind,
            data: data,
            mimeType: effectiveMimeType,
            fileName: normalizedFileName,
            audioFormat: audioFormat(fileName: normalizedFileName, mimeType: effectiveMimeType)
        )
    }

    nonisolated static func loadAttachmentImportPayload(
        from rawSource: String,
        documentsDirectory: URL = ChatViewModel.documentsDirectory()
    ) async throws -> WatchAttachmentImportPayload {
        let resolution = try resolveAttachmentSource(rawSource, documentsDirectory: documentsDirectory)
        switch resolution {
        case .remote(let url):
            var request = URLRequest(url: url)
            request.timeoutInterval = NetworkSessionConfiguration.minimumRequestTimeout
            let (data, response) = try await NetworkSessionConfiguration.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw WatchAttachmentImportError.invalidHTTPStatus(httpResponse.statusCode)
            }
            let fileName = resolvedRemoteFileName(url: url, response: response)
            let mimeType = resolvedAttachmentMimeType(fileName: fileName, responseMimeType: response.mimeType)
            return try makeAttachmentImportPayload(data: data, mimeType: mimeType, fileName: fileName)
        case .local(let url):
            do {
                let data = try Data(contentsOf: url)
                let fileName = normalizedAttachmentFileName(url.lastPathComponent, mimeType: resolvedAttachmentMimeType(fileName: url.lastPathComponent))
                let mimeType = resolvedAttachmentMimeType(fileName: fileName)
                return try makeAttachmentImportPayload(data: data, mimeType: mimeType, fileName: fileName)
            } catch let error as WatchAttachmentImportError {
                throw error
            } catch {
                throw WatchAttachmentImportError.readFailed(error.localizedDescription)
            }
        }
    }

    nonisolated static func validatedLocalAttachmentURL(_ url: URL) throws -> WatchAttachmentSourceResolution {
        let fileURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw WatchAttachmentImportError.missingLocalFile(fileURL.path)
        }
        guard !isDirectory.boolValue else {
            throw WatchAttachmentImportError.directoryPath(fileURL.path)
        }
        return .local(fileURL)
    }

    nonisolated static func isFileURL(_ url: URL, containedIn root: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = url.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    nonisolated static func resolvedRemoteFileName(url: URL, response: URLResponse) -> String {
        let responseName = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !responseName.isEmpty && responseName.lowercased() != "unknown" {
            return responseName
        }
        let pathName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pathName.isEmpty {
            return pathName
        }
        return "附件_\(UUID().uuidString)"
    }

    nonisolated static func normalizedAttachmentFileName(_ fileName: String, mimeType: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = (trimmed.isEmpty ? "附件_\(UUID().uuidString)" : trimmed) as NSString
        let lastPathComponent = baseName.lastPathComponent.isEmpty ? "附件_\(UUID().uuidString)" : baseName.lastPathComponent
        guard (lastPathComponent as NSString).pathExtension.isEmpty else { return lastPathComponent }
        let ext = fallbackFileExtension(for: mimeType)
        return ext.isEmpty ? lastPathComponent : "\(lastPathComponent).\(ext)"
    }

    nonisolated static func fallbackFileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "audio/mpeg":
            return "mp3"
        case "audio/mp4", "audio/x-m4a":
            return "m4a"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/aac":
            return "aac"
        case "audio/flac":
            return "flac"
        case "text/plain":
            return "txt"
        case "application/json":
            return "json"
        case "application/pdf":
            return "pdf"
        default:
            return ""
        }
    }

    nonisolated static func audioFormat(fileName: String, mimeType: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        switch mimeType.lowercased() {
        case "audio/mpeg":
            return "mp3"
        case "audio/mp4", "audio/x-m4a":
            return "m4a"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/aac":
            return "aac"
        case "audio/flac":
            return "flac"
        default:
            return "m4a"
        }
    }
}


actor ETMarkdownPrecomputeWorker {
    static let shared = ETMarkdownPrecomputeWorker()

    var cache: [String: ETPreparedMarkdownRenderPayload] = [:]
    var keyOrder: [String] = []
    let cacheLimit = 240

    func prepare(source: String) async -> ETPreparedMarkdownRenderPayload {
        if let cached = cache[source] {
            return cached
        }

        let prepared = await ETPreparedMarkdownRenderPayload.build(from: source)
        cache[source] = prepared
        keyOrder.append(source)
        trimIfNeeded()
        return prepared
    }

    func trimIfNeeded() {
        while keyOrder.count > cacheLimit {
            let removed = keyOrder.removeFirst()
            cache.removeValue(forKey: removed)
        }
    }
}

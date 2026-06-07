// ============================================================================
// WatchChatViewModelAttachmentImport.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 watchOS ChatViewModel 的附件导入、来源解析与导入结果构建。
// ============================================================================

import Foundation
import ETOSCore
import UniformTypeIdentifiers

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

private enum WatchAttachmentImportError: LocalizedError {
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
    func importAttachment(from source: String) {
        guard !attachmentImportInProgress else { return }
        attachmentImportInProgress = true
        attachmentImportErrorMessage = nil
        let documentsDirectory = Self.documentsDirectory()

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try await Self.loadAttachmentImportPayload(
                    from: source,
                    documentsDirectory: documentsDirectory
                )
            }.result

            switch result {
            case .success(let payload):
                applyImportedAttachment(payload)
            case .failure(let error):
                presentAttachmentImportError(error.localizedDescription)
            }
            attachmentImportInProgress = false
        }
    }

    private func applyImportedAttachment(_ payload: WatchAttachmentImportPayload) {
        switch payload.kind {
        case .audio:
            pendingAudioAttachment = AudioAttachment(
                data: payload.data,
                mimeType: payload.mimeType,
                format: payload.audioFormat,
                fileName: payload.fileName
            )
        case .image:
            pendingImageAttachments.append(ImageAttachment(
                data: payload.data,
                mimeType: payload.mimeType,
                fileName: payload.fileName
            ))
        case .file:
            pendingFileAttachments.append(FileAttachment(
                data: payload.data,
                mimeType: payload.mimeType,
                fileName: payload.fileName
            ))
        }
    }

    private func presentAttachmentImportError(_ message: String) {
        attachmentImportErrorMessage = message.isEmpty ? NSLocalizedString("附件导入失败，请稍后重试。", comment: "") : message
        showAttachmentImportErrorAlert = true
    }
}

extension ChatViewModel {
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

    nonisolated private static func validatedLocalAttachmentURL(_ url: URL) throws -> WatchAttachmentSourceResolution {
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

    nonisolated private static func isFileURL(_ url: URL, containedIn root: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = url.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    nonisolated private static func resolvedRemoteFileName(url: URL, response: URLResponse) -> String {
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

    nonisolated private static func normalizedAttachmentFileName(_ fileName: String, mimeType: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = (trimmed.isEmpty ? "附件_\(UUID().uuidString)" : trimmed) as NSString
        let lastPathComponent = baseName.lastPathComponent.isEmpty ? "附件_\(UUID().uuidString)" : baseName.lastPathComponent
        guard (lastPathComponent as NSString).pathExtension.isEmpty else { return lastPathComponent }
        let ext = fallbackFileExtension(for: mimeType)
        return ext.isEmpty ? lastPathComponent : "\(lastPathComponent).\(ext)"
    }

    nonisolated private static func fallbackFileExtension(for mimeType: String) -> String {
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

    nonisolated private static func audioFormat(fileName: String, mimeType: String) -> String {
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

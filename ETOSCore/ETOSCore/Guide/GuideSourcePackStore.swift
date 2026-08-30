// ============================================================================
// GuideSourcePackStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 按完整 Commit 懒下载纯文本源码包，并在后台提供本地全文搜索与分段读取。
// ============================================================================

import Foundation
import ZIPFoundation

public struct GuideSourceCodeMatch: Codable, Hashable, Sendable {
    public let path: String
    public let lineNumber: Int
    public let preview: String

    public init(path: String, lineNumber: Int, preview: String) {
        self.path = path
        self.lineNumber = lineNumber
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case lineNumber = "line_number"
        case preview
    }
}

public struct GuideSourceExcerpt: Codable, Hashable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let totalLines: Int
    public let hasMore: Bool
    public let content: String

    private enum CodingKeys: String, CodingKey {
        case path
        case startLine = "start_line"
        case endLine = "end_line"
        case totalLines = "total_lines"
        case hasMore = "has_more"
        case content
    }
}

actor GuideSourcePackStore {
    private static let repository = "Eric-Terminal/ETOS-LLM-Studio"
    private static let maximumArchiveBytes = 64 * 1024 * 1024
    private static let maximumFileBytes: Int64 = 8 * 1024 * 1024
    private static let maximumTotalBytes: Int64 = 128 * 1024 * 1024
    private static let maximumFiles = 10_000
    private static let maximumPreviewCharacters = 400
    private static let maximumLineCharacters = 4_000
    private static let maximumExcerptCharacters = 80_000
    private static let allowedExtensions: Set<String> = [
        "swift", "md", "json", "plist", "yml", "yaml", "toml", "xml", "xcconfig", "entitlements",
        "strings", "stringsdict", "pbxproj", "sql", "proto", "go", "ts", "js", "vue", "html", "css", "sh",
        "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "metal", "py", "rb", "rs", "java", "kt", "kts"
    ]

    private let baseURL: URL
    private let urlSession: URLSession
    private let fileManager: FileManager
    private let cacheDirectoryOverride: URL?
    private var memoryPack: InstalledPack?

    init(
        baseURL: URL,
        urlSession: URLSession,
        fileManager: FileManager,
        cacheDirectoryURL: URL?
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.fileManager = fileManager
        self.cacheDirectoryOverride = cacheDirectoryURL
    }

    func search(
        query: String,
        pathPrefix: String?,
        commitSHA: String,
        limit: Int
    ) async throws -> [GuideSourceCodeMatch] {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty, query.count <= 256 else { throw GuideError.invalidToolArguments }
        let normalizedPrefix = try normalizedDirectory(pathPrefix ?? "")
        let pack = try await installedPack(commitSHA: commitSHA)
        let maximumResults = max(1, min(limit, 40))
        var results: [GuideSourceCodeMatch] = []

        for file in pack.manifest.files where normalizedPrefix.isEmpty || file.path.hasPrefix(normalizedPrefix) {
            try Task.checkCancellation()
            let fileURL = sourceURL(path: file.path, in: pack.directory)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                try? invalidate(pack)
                throw GuideError.sourceUnavailable
            }
            try visitLines(at: fileURL) { lineNumber, line in
                let normalizedLine = line.lowercased()
                guard terms.allSatisfy(normalizedLine.contains) else { return true }
                let preview = line.trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(GuideSourceCodeMatch(
                    path: file.path,
                    lineNumber: lineNumber,
                    preview: String(preview.prefix(Self.maximumPreviewCharacters))
                ))
                return results.count < maximumResults
            }
            if results.count >= maximumResults {
                break
            }
        }
        return results
    }

    func read(
        path: String,
        startLine: Int,
        endLine: Int,
        commitSHA: String
    ) async throws -> GuideSourceExcerpt {
        let normalizedPath = try normalizedSourcePath(path)
        let pack = try await installedPack(commitSHA: commitSHA)
        guard pack.manifest.files.contains(where: { $0.path == normalizedPath }) else {
            throw GuideError.sourceUnavailable
        }
        let fileURL = sourceURL(path: normalizedPath, in: pack.directory)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            try? invalidate(pack)
            throw GuideError.sourceUnavailable
        }

        let start = max(1, startLine)
        let requestedEnd = min(max(start, endLine), start + 239)
        var output = ""
        var returnedEnd = start - 1
        var totalLines = 0
        var outputIsFull = false
        try visitLines(at: fileURL) { lineNumber, line in
            totalLines = lineNumber
            guard !outputIsFull, lineNumber >= start, lineNumber <= requestedEnd else { return true }
            let visibleLine = String(line.prefix(Self.maximumLineCharacters))
            let truncationMarker = line.count > Self.maximumLineCharacters ? " …" : ""
            let renderedLine = "\(lineNumber): \(visibleLine)\(truncationMarker)"
            let separator = output.isEmpty ? "" : "\n"
            guard output.count + separator.count + renderedLine.count <= Self.maximumExcerptCharacters else {
                outputIsFull = true
                return true
            }
            output.append(separator)
            output.append(renderedLine)
            returnedEnd = lineNumber
            return true
        }
        guard start <= totalLines else {
            return GuideSourceExcerpt(
                path: normalizedPath,
                startLine: start,
                endLine: start - 1,
                totalLines: totalLines,
                hasMore: false,
                content: ""
            )
        }
        return GuideSourceExcerpt(
            path: normalizedPath,
            startLine: start,
            endLine: returnedEnd,
            totalLines: totalLines,
            hasMore: returnedEnd < totalLines,
            content: output
        )
    }

    private func installedPack(commitSHA: String) async throws -> InstalledPack {
        guard GuideBuildVersion.isFullSHA(commitSHA) else { throw GuideError.sourceUnavailable }
        let sha = commitSHA.lowercased()
        if let memoryPack, memoryPack.manifest.commitSHA.lowercased() == sha {
            return memoryPack
        }
        if let cached = try? loadCachedPack(sha: sha) {
            memoryPack = cached
            return cached
        }
        do {
            let installed = try await downloadAndInstall(sha: sha)
            memoryPack = installed
            return installed
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GuideError.sourceUnavailable
        }
    }

    private func downloadAndInstall(sha: String) async throws -> InstalledPack {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("guide")
            .appendingPathComponent("source-packs")
            .appendingPathComponent(sha)
        let (data, response) = try await urlSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              data.count <= Self.maximumArchiveBytes else {
            throw GuideError.sourceUnavailable
        }
        let archive = try Archive(data: data, accessMode: .read)
        var archiveEntries: [String: Entry] = [:]
        for entry in archive {
            guard archiveEntries.count <= Self.maximumFiles,
                  archiveEntries.updateValue(entry, forKey: entry.path) == nil else {
                throw GuideError.sourceUnavailable
            }
        }
        guard let manifestEntry = archiveEntries["manifest.json"],
              manifestEntry.type == .file,
              manifestEntry.uncompressedSize <= 1024 * 1024 else {
            throw GuideError.sourceUnavailable
        }
        var manifestData = Data()
        _ = try archive.extract(manifestEntry) { manifestData.append($0) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        try validate(manifest: manifest, sha: sha)

        let root = try cacheDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let temporaryDirectory = root.appendingPathComponent(".\(sha)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        do {
            let sourcesDirectory = temporaryDirectory.appendingPathComponent("sources", isDirectory: true)
            try fileManager.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
            for file in manifest.files {
                try Task.checkCancellation()
                guard let entry = archiveEntries["sources/\(file.path)"],
                      entry.type == .file,
                      Int64(entry.uncompressedSize) == file.size else {
                    throw GuideError.sourceUnavailable
                }
                let destination = sourceURL(path: file.path, in: temporaryDirectory)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                _ = try archive.extract(entry, to: destination)
            }
            try manifestData.write(
                to: temporaryDirectory.appendingPathComponent("manifest.json"),
                options: .atomic
            )

            let destination = root.appendingPathComponent(sha, isDirectory: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporaryDirectory, to: destination)
            for cachedURL in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where cachedURL.lastPathComponent != sha {
                try? fileManager.removeItem(at: cachedURL)
            }
            return InstalledPack(directory: destination, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    private func loadCachedPack(sha: String) throws -> InstalledPack {
        let directory = try cacheDirectory().appendingPathComponent(sha, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try validate(manifest: manifest, sha: sha)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.appendingPathComponent("sources", isDirectory: true).path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw GuideError.sourceUnavailable
        }
        return InstalledPack(directory: directory, manifest: manifest)
    }

    private func validate(manifest: Manifest, sha: String) throws {
        guard manifest.schemaVersion == 1,
              manifest.repository == Self.repository,
              manifest.commitSHA.lowercased() == sha,
              !manifest.files.isEmpty,
              manifest.files.count <= Self.maximumFiles else {
            throw GuideError.sourceUnavailable
        }
        var paths = Set<String>()
        var totalBytes: Int64 = 0
        for file in manifest.files {
            guard try normalizedSourcePath(file.path) == file.path,
                  file.size >= 0,
                  file.size <= Self.maximumFileBytes,
                  paths.insert(file.path).inserted else {
                throw GuideError.sourceUnavailable
            }
            totalBytes += file.size
            guard totalBytes <= Self.maximumTotalBytes else { throw GuideError.sourceUnavailable }
        }
    }

    private func normalizedSourcePath(_ path: String) throws -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              Self.allowedExtensions.contains((normalized as NSString).pathExtension.lowercased()) else {
            throw GuideError.sourceUnavailable
        }
        return normalized
    }

    private func normalizedDirectory(_ path: String) throws -> String {
        let normalized = path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"),
              !normalized.contains("\\"),
              normalized.isEmpty || components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw GuideError.invalidToolArguments
        }
        return normalized.isEmpty ? "" : normalized + "/"
    }

    private func sourceURL(path: String, in packDirectory: URL) -> URL {
        path.split(separator: "/").reduce(packDirectory.appendingPathComponent("sources", isDirectory: true)) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }
    }

    // 固定大小读取只在内存中保留当前未结束的一行，避免长文件搜索时构造整份 String。
    private func visitLines(at url: URL, _ visit: (Int, String) throws -> Bool) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        var lineNumber = 0
        var sawData = false
        var endedWithNewline = false

        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            sawData = true
            endedWithNewline = chunk.last == 0x0A
            pending.append(chunk)
            var cursor = pending.startIndex
            while let newline = pending[cursor...].firstIndex(of: 0x0A) {
                let lineData = Data(pending[cursor..<newline])
                guard let line = String(data: lineData, encoding: .utf8) else {
                    throw GuideError.sourceUnavailable
                }
                lineNumber += 1
                guard try visit(lineNumber, line) else { return }
                cursor = pending.index(after: newline)
            }
            if cursor != pending.startIndex {
                pending.removeSubrange(pending.startIndex..<cursor)
            }
        }
        if !pending.isEmpty {
            guard let line = String(data: pending, encoding: .utf8) else {
                throw GuideError.sourceUnavailable
            }
            lineNumber += 1
            _ = try visit(lineNumber, line)
        } else if sawData, endedWithNewline {
            lineNumber += 1
            _ = try visit(lineNumber, "")
        }
    }

    private func cacheDirectory() throws -> URL {
        if let cacheDirectoryOverride {
            return cacheDirectoryOverride
        }
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw GuideError.sourceUnavailable
        }
        return caches.appendingPathComponent("GuideSourcePacks", isDirectory: true)
    }

    private func invalidate(_ pack: InstalledPack) throws {
        if memoryPack?.directory == pack.directory {
            memoryPack = nil
        }
        try fileManager.removeItem(at: pack.directory)
    }

    private struct InstalledPack {
        let directory: URL
        let manifest: Manifest
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let repository: String
        let commitSHA: String
        let files: [ManifestFile]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case repository
            case commitSHA = "commit_sha"
            case files
        }
    }

    private struct ManifestFile: Codable {
        let path: String
        let size: Int64
    }
}

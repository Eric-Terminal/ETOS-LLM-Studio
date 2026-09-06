// ============================================================================
// GuideSourceService.swift
// ============================================================================
// ETOS LLM Studio
//
// 只允许读取当前构建精确 Commit 的公开源码；LocalBuild 与短 SHA 不做猜测。
// ============================================================================

import Foundation

public struct GuideSourceTreeEntry: Codable, Hashable, Sendable {
    public let path: String
    public let type: String
    public let size: Int?

    public init(path: String, type: String, size: Int? = nil) {
        self.path = path
        self.type = type
        self.size = size
    }
}

public struct GuideSourceTree: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let repository: String
    public let commitSHA: String
    public let truncated: Bool
    public let entries: [GuideSourceTreeEntry]

    public init(
        schemaVersion: Int,
        repository: String,
        commitSHA: String,
        truncated: Bool,
        entries: [GuideSourceTreeEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.repository = repository
        self.commitSHA = commitSHA
        self.truncated = truncated
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case repository
        case commitSHA = "commit_sha"
        case truncated
        case entries
    }
}

public enum GuideBuildVersion {
    public static func fullCommitSHA(bundle: Bundle = .main) -> String? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ETOS_DEBUG_COMMIT_HASH"],
           isFullSHA(override) {
            return override.lowercased()
        }
        #endif
        guard let value = bundle.object(forInfoDictionaryKey: "ETCommitHash") as? String,
              isFullSHA(value) else {
            return nil
        }
        return value.lowercased()
    }

    public static func displayCommit(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "LocalBuild" }
        return String(value.prefix(7))
    }

    public static func isFullSHA(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count == 40 && normalized.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

public actor GuideSourceService {
    public static let repository = "Eric-Terminal/ETOS-LLM-Studio"
    public static let shared = GuideSourceService()

    private let baseURL: URL
    private let urlSession: URLSession
    private let fileManager: FileManager
    private let cacheDirectoryOverride: URL?
    private let sourcePackStore: GuideSourcePackStore
    private var memoryTree: GuideSourceTree?

    public init(
        baseURL: URL = FeedbackServiceConfig.default.baseURL,
        urlSession: URLSession = NetworkSessionConfiguration.shared,
        fileManager: FileManager = .default,
        cacheDirectoryURL: URL? = nil,
        sourcePackDirectoryURL: URL? = nil
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.fileManager = fileManager
        self.cacheDirectoryOverride = cacheDirectoryURL
        self.sourcePackStore = GuideSourcePackStore(
            baseURL: baseURL,
            urlSession: urlSession,
            fileManager: fileManager,
            cacheDirectoryURL: sourcePackDirectoryURL
        )
    }

    public func searchTree(query: String, commitSHA: String, limit: Int = 40) async throws -> [GuideSourceTreeEntry] {
        let tree = try await sourceTree(commitSHA: commitSHA)
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return Array(tree.entries.lazy.filter { entry in
            let path = entry.path.lowercased()
            return terms.allSatisfy(path.contains)
        }.prefix(max(1, min(limit, 100))))
    }

    public func sourceTree(commitSHA: String) async throws -> GuideSourceTree {
        guard GuideBuildVersion.isFullSHA(commitSHA) else { throw GuideError.sourceUnavailable }
        let sha = commitSHA.lowercased()
        if let memoryTree, memoryTree.commitSHA == sha {
            return memoryTree
        }
        do {
            let cached = try loadCachedTree(sha: sha)
            if isValid(cached, sha: sha) {
                memoryTree = cached
                return cached
            }
            try? fileManager.removeItem(at: try cacheFileURL(sha: sha))
        } catch {
            // 损坏或半写入的缓存不能阻断恢复；删除后从精确 Commit 重新获取。
            try? fileManager.removeItem(at: try cacheFileURL(sha: sha))
        }

        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("guide")
            .appendingPathComponent("source-trees")
            .appendingPathComponent(sha)
        let (data, response) = try await urlSession.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let tree = try JSONDecoder().decode(GuideSourceTree.self, from: data)
        guard isValid(tree, sha: sha) else { throw GuideError.invalidResponse }
        try storeTree(tree, sha: sha)
        memoryTree = tree
        return tree
    }

    public func listDirectory(
        path: String,
        commitSHA: String,
        limit: Int = 100
    ) async throws -> [GuideSourceTreeEntry] {
        let directory = try validatedDirectoryPath(path)
        let tree = try await sourceTree(commitSHA: commitSHA)
        let prefix = directory.isEmpty ? "" : "\(directory)/"
        return Array(tree.entries.lazy.filter { entry in
            guard entry.path.hasPrefix(prefix) else { return false }
            let remainder = entry.path.dropFirst(prefix.count)
            return !remainder.isEmpty && !remainder.contains("/")
        }.prefix(max(1, min(limit, 200))))
    }

    public func searchSourceCode(
        query: String,
        pathPrefix: String? = nil,
        commitSHA: String,
        limit: Int = 40
    ) async throws -> [GuideSourceCodeMatch] {
        try await sourcePackStore.search(
            query: query,
            pathPrefix: pathPrefix,
            commitSHA: commitSHA,
            limit: limit
        )
    }

    public func readSource(
        path: String,
        startLine: Int,
        endLine: Int,
        commitSHA: String
    ) async throws -> GuideSourceExcerpt {
        try await sourcePackStore.read(
            path: path,
            startLine: startLine,
            endLine: endLine,
            commitSHA: commitSHA
        )
    }

    private func validatedDirectoryPath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { throw GuideError.sourceUnavailable }
        let normalized = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.split(separator: "/").contains("..") else {
            throw GuideError.sourceUnavailable
        }
        return normalized
    }

    private func isValid(_ tree: GuideSourceTree, sha: String) -> Bool {
        tree.schemaVersion == 1
            && tree.repository == Self.repository
            && tree.commitSHA.lowercased() == sha
            && !tree.truncated
    }

    private func cacheDirectory() throws -> URL {
        if let cacheDirectoryOverride {
            return cacheDirectoryOverride
        }
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw GuideError.sourceUnavailable
        }
        return caches.appendingPathComponent("GuideSourceTrees", isDirectory: true)
    }

    private func loadCachedTree(sha: String) throws -> GuideSourceTree {
        let data = try Data(contentsOf: try cacheFileURL(sha: sha))
        return try JSONDecoder().decode(GuideSourceTree.self, from: data)
    }

    private func cacheFileURL(sha: String) throws -> URL {
        try cacheDirectory().appendingPathComponent("\(sha).json")
    }

    private func storeTree(_ tree: GuideSourceTree, sha: String) throws {
        let directory = try cacheDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(tree)
        try data.write(to: directory.appendingPathComponent("\(sha).json"), options: .atomic)

        // 新版本成功落盘后才清理旧树，网络失败时仍保留上一次可诊断数据。
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.lastPathComponent != "\(sha).json" {
            try? fileManager.removeItem(at: url)
        }
    }
}

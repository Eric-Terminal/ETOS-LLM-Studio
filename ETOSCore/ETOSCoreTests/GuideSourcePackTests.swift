// ============================================================================
// GuideSourcePackTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 覆盖精确 Commit 源码包的懒下载、本地全文搜索、缓存与按行读取。
// ============================================================================

import Foundation
import Testing
import ZIPFoundation
@testable import ETOSCore

@Suite("向导源码包", .serialized)
struct GuideSourcePackTests {
    @Test("源码包只下载一次并支持全文定位与分段读取")
    func sourcePackSearchesAndReadsLocally() async throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let sourcePath = "ETOSCore/Guide/LongGuide.swift"
        let source = (["struct LongGuide {"]
            + (1...300).map { $0 == 125 ? "    let guideOverlayEnabled = true" : "    let line\($0) = \($0)" }
            + ["}"])
            .joined(separator: "\n")
        let archiveData = try makeSourcePack(
            sha: sha,
            files: [
                sourcePath: Data(source.utf8),
                "README.md": Data("# ETOS".utf8)
            ]
        )
        let baseURL = try #require(URL(string: "https://feedback.example"))
        let expectedURL = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("guide")
            .appendingPathComponent("source-packs")
            .appendingPathComponent(sha)
        GuideSourcePackURLProtocol.configure(url: expectedURL, data: archiveData)
        defer { GuideSourcePackURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideSourcePackURLProtocol.self]
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let service = GuideSourceService(
            baseURL: baseURL,
            urlSession: URLSession(configuration: configuration),
            sourcePackDirectoryURL: cacheDirectory
        )

        let matches = try await service.searchSourceCode(
            query: "guideOverlayEnabled",
            pathPrefix: "ETOSCore/Guide",
            commitSHA: sha
        )
        #expect(matches == [GuideSourceCodeMatch(
            path: sourcePath,
            lineNumber: 126,
            preview: "let guideOverlayEnabled = true"
        )])

        let excerpt = try await service.readSource(
            path: sourcePath,
            startLine: 1,
            endLine: 1_000,
            commitSHA: sha
        )
        #expect(excerpt.startLine == 1)
        #expect(excerpt.endLine == 240)
        #expect(excerpt.totalLines == 302)
        #expect(excerpt.hasMore)
        #expect(excerpt.content.split(separator: "\n").count == 240)

        let restartedService = GuideSourceService(
            baseURL: baseURL,
            urlSession: URLSession(configuration: configuration),
            sourcePackDirectoryURL: cacheDirectory
        )
        let cachedMatches = try await restartedService.searchSourceCode(
            query: "guideOverlayEnabled",
            commitSHA: sha
        )
        #expect(cachedMatches == matches)
        #expect(GuideSourcePackURLProtocol.requestCount == 1)
    }

    @Test("源码包拒绝清单中的越界路径")
    func sourcePackRejectsUnsafeManifestPath() async throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let archiveData = try makeSourcePack(
            sha: sha,
            files: ["Safe.swift": Data("let safe = true".utf8)],
            manifestFiles: ["../Secret.swift": Data("let secret = true".utf8)]
        )
        let baseURL = try #require(URL(string: "https://feedback.example"))
        let expectedURL = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("guide")
            .appendingPathComponent("source-packs")
            .appendingPathComponent(sha)
        GuideSourcePackURLProtocol.configure(url: expectedURL, data: archiveData)
        defer { GuideSourcePackURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideSourcePackURLProtocol.self]
        let service = GuideSourceService(
            baseURL: baseURL,
            urlSession: URLSession(configuration: configuration),
            sourcePackDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        await #expect(throws: GuideError.self) {
            _ = try await service.searchSourceCode(query: "secret", commitSHA: sha)
        }
    }

    @Test("构建 Commit 变化后安装新源码包并清理旧缓存")
    func sourcePackReplacesPreviousCommitCache() async throws {
        let oldSHA = "0123456789abcdef0123456789abcdef01234567"
        let newSHA = "fedcba9876543210fedcba9876543210fedcba98"
        let baseURL = try #require(URL(string: "https://feedback.example"))
        func packURL(_ sha: String) -> URL {
            baseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("guide")
                .appendingPathComponent("source-packs")
                .appendingPathComponent(sha)
        }
        GuideSourcePackURLProtocol.configure(responses: [
            packURL(oldSHA): try makeSourcePack(
                sha: oldSHA,
                files: ["Guide.swift": Data("let version = \"old\"".utf8)]
            ),
            packURL(newSHA): try makeSourcePack(
                sha: newSHA,
                files: ["Guide.swift": Data("let version = \"new\"".utf8)]
            )
        ])
        defer { GuideSourcePackURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuideSourcePackURLProtocol.self]
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let service = GuideSourceService(
            baseURL: baseURL,
            urlSession: URLSession(configuration: configuration),
            sourcePackDirectoryURL: cacheDirectory
        )

        _ = try await service.searchSourceCode(query: "old", commitSHA: oldSHA)
        #expect(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(oldSHA).path))
        _ = try await service.searchSourceCode(query: "new", commitSHA: newSHA)

        #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(oldSHA).path))
        #expect(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(newSHA).path))
        #expect(GuideSourcePackURLProtocol.requestCount == 2)
    }

    private func makeSourcePack(
        sha: String,
        files: [String: Data],
        manifestFiles: [String: Data]? = nil
    ) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        let declaredFiles = manifestFiles ?? files
        let manifest: [String: Any] = [
            "schema_version": 1,
            "repository": GuideSourceService.repository,
            "commit_sha": sha,
            "files": declaredFiles.keys.sorted().map { path in
                ["path": path, "size": declaredFiles[path]!.count]
            }
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try add(manifestData, path: "manifest.json", to: archive)
        for path in files.keys.sorted() {
            try add(files[path]!, path: "sources/\(path)", to: archive)
        }
        return try #require(archive.data)
    }

    private func add(_ data: Data, path: String, to archive: Archive) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            let start = Int(position)
            let end = min(start + size, data.count)
            return data.subdata(in: start..<end)
        }
    }
}

private final class GuideSourcePackURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [URL: Data] = [:]
    private static var count = 0

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func configure(url: URL, data: Data) {
        configure(responses: [url: data])
    }

    static func configure(responses: [URL: Data]) {
        lock.withLock {
            Self.responses = responses
            count = 0
        }
    }

    static func reset() {
        lock.withLock {
            responses = [:]
            count = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response: (URL, Data)? = Self.lock.withLock {
            guard let requestURL = request.url, let responseData = Self.responses[requestURL] else { return nil }
            Self.count += 1
            return (requestURL, responseData)
        }
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: response.0,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/zip"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

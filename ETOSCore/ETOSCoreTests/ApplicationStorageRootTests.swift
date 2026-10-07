// ============================================================================
// ApplicationStorageRootTests.swift
// ============================================================================
// 数据库、浏览器文件、本地权重和调试传输必须共享应用根目录，保证跨端备份
// 中的相对路径在 macOS Application Support 下仍可解析。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("跨平台应用存储目录")
struct ApplicationStorageRootTests {
    @Test("浏览器下载可转换成相同的 app URI")
    func browserDownloadUsesApplicationRoot() throws {
        let sessionID = UUID()
        let url = try BrowserAgentStorage.destinationURL(
            sessionID: sessionID,
            directoryName: "Downloads",
            proposedFilename: "example.txt"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let contents = Data("portable attachment".utf8)
        try contents.write(to: url)
        let uri = try BrowserAgentStorage.appURI(for: url)
        #expect(uri == "app://BrowserAgent/\(sessionID.uuidString)/Downloads/example.txt")
        let relativePath = String(uri.dropFirst("app://".count))
        #expect(try Data(contentsOf: StorageUtility.documentsDirectory.appendingPathComponent(relativePath)) == contents)
    }

    @Test("浏览器不能把应用目录外的文件转换成应用附件 URI")
    func browserRejectsExternalFile() {
        let outside = StorageUtility.documentsDirectory.deletingLastPathComponent()
            .appendingPathComponent("external-\(UUID()).txt")
        #expect(throws: BrowserAgentError.self) { try BrowserAgentStorage.appURI(for: outside) }
    }

    @Test("本地权重与会话存储位于同一个应用数据根目录")
    func localModelsShareChatRoot() {
        let root = StorageUtility.documentsDirectory.standardizedFileURL
        #expect(LocalModelStore.localModelsDirectoryURL().deletingLastPathComponent().standardizedFileURL == root)
        #expect(Persistence.getChatsDirectory().deletingLastPathComponent().standardizedFileURL == root)
    }

    @MainActor
    @Test("调试文件上传和下载使用应用数据目录")
    func debugTransferSharesApplicationRoot() async throws {
        let directory = "root-regression-\(UUID().uuidString)"
        let relativePath = directory + "/attachment.txt"
        let contents = Data("shared storage root".utf8)
        let targetURL = StorageUtility.documentsDirectory.appendingPathComponent(relativePath)
        defer { try? FileManager.default.removeItem(at: targetURL.deletingLastPathComponent()) }
        let server = LocalDebugServer()
        let uploaded = await server.handleUpload(["path": relativePath, "data": contents.base64EncodedString()])
        #expect(uploaded["status"] as? String == "ok")
        #expect(try Data(contentsOf: targetURL) == contents)
        let downloaded = await server.handleDownload(["path": relativePath])
        #expect(downloaded["data"] as? String == contents.base64EncodedString())
    }
}

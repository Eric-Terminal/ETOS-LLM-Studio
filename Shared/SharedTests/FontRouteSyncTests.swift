// ============================================================================
// FontRouteSyncTests.swift
// ============================================================================
// 字体路由与同步测试
// - 验证字体同步打包是否携带字体文件与路由配置
// - 验证字体路由同步时会过滤无效 ID 并保留优先级
// - 验证候选字体均不可用时回退到系统字体
// ============================================================================

import Testing
import Foundation
@testable import Shared

@Suite("字体路由与同步测试")
struct FontRouteSyncTests {

    @Test("字体同步打包会携带字体文件与路由配置")
    func testBuildPackageIncludesFontFilesAndRouteConfiguration() async throws {
        try await withIsolatedFontStore {
            let fontData = Data([0x11, 0x22, 0x33, 0x44])
            let assetID = UUID(uuidString: "A7B6C7D8-1111-2222-3333-444455556666")!
            let fileName = "unit-test-font.ttf"
            let route = FontRouteConfiguration(body: [assetID], emphasis: [], strong: [], code: [])

            _ = Persistence.saveFont(fontData, fileName: fileName)
            #expect(FontLibrary.saveAssets([
                FontAssetRecord(
                    id: assetID,
                    fileName: fileName,
                    checksum: fontData.sha256Hex,
                    displayName: "单元测试字体",
                    postScriptName: "UnitTestFontPS",
                    importedAt: Date(timeIntervalSince1970: 1_730_000_000),
                    isEnabled: true
                )
            ]))
            #expect(FontLibrary.saveRouteConfiguration(route))

            let package = SyncEngine.buildPackage(options: [.fontFiles])
            #expect(package.fontFiles.count == 1)

            guard let syncedFont = package.fontFiles.first else {
                Issue.record("同步包中缺少字体文件")
                return
            }
            #expect(syncedFont.assetID == assetID)
            #expect(syncedFont.filename == fileName)
            #expect(syncedFont.data == fontData)
            #expect(syncedFont.checksum == fontData.sha256Hex)

            guard let routeData = package.fontRouteConfigurationData else {
                Issue.record("同步包中缺少字体路由配置")
                return
            }
            let decoded = try JSONDecoder().decode(FontRouteConfiguration.self, from: routeData)
            #expect(decoded == route)
        }
    }

    @Test("字体路由同步会过滤无效 ID 并保留有效优先级")
    func testApplySyncPackageNormalizesFontRouteIDs() async throws {
        try await withIsolatedFontStore {
            let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
            let invalidID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

            #expect(FontLibrary.saveAssets([
                FontAssetRecord(
                    id: firstID,
                    fileName: "first.ttf",
                    checksum: "checksum-first",
                    displayName: "第一字体",
                    postScriptName: "FirstPS",
                    importedAt: Date(timeIntervalSince1970: 1_730_000_001),
                    isEnabled: true
                ),
                FontAssetRecord(
                    id: secondID,
                    fileName: "second.ttf",
                    checksum: "checksum-second",
                    displayName: "第二字体",
                    postScriptName: "SecondPS",
                    importedAt: Date(timeIntervalSince1970: 1_730_000_002),
                    isEnabled: true
                )
            ]))
            #expect(FontLibrary.saveRouteConfiguration(.init()))

            let incoming = FontRouteConfiguration(
                body: [secondID, invalidID, secondID, firstID],
                emphasis: [invalidID, firstID],
                strong: [invalidID],
                code: [firstID, secondID],
                languageBuckets: [
                    "zh-Hans": .init(
                        body: [firstID, invalidID],
                        emphasis: [invalidID],
                        strong: [secondID, secondID],
                        code: []
                    )
                ]
            )
            let encodedIncoming = try JSONEncoder().encode(incoming)
            let package = SyncPackage(
                options: [.fontFiles],
                fontFiles: [],
                fontRouteConfigurationData: encodedIncoming
            )

            let summary = await SyncEngine.apply(package: package)
            #expect(summary.importedFontFiles == 0)
            #expect(summary.importedFontRouteConfigurations == 1)
            #expect(summary.skippedFontRouteConfigurations == 0)

            let merged = FontLibrary.loadRouteConfiguration()
            #expect(merged.body == [secondID, firstID])
            #expect(merged.emphasis == [firstID])
            #expect(merged.strong.isEmpty)
            #expect(merged.code == [firstID, secondID])

            guard let zhHans = merged.languageBuckets["zh-Hans"] else {
                Issue.record("缺少语言桶配置")
                return
            }
            #expect(zhHans.body == [firstID])
            #expect(zhHans.emphasis.isEmpty)
            #expect(zhHans.strong == [secondID])
            #expect(zhHans.code.isEmpty)
        }
    }

    @Test("当候选字体无法覆盖样本文本时返回 nil（系统字体兜底）")
    func testResolvePostScriptNameReturnsNilWhenNoCandidateCanRender() async throws {
        try await withIsolatedFontStore {
            let assetID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
            #expect(FontLibrary.saveAssets([
                FontAssetRecord(
                    id: assetID,
                    fileName: "fake.ttf",
                    checksum: "fake-checksum",
                    displayName: "不可用字体",
                    postScriptName: "Definitely-Not-Existing-Font-PS-Name",
                    importedAt: Date(timeIntervalSince1970: 1_730_000_100),
                    isEnabled: true
                )
            ]))
            #expect(FontLibrary.saveRouteConfiguration(.init(body: [assetID], emphasis: [], strong: [], code: [])))

            let unsupportedSample = "\u{100000}\u{100001}\u{100002}"
            let resolved = FontLibrary.resolvePostScriptName(for: .body, sampleText: unsupportedSample)
            #expect(resolved == nil)
        }
    }

    private func withIsolatedFontStore(_ body: () async throws -> Void) async throws {
        let fileManager = FileManager.default
        let fontDirectory = Persistence.getFontDirectory()
        let backupRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("font-tests-backup-\(UUID().uuidString)", isDirectory: true)
        let backupDirectory = backupRoot.appendingPathComponent("FontFiles", isDirectory: true)
        let hadOriginalStore = fileManager.fileExists(atPath: fontDirectory.path)

        if hadOriginalStore {
            try? fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            try? fileManager.copyItem(at: fontDirectory, to: backupDirectory)
        }

        try? fileManager.removeItem(at: fontDirectory)
        try fileManager.createDirectory(at: fontDirectory, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: fontDirectory)
            if hadOriginalStore, fileManager.fileExists(atPath: backupDirectory.path) {
                try? fileManager.copyItem(at: backupDirectory, to: fontDirectory)
            }
            try? fileManager.removeItem(at: backupRoot)
        }

        try await body()
    }
}

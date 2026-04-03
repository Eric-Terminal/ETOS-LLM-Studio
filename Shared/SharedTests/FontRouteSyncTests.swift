// ============================================================================
// FontRouteSyncTests.swift
// ============================================================================
// 字体路由与同步测试
// - 验证字体同步打包是否携带字体文件与路由配置
// - 验证字体路由同步时会过滤无效 ID 并保留优先级
// - 验证候选字体均不可用时回退到系统字体
// - 验证重复校验和在同步合并时会去重，启用状态变化可被正确应用
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
            #expect(syncedFont.isEnabled == true)

            guard let routeData = package.fontRouteConfigurationData else {
                Issue.record("同步包中缺少字体路由配置")
                return
            }
            let decoded = try JSONDecoder().decode(FontRouteConfiguration.self, from: routeData)
            #expect(decoded == route)
        }
    }

    @Test("同步合并遇到重复校验和时会跳过，启用状态变化时会更新")
    func testApplySyncPackageSkipsDuplicateChecksumButUpdatesEnabledState() async throws {
        try await withIsolatedFontStore {
            let fixture = try loadSystemFontFixture()
            let localRecord = try FontLibrary.importFont(
                data: fixture.data,
                fileName: "local-\(fixture.fileName)"
            )

            let duplicateEnabled = SyncedFontFile(
                assetID: UUID(),
                displayName: localRecord.displayName,
                postScriptName: localRecord.postScriptName,
                filename: "incoming-\(fixture.fileName)",
                data: fixture.data,
                isEnabled: true
            )
            let firstSummary = await SyncEngine.apply(
                package: SyncPackage(options: [.fontFiles], fontFiles: [duplicateEnabled])
            )
            #expect(firstSummary.importedFontFiles == 0)
            #expect(firstSummary.skippedFontFiles == 1)

            let duplicateDisabled = SyncedFontFile(
                assetID: UUID(),
                displayName: localRecord.displayName,
                postScriptName: localRecord.postScriptName,
                filename: "incoming-disabled-\(fixture.fileName)",
                data: fixture.data,
                isEnabled: false
            )
            let secondSummary = await SyncEngine.apply(
                package: SyncPackage(options: [.fontFiles], fontFiles: [duplicateDisabled])
            )
            #expect(secondSummary.importedFontFiles == 1)
            #expect(secondSummary.skippedFontFiles == 0)

            let assets = FontLibrary.loadAssets()
            #expect(assets.count == 1)
            #expect(assets.first?.isEnabled == false)
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

    @Test("字体路由配置编解码会保留顺序与语言桶")
    func testFontRouteConfigurationCodingPreservesOrderAndLanguageBuckets() throws {
        let bodyFirst = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let bodySecond = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        let codeOnly = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
        let source = FontRouteConfiguration(
            body: [bodySecond, bodyFirst],
            emphasis: [bodyFirst],
            strong: [bodyFirst, bodySecond],
            code: [codeOnly, bodySecond],
            languageBuckets: [
                "zh-Hans": .init(
                    body: [bodyFirst, bodySecond],
                    emphasis: [bodySecond],
                    strong: [bodyFirst],
                    code: [codeOnly]
                ),
                "ja": .init(
                    body: [codeOnly],
                    emphasis: [],
                    strong: [bodySecond],
                    code: [codeOnly, bodyFirst]
                )
            ]
        )

        let encoded = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(FontRouteConfiguration.self, from: encoded)
        #expect(decoded == source)
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

    @Test("字体启用状态变更会写回清单并参与路由过滤")
    func testSetAssetEnabledPersistsAndAffectsFallback() async throws {
        try await withIsolatedFontStore {
            let assetID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
            #expect(FontLibrary.saveAssets([
                FontAssetRecord(
                    id: assetID,
                    fileName: "disabled.ttf",
                    checksum: "disabled-checksum",
                    displayName: "可停用字体",
                    postScriptName: "DisabledFontPS",
                    importedAt: Date(timeIntervalSince1970: 1_730_000_200),
                    isEnabled: true
                )
            ]))
            #expect(FontLibrary.saveRouteConfiguration(.init(body: [assetID], emphasis: [], strong: [], code: [])))

            #expect(FontLibrary.setAssetEnabled(id: assetID, isEnabled: false))

            let reloaded = FontLibrary.loadAssets()
            #expect(reloaded.first?.isEnabled == false)
            #expect(FontLibrary.fallbackPostScriptNames(for: .body).isEmpty)
        }
    }

    @Test("旧版本同步包缺少 isEnabled 字段时默认按启用处理")
    func testDecodeLegacySyncedFontFileDefaultsIsEnabled() throws {
        let assetID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let legacyPayload: [String: Any] = [
            "assetID": assetID.uuidString,
            "displayName": "Legacy Font",
            "postScriptName": "LegacyFontPS",
            "filename": "legacy.ttf",
            "data": Data([0x01, 0x02]).base64EncodedString(),
            "checksum": Data([0x01, 0x02]).sha256Hex
        ]

        let encoded = try JSONSerialization.data(withJSONObject: legacyPayload)
        let decoded = try JSONDecoder().decode(SyncedFontFile.self, from: encoded)
        #expect(decoded.isEnabled == true)
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

    private func loadSystemFontFixture() throws -> (data: Data, fileName: String) {
        let directCandidates = [
            "/System/Library/Fonts/Symbol.ttf",
            "/System/Library/Fonts/SFNSMono.ttf",
            "/System/Library/Fonts/HelveticaNeue.ttc",
            "/Library/Fonts/Arial.ttf"
        ]
        let fileManager = FileManager.default

        for path in directCandidates where fileManager.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return (data, url.lastPathComponent)
            }
        }

        let searchDirectories = [
            "/System/Library/Fonts",
            "/Library/Fonts"
        ]
        for directoryPath in searchDirectories where fileManager.fileExists(atPath: directoryPath) {
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ["ttf", "otf", "ttc"].contains(ext) else { continue }
                if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
                    return (data, fileURL.lastPathComponent)
                }
            }
        }

        throw NSError(
            domain: "FontRouteSyncTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "测试环境中未找到可用字体样本。"]
        )
    }
}

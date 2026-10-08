import CoreText
import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import ETOSCore

struct FontConfigurationLibraryTests {
    @Test("字体路由沿用文件格式，保留语言分组与指定文字规则")
    func compatibleRouteRoundTrip() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = FontConfigurationLibrary(directory: fixture.root), original = try await store.snapshot()
        var routes = original.routes
        routes.body = [fixture.second.id, fixture.first.id]
        routes.customTextRules = [.init(exactText: "目标", fontAssetIDs: [fixture.second.id])]
        let saved = try await store.saveRoutes(routes, original: original)
        #expect(saved.routes == routes && saved.assets == original.assets)
        #expect(saved.routes.languageBuckets == original.routes.languageBuckets)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.first.fileName)) == fixture.bytes)
    }

    @Test("原清单或路由已变化时拒绝旧草稿且不覆盖新内容")
    func staleSnapshotIsRejected() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = FontConfigurationLibrary(directory: fixture.root), original = try await store.snapshot()
        var routes = original.routes; routes.code.reverse()
        let latest = try await store.saveRoutes(routes, original: original)
        await #expect(throws: FontConfigurationError.self) { try await store.saveRoutes(original.routes, original: original) }
        #expect(try await store.snapshot() == latest)
        var changed = latest.assets; changed[0].displayName = "其他窗口"
        try JSONEncoder().encode(changed).write(to: fixture.root.appendingPathComponent("font-manifest-v1.json"))
        await #expect(throws: FontConfigurationError.self) { try await store.saveRoutes(routes, original: latest) }
    }

    @Test("未知字体与重复优先级不会进入保存文件")
    func invalidChainsAreRejected() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = FontConfigurationLibrary(directory: fixture.root), original = try await store.snapshot()
        for chain in [[UUID()], [fixture.first.id, fixture.first.id]] {
            var routes = original.routes; routes.body = chain
            await #expect(throws: FontConfigurationError.self) { try await store.saveRoutes(routes, original: original) }
        }
        #expect(try await store.snapshot() == original)
    }

    @Test("删除字体同步清理四个槽位、语言分组与规则，保留其他文件")
    func deletionRemovesEveryReference() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = FontConfigurationLibrary(directory: fixture.root), original = try await store.snapshot()
        let saved = try await store.delete(fixture.first.id, original: original)
        #expect(saved.assets == [fixture.second])
        for role in FontSemanticRole.allCases { #expect(saved.routes.chain(for: role) == [fixture.second.id]) }
        #expect(saved.routes.customTextRules[0].fontAssetIDs == [fixture.second.id])
        #expect(saved.routes.languageBuckets["zh"]?.body == [fixture.second.id])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(fixture.first.fileName).path))
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.second.fileName)) == fixture.bytes)
    }

    @Test("同名字体文件被替换时旧删除确认无效")
    func replacedFontIsNotDeleted() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = FontConfigurationLibrary(directory: fixture.root), original = try await store.snapshot()
        let target = fixture.root.appendingPathComponent(fixture.first.fileName), replacement = Data("替换后的字体".utf8)
        try replacement.write(to: target, options: [.atomic])
        await #expect(throws: FontConfigurationError.self) { try await store.delete(fixture.first.id, original: original) }
        #expect(try Data(contentsOf: target) == replacement)
        #expect(try await store.snapshot() == original)
    }

    @Test("第二个元数据文件写入失败时恢复原路由和待删除字体")
    func failedManifestRestoresFiles() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = FontConfigurationLibrary(directory: fixture.root) { data, url in
            if url.lastPathComponent == "font-manifest-v1.json" { throw FontLibraryError.saveFailed }
            try data.write(to: url, options: [.atomic])
        }
        let original = try await store.snapshot()
        await #expect(throws: FontLibraryError.self) { try await store.delete(fixture.first.id, original: original) }
        #expect(try await store.snapshot() == original)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.first.fileName)) == fixture.bytes)
    }

    @Test("路径穿越、重复规则和损坏清单不能进入字体编辑器")
    func malformedCatalogIsRejected() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = FontConfigurationLibrary(directory: fixture.root)
        var bad = fixture.first; bad.fileName = "../outside.ttf"
        let path = fixture.root.appendingPathComponent("font-manifest-v1.json")
        try JSONEncoder().encode([bad]).write(to: path)
        await #expect(throws: FontConfigurationError.self) { try await store.snapshot() }
        try Data("{".utf8).write(to: path)
        await #expect(throws: DecodingError.self) { try await store.snapshot() }
        try JSONEncoder().encode([fixture.first, fixture.second]).write(to: path)
        var routes = FontRouteConfiguration(); let rule = ChatAppearanceTextFontRule()
        routes.customTextRules = [rule, rule]
        try JSONEncoder().encode(routes).write(to: fixture.root.appendingPathComponent("font-routes-v1.json"))
        await #expect(throws: FontConfigurationError.self) { try await store.snapshot() }
    }

    @Test("不支持的扩展和损坏字体不会写入清单或候选链")
    func invalidImportDoesNotPublish() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = FontConfigurationLibrary(directory: fixture.root), original = try await store.snapshot()
        for name in ["bad.txt", "bad.ttf"] {
            let url = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + name)
            defer { try? FileManager.default.removeItem(at: url) }
            try Data("不是字体".utf8).write(to: url)
            await #expect(throws: FontLibraryError.self) { try await store.importFile(url, original: original) }
        }
        #expect(try await store.snapshot() == original)
    }

    #if os(macOS)
    @Test("Mac 逐字规则跳过不可用字体，使用后续 CoreText 候选字体")
    func characterRulesSkipMissingFont() async throws {
        let missing = "ELS-Definitely-Missing-Font", font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let name = CTFontCopyPostScriptName(font) as String
        let rule = ChatAppearanceTextFontRule(exactText: "abc", fontAssetIDs: [UUID()])
        let text = try #require(await ChatAppearanceTextRuleRenderer.shared.prepare(request: .init(
            source: "abc", usesMarkdown: false, styleColors: .init(defaultHex: "000000FF"),
            fontRules: [.init(rule: rule, postScriptNames: [missing, name])], fontPointSize: 13,
            fontFallbackScope: .character, semanticFont: .system(size: 13))))
        let rendered = try #require(text.runs.first?.font)
        #expect(rendered != Font.custom(missing, size: 13, relativeTo: .body))
    }

    @Test("真实系统字体导入保留字节、兼容校验和与四个候选链，重复导入不新增")
    func importSystemFontAndDeduplicate() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        let url = try #require(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
        let data = try Data(contentsOf: url), store = FontConfigurationLibrary(directory: fixture.root)
        let original = try await store.snapshot(), saved = try await store.importFile(url, original: original)
        let asset = try #require(saved.assets.first)
        #expect(saved.assets.count == original.assets.count + 1)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(asset.fileName)) == data)
        #expect(asset.checksum == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        for role in FontSemanticRole.allCases { #expect(saved.routes.chain(for: role).last == asset.id) }
        #expect(try await store.importFile(url, original: saved) == saved)
    }
    #endif

    private struct Fixture {
        let root: URL
        let bytes = Data("删除测试只核对内容身份，不注册或解析字形".utf8)
        let first: FontAssetRecord
        let second: FontAssetRecord
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("font-library-\(UUID())")
            let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            first = .init(fileName: "first.ttf", checksum: checksum, displayName: "第一项", postScriptName: "First")
            second = .init(fileName: "second.ttf", checksum: checksum, displayName: "第二项", postScriptName: "Second")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent(first.fileName)); try bytes.write(to: root.appendingPathComponent(second.fileName))
            try JSONEncoder().encode([first, second]).write(to: root.appendingPathComponent("font-manifest-v1.json"))
            let ids = [first.id, second.id]
            let routes = FontRouteConfiguration(body: ids, emphasis: ids, strong: ids, code: ids,
                languageBuckets: ["zh": .init(body: ids, emphasis: ids, strong: ids, code: ids)],
                customTextRules: [.init(exactText: "目标", fontAssetIDs: ids)])
            try JSONEncoder().encode(routes).write(to: root.appendingPathComponent("font-routes-v1.json"))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

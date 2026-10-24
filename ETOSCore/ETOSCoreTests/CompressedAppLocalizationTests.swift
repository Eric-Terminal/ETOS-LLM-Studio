import Foundation
import Testing
import ZIPFoundation
@testable import ETOSCore

@Suite("离线压缩文案")
struct CompressedAppLocalizationTests {
    @Test("压缩文案完整还原多行、Unicode、格式占位符和空值")
    func readsCompressedBinaryTable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let table = ["标题": "設定", "多行": "第一行\n第二行 🐈", "格式": "%@：%lld", "空值": ""]
        let url = directory.appendingPathComponent("ja.zip")
        try writeArchive(table, to: url, directory: directory)
        #expect(try AppLocalizationResources.readArchive(at: url) == table)
    }

    @Test("缺少压缩条目和损坏归档不能被当成有效翻译")
    func rejectsInvalidArchives() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("invalid.zip")
        try Data("不是 ZIP 文件".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            try AppLocalizationResources.readArchive(at: url)
        }
        try FileManager.default.removeItem(at: url)
        try writeArchive(["标题": "Title"], to: url, directory: directory, entryName: "other.strings")
        #expect(throws: (any Error).self) {
            try AppLocalizationResources.readArchive(at: url)
        }
    }

    @Test("缺失键使用英语，显式空翻译不回退，未知键保留调用者默认值")
    func preservesFallbackSemantics() {
        let snapshot = AppLocalizationSnapshot(
            language: "ja", translations: ["标题": "設定", "空值": ""],
            english: ["标题": "Settings", "说明": "Help", "空值": "Not empty"]
        )
        #expect(snapshot.localizedString(forKey: "标题", value: nil) == "設定")
        #expect(snapshot.localizedString(forKey: "说明", value: "调用者默认值") == "Help")
        #expect(snapshot.localizedString(forKey: "空值", value: nil).isEmpty)
        #expect(snapshot.localizedString(forKey: "未知", value: "Default") == "Default")
        #expect(snapshot.localizedString(forKey: "未知", value: "") == "未知")
        #expect(snapshot.localizedString(forKey: "未知", value: nil) == "未知")
    }

    @Test("系统语言匹配地区变体，未知语言使用英语，手动选择不受系统影响")
    func resolvesLanguage() {
        #expect(AppLocalizationResources.language(rawValue: "system", preferredLanguages: ["fr-CA"]) == "fr")
        #expect(AppLocalizationResources.language(rawValue: "system", preferredLanguages: ["zh-Hant-TW"]) == "zh-Hant-HK")
        #expect(AppLocalizationResources.language(rawValue: "system", preferredLanguages: ["de-DE"]) == "en")
        #expect(AppLocalizationResources.language(rawValue: "ja", preferredLanguages: ["en-US"]) == "ja")
        #expect(AppLocalizationResources.language(rawValue: "失效设置", preferredLanguages: ["ru-RU"]) == "ru")
    }

    @Test("后台加载器从原生英语和随包压缩资源生成快照")
    func loadsBundleResources() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Languages.bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "test.languages", "CFBundleDevelopmentRegion": "en"],
            format: .xml, options: 0
        )
        try info.write(to: directory.appendingPathComponent("Info.plist"))
        let english = ["标题": "Settings", "说明": "Help"]
        let englishDirectory = directory.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: englishDirectory, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: english, format: .binary, options: 0)
            .write(to: englishDirectory.appendingPathComponent("Localizable.strings"))
        try writeArchive(
            ["标题": "設定"], to: directory.appendingPathComponent("WatchLocalizable-ja.zip"), directory: directory
        )
        let loader = AppLocalizationResourceLoader(bundle: try #require(Bundle(url: directory)))
        let japanese = try await loader.load(language: "ja")
        #expect(japanese.localizedString(forKey: "标题", value: nil) == "設定")
        #expect(japanese.localizedString(forKey: "说明", value: nil) == "Help")
        let restoredEnglish = try await loader.load(language: "en")
        #expect(restoredEnglish.translations == english)
        let restoredJapanese = try await loader.load(language: "ja")
        #expect(restoredJapanese.translations == japanese.translations)
    }

    @Test("慢速旧请求不会覆盖已经完成的新语言")
    @MainActor
    func discardsStaleLanguageRequest() async {
        let gate = LocalizationLoadGate()
        var installed: [String] = []
        let controller = CompressedAppLanguageController(load: { language in
            if language == "ja" { await gate.suspend() }
            return AppLocalizationSnapshot(language: language, translations: [:], english: [:])
        }, install: { installed.append($0.language) })
        let first = Task { await controller.prepare(rawValue: "ja") }
        await gate.waitUntilSuspended()
        await controller.prepare(rawValue: "fr")
        await gate.resume()
        await first.value
        #expect(installed == ["fr"])
        #expect(controller.state.isReady)
        #expect(controller.state.locale.identifier == "fr")
    }

    @Test("同一语言的并发加载不会恢复旧的系统区域偏好")
    @MainActor
    func keepsLatestLocaleForSameLanguage() async {
        let gate = LocalizationLoadGate()
        let controller = CompressedAppLanguageController(load: { language in
            await gate.suspendFirstRequest()
            return AppLocalizationSnapshot(language: language, translations: [:], english: [:])
        }, install: { _ in })
        let first = Task { await controller.prepare(rawValue: "ja") }
        await gate.waitUntilSuspended()
        await controller.prepare(rawValue: "system", preferredLanguages: ["ja"])
        await gate.resume()
        await first.value
        #expect(controller.state.language == "ja")
        #expect(controller.state.locale == Locale.autoupdatingCurrent)
    }

    @Test("任务取消后不安装语言快照")
    @MainActor
    func respectsCancellation() async {
        let gate = LocalizationLoadGate()
        var didInstall = false
        let controller = CompressedAppLanguageController(load: { language in
            await gate.suspend()
            return AppLocalizationSnapshot(language: language, translations: [:], english: [:])
        }, install: { _ in didInstall = true })
        let task = Task { await controller.prepare(rawValue: "ja") }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.resume()
        await task.value
        #expect(!didInstall)
        #expect(!controller.state.isReady)
    }

    @Test("压缩语言读取失败后仍可离线进入英语界面")
    @MainActor
    func fallsBackToEnglish() async {
        var installed: String?
        let controller = CompressedAppLanguageController(load: { language in
            if language != "en" { throw AppLocalizationResources.ResourceError.invalidTable }
            return AppLocalizationSnapshot(language: "en", translations: ["标题": "Settings"], english: [:])
        }, install: { installed = $0.language })
        await controller.prepare(rawValue: "ar")
        #expect(installed == "en")
        #expect(controller.state.isReady)
        #expect(controller.state.locale.identifier == "en")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeArchive(
        _ table: [String: String], to url: URL, directory: URL, entryName: String = "Localizable.strings"
    ) throws {
        let source = directory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0).write(to: source)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: entryName, fileURL: source, compressionMethod: .deflate)
    }
}

private actor LocalizationLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didSuspend = false

    func suspendFirstRequest() async {
        guard !didSuspend else { return }
        didSuspend = true
        await suspend()
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilSuspended() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

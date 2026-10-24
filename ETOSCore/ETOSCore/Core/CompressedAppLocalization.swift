import Combine
import Foundation
import os.log
import ZIPFoundation

/// 查询阶段只访问已准备好的字典，不能在 NSLocalizedString 的渲染调用链中解压或读取磁盘。
final class AppLocalizationSnapshot: NSObject, @unchecked Sendable {
    let language: String
    let translations: [String: String]
    let english: [String: String]

    init(language: String, translations: [String: String], english: [String: String]) {
        self.language = language
        self.translations = translations
        self.english = english
    }

    func localizedString(forKey key: String, value: String?) -> String {
        translations[key] ?? english[key] ?? (value.flatMap { $0.isEmpty ? nil : $0 } ?? key)
    }
}

enum AppLocalizationResources {
    static let languages = ["en", "ja", "zh-Hans", "zh-Hant-HK", "ru", "fr", "es", "ar"]

    static func language(rawValue: String, preferredLanguages: [String]) -> String {
        let preference = AppLanguagePreference.resolved(rawValue: rawValue)
        if let identifier = preference.localizationIdentifier { return identifier }
        return Bundle.preferredLocalizations(from: languages, forPreferences: preferredLanguages).first ?? "en"
    }

    enum ResourceError: Error {
        case missingLanguage(String)
        case invalidTable
        case invalidChecksum
    }

    static func readTable(_ data: Data) throws -> [String: String] {
        guard let table = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as? [String: String] else {
            throw ResourceError.invalidTable
        }
        return table
    }

    static func readArchive(at url: URL) throws -> [String: String] {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive["Localizable.strings"] else { throw ResourceError.invalidTable }
        var data = Data()
        let checksum = try archive.extract(entry) { data.append($0) }
        guard checksum == entry.checksum else { throw ResourceError.invalidChecksum }
        return try readTable(data)
    }
}

/// Actor 在后台读取随包资源；缓存只保留英语和最近一种语言，避免手表常驻八份字典。
actor AppLocalizationResourceLoader {
    private let bundle: Bundle
    private var english: [String: String]?
    private var current: AppLocalizationSnapshot?

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    func load(language: String) throws -> AppLocalizationSnapshot {
        if let current, current.language == language { return current }
        let fallback: [String: String]
        if let english {
            fallback = english
        } else {
            guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj") else {
                throw AppLocalizationResources.ResourceError.missingLanguage("en")
            }
            fallback = try AppLocalizationResources.readTable(Data(contentsOf: url))
            english = fallback
        }
        let translations: [String: String]
        if language == "en" {
            translations = fallback
        } else {
            let name = "WatchLocalizable-\(language)"
            guard let url = bundle.url(forResource: name, withExtension: "zip", subdirectory: "Localizations")
                ?? bundle.url(forResource: name, withExtension: "zip") else {
                throw AppLocalizationResources.ResourceError.missingLanguage(language)
            }
            translations = try AppLocalizationResources.readArchive(at: url)
        }
        let snapshot = AppLocalizationSnapshot(language: language, translations: translations, english: fallback)
        current = snapshot
        return snapshot
    }
}

@MainActor
public final class CompressedAppLanguageController: ObservableObject {
    public static let shared = CompressedAppLanguageController()

    public struct State {
        public let isReady: Bool
        public let locale: Locale
        public let language: String?
    }

    @Published public private(set) var state = State(isReady: false, locale: .autoupdatingCurrent, language: nil)
    private let load: @Sendable (String) async throws -> AppLocalizationSnapshot
    private let install: @MainActor (AppLocalizationSnapshot) -> Void
    private var requestGeneration = 0
    private var requestedLanguage: String?
    private var requestedPreference = AppLanguagePreference.defaultLanguage.rawValue
    private let logger = Logger(subsystem: "com.ETOS.LLM.Studio", category: "Localization")

    public convenience init(bundle: Bundle = .main) {
        let loader = AppLocalizationResourceLoader(bundle: bundle)
        self.init(
            load: { language in try await loader.load(language: language) },
            install: { AppLanguageRuntime.installCompressedSnapshot($0) }
        )
    }

    init(
        load: @escaping @Sendable (String) async throws -> AppLocalizationSnapshot,
        install: @escaping @MainActor (AppLocalizationSnapshot) -> Void
    ) {
        self.load = load
        self.install = install
    }

    /// App Intent 可以在首屏任务之前执行，必须使用同一加载器准备其动态回复。
    public static func prepareConfiguredLanguage() async {
        await shared.prepare(rawValue: AppConfigStore.shared.appLanguage)
    }

    public func prepare(rawValue: String, preferredLanguages: [String] = Locale.preferredLanguages) async {
        requestGeneration += 1
        let generation = requestGeneration
        let language = AppLocalizationResources.language(rawValue: rawValue, preferredLanguages: preferredLanguages)
        requestedLanguage = language
        requestedPreference = rawValue
        let snapshot: AppLocalizationSnapshot?
        do {
            snapshot = try await load(language)
        } catch {
            logger.error("离线文案加载失败，使用英语：\(String(describing: error), privacy: .public)")
            snapshot = try? await load("en")
        }
        // 快速切换、系统语言变化或视图任务取消后，旧读取结果不能覆盖新的选择。
        // 首屏和 App Intent 可同时请求同一种语言，任一读取完成即可准备动态回复。
        guard generation == requestGeneration || (language == requestedLanguage && snapshot?.language == language),
              !Task.isCancelled else { return }
        if let snapshot {
            install(snapshot)
        } else {
            AppLanguageRuntime.apply(rawValue: AppLanguagePreference.english.rawValue)
        }
        let locale = snapshot?.language == language
            ? AppLanguagePreference.preferredLocale(rawValue: requestedPreference)
            : Locale(identifier: "en")
        // 一次发布同时更新首屏门禁和 Locale，安装字典后再让 SwiftUI 重算文案。
        state = State(isReady: true, locale: locale, language: snapshot?.language ?? "en")
    }
}

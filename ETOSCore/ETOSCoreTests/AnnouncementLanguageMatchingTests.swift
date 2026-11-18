import Testing
import Foundation
@testable import ETOSCore

@Suite("公告语言匹配测试")
@MainActor
struct AnnouncementLanguageMatchingTests {
    @Test("公告统一从反馈服务域名获取")
    func announcementUsesUnifiedServiceEndpoint() {
        #expect(AnnouncementManager.announcementURL.host == "feedback.els.ericterminal.com")
        #expect(AnnouncementManager.announcementURL.path == "/v1/announcements")
    }

    @Test("简体环境只命中 zh-Hans，不命中 zh-Hant")
    func simplifiedLocaleMatchesOnlyHans() {
        let hans = AnnouncementManager.languageMatchScore(
            announcementLanguage: "zh-Hans",
            deviceLanguageCode: "zh",
            deviceLocaleIdentifier: "zh_CN"
        )
        let hant = AnnouncementManager.languageMatchScore(
            announcementLanguage: "zh-Hant",
            deviceLanguageCode: "zh",
            deviceLocaleIdentifier: "zh_CN"
        )

        #expect(hans > 0)
        #expect(hant == 0)
    }

    @Test("繁体环境只命中 zh-Hant，不命中 zh-Hans")
    func traditionalLocaleMatchesOnlyHant() {
        let hant = AnnouncementManager.languageMatchScore(
            announcementLanguage: "zh-Hant",
            deviceLanguageCode: "zh",
            deviceLocaleIdentifier: "zh_HK"
        )
        let hans = AnnouncementManager.languageMatchScore(
            announcementLanguage: "zh-Hans",
            deviceLanguageCode: "zh",
            deviceLocaleIdentifier: "zh_HK"
        )

        #expect(hant > 0)
        #expect(hans == 0)
    }

    @Test("中文脚本匹配优先级高于泛 zh 匹配")
    func scriptSpecificChineseMatchBeatsGenericZh() {
        let specific = AnnouncementManager.languageMatchScore(
            announcementLanguage: "zh-Hans",
            deviceLanguageCode: "zh",
            deviceLocaleIdentifier: "zh_CN"
        )
        let generic = AnnouncementManager.languageMatchScore(
            announcementLanguage: "zh",
            deviceLanguageCode: "zh",
            deviceLocaleIdentifier: "zh_CN"
        )

        #expect(specific > generic)
    }

    @Test("翻译采用手动选择的语言，跟随系统时支持没有内置文案的语言")
    func translationTargetRespectsReadingPreference() {
        #expect(AnnouncementTranslation.targetLanguage(for: .japanese, systemLanguage: "sw-KE") == "ja")
        #expect(AnnouncementTranslation.targetLanguage(for: .system, systemLanguage: "sw-KE") == "sw-KE")
    }

    @Test("重新解码保留原公告的隐藏标识，同 ID 不同文案独立展示")
    func decodingPreservesContentIdentity() throws {
        let first = Announcement(id: 10, type: .warning, title: "Update", body: "A")
        let second = Announcement(id: 10, type: .warning, title: "Update", body: "B")
        let decoded = try JSONDecoder().decode(Announcement.self, from: JSONEncoder().encode(first))
        #expect(decoded.uniqueKey == Announcement.hashKey("10|warning|||Update|A"))
        #expect(decoded.uniqueKey == first.uniqueKey)
        #expect(decoded.uniqueKey != second.uniqueKey)
    }

    @Test("阅读语言相同可直接显示，书写系统不同仍可翻译", arguments: [
        ("zh-Hans", "zh_CN", false), ("zh-Hans", "zh-Hant-HK", true),
        ("zh-TW", "zh-Hant-HK", false), ("en-US", "en-GB", false),
        ("en", "sw-KE", true), ("sr-Cyrl", "sr-Latn", true)
    ])
    func translationAvailability(source: String, target: String, expected: Bool) {
        let item = Announcement(id: 1, type: .info, language: source, title: "ETOS", body: "v1.2")
        #expect(AnnouncementTranslation.needsTranslation(item, targetLanguage: target) == expected)
    }

    @Test("无标签公告按实际显示的文字识别")
    func recognizesDisplayedText() {
        let item = Announcement(id: 1, type: .info, title: "Scheduled maintenance",
                                body: "We will update the service on Monday morning. You can continue reading your saved conversations during the update.")
        #expect(!AnnouncementTranslation.needsTranslation(item, targetLanguage: "en-AU"))
        #expect(AnnouncementTranslation.needsTranslation(item, targetLanguage: "ja"))
        let empty = Announcement(id: 2, type: .info, title: "", body: "")
        #expect(!AnnouncementTranslation.needsTranslation(empty, targetLanguage: "en"))
    }

    @Test("泛中文公告根据实际用字区分简繁")
    func recognizesGenericChineseScript() {
        let item = Announcement(id: 1, type: .info, language: "zh", title: "軟體更新通知",
                                body: "請先儲存變更，再關閉應用程式。重新啟動後，即可繼續閱讀對話記錄。")
        #expect(!AnnouncementTranslation.needsTranslation(item, targetLanguage: "zh-Hant-HK"))
        #expect(AnnouncementTranslation.needsTranslation(item, targetLanguage: "zh-Hans"))
    }

    @Test("翻译可保留 Markdown 与换行，缺少标题或正文时保留原文")
    func completeTranslationRequired() throws {
        let original = AnnouncementText(title: "Update", body: "First line\n\n[Details](https://example.com)")
        let translated = AnnouncementText(title: "更新", body: "第一行\n\n[详情](https://example.com)")
        let json = String(decoding: try JSONEncoder().encode(translated), as: UTF8.self)
        #expect(try AnnouncementTranslation.translatedText(from: "```json\n\(json)\n```", original: original) == translated)
        for incomplete in [#"{"title":"更新"}"#, #"{"title":" ","body":"正文"}"#, ""] {
            #expect(throws: AnnouncementTranslation.TranslationError.self) {
                try AnnouncementTranslation.translatedText(from: incomplete, original: original)
            }
        }
    }

    @Test("公告详情引用的翻译说明可以从向导检索")
    func guideExplainsTranslation() async {
        let references = await GuideKnowledgeService().search("公告翻译", limit: 1)
        #expect(references.first?.id == "announcement-translation")
    }

}

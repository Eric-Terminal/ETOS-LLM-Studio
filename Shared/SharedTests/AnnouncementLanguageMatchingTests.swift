import Testing
@testable import Shared

@Suite("公告语言匹配测试")
struct AnnouncementLanguageMatchingTests {

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
}

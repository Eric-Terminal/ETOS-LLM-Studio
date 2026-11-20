import Testing
@testable import ETOSCore

struct GuideKnowledgeSearchTests {
    @Test("口语问题能直接找到对应的新手指南", arguments: [
        ("怎么导卡", "roleplay-beginner-guide"), ("404 报错", "troubleshooting-faq"),
        ("这软件有什么功能", "app-features-tour"), ("怎么配API", "getting-started-guide")
    ])
    func beginnerQuestionsFindGuide(query: String, documentID: String) async {
        let result = await GuideKnowledgeService.shared.search(query, limit: 1)
        #expect(result.first?.id == documentID)
    }

    @Test("专属完整关键词优先于正文及泛关键词，整句中文仍能检索")
    func exactKeywordPrecedesBroadMatches() async {
        let service = GuideKnowledgeService(documents: [
            .init(id: "generic", title: "导入", keywords: ["备份"], content: "可以导入云备份"),
            .init(id: "specific", title: "快照上传", keywords: ["云备份"], content: "上传配置")
        ])
        #expect(await service.search("云备份", limit: 1).first?.id == "specific")
        #expect(await service.search("如何配置云备份上传").contains { $0.id == "specific" })
        #expect(await service.search("").isEmpty)
    }
}

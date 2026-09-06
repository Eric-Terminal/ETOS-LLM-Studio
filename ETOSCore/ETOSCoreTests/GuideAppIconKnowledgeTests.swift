import Testing
@testable import ETOSCore

struct GuideAppIconKnowledgeTests {
    @Test("主屏幕图标问题可检索到专属教程而非普通快捷指令工具箱")
    func appIconInstructionsAreDiscoverable() async throws {
        let service = GuideKnowledgeService()
        let references = await service.search("自定义图标", limit: 1)
        #expect(references.first?.id == "settings-app-icon")
        let document = await service.document(id: "settings-app-icon")
        #expect(document != nil)
        #expect(GuideDocumentCatalog.documents.filter { $0.id == "settings-app-icon" }.count == 1)
    }
}

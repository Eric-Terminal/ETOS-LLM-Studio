import Testing
@testable import ETOSCore

struct GuideBackgroundCropKnowledgeTests {
    @Test("背景裁切文档说明动态比例、只读上下文和手动保存边界")
    func documentsCropDraftBoundary() throws {
        let document = try #require(GuideDocumentCatalog.documents.first { $0.id == "settings-display" })
        #expect(document.content.contains("随 iPhone Duo 折叠、展开以及 iPad 分屏更新"))
        #expect(document.content.contains("裁切弹窗是独立的只读向导页面"))
        #expect(document.content.contains("不发送图片数据或文件路径"))
        #expect(document.content.contains("须手动点击“保存”才创建背景"))
    }
}

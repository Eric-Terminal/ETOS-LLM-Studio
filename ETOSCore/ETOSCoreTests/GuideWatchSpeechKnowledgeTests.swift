import Testing
@testable import ETOSCore

struct GuideWatchSpeechKnowledgeTests {
    @Test("手表语音指引区分系统键盘听写与本地或云端录音转写")
    func distinguishesWatchSpeechRoutes() throws {
        let document = try #require(GuideDocumentCatalog.documents.first { $0.id == "speech-input" })
        #expect(document.content.contains("不提供 SFSpeechRecognizer 系统模型"))
        #expect(document.content.contains("系统键盘中的听写按钮"))
        #expect(document.content.contains("无需配置转写模型或开启 App 的语音输入开关"))
        #expect(document.content.contains("已保存的模型选择失效时改用列表首项"))
    }
}

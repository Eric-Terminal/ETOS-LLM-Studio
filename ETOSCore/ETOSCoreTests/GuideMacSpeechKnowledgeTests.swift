import Foundation
import Testing
@testable import ETOSCore

struct GuideMacSpeechKnowledgeTests {
    @Test("语音指引区分草稿、音频、手动转写与迟到权限的隐私边界")
    func speechGuidance() {
        let chinese = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "zh-Hans")).content
        #expect(chinese.contains("最终发送仍手动进行"))
        #expect(chinese.contains("迟到授权不会重新录音"))
        #expect(chinese.contains("不包含录音、路径或识别正文"))
        #expect(chinese.contains("转写前核对模型配置"))
        let english = GuideMacWorkspaceKnowledge.document(locale: Locale(identifier: "en")).content
        #expect(english.contains("cancellation does not retry other locales"))
        #expect(english.contains("Unsent audio stays in memory"))
        #expect(english.contains("the guide cannot record, transcribe, play, insert, send or grant permission"))
    }
}

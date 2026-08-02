import Foundation
import Testing
@testable import ETOSCore

@Suite("生成时自动朗读分段测试")
struct BackgroundReplySpeechChunkerTests {
    @Test("生成时自动朗读默认关闭且仅保存在本机")
    func streamingSpeechDefaultsToLocalOptIn() {
        #expect(AppConfigKey.streamingReplySpeechEnabled.defaultValue == .bool(false))
        #expect(!AppConfigKey.streamingReplySpeechEnabled.participatesInSync)
    }

    @Test("只返回已经结束的完整句子")
    func extractsOnlyStableSentence() {
        let firstSentence = "这是一个已经完整生成的句子。"
        let content = firstSentence + "后半句仍在生成"

        let chunk = BackgroundReplySpeechChunker.nextChunk(
            in: content,
            consumedUTF16Length: 0,
            isFinal: false
        )

        #expect(chunk?.text == firstSentence)
        #expect(chunk?.consumedUTF16Length == (firstSentence as NSString).length)
    }

    @Test("不会朗读尚未结束的流式文本")
    func ignoresIncompleteText() {
        let chunk = BackgroundReplySpeechChunker.nextChunk(
            in: "这段回复还没有生成完",
            consumedUTF16Length: 0,
            isFinal: false
        )

        #expect(chunk == nil)
    }

    @Test("完成时会朗读最后一段无标点文本")
    func flushesRemainderWhenFinished() {
        let content = "最后一段没有结束标点"
        let chunk = BackgroundReplySpeechChunker.nextChunk(
            in: content,
            consumedUTF16Length: 0,
            isFinal: true
        )

        #expect(chunk?.text == content)
        #expect(chunk?.consumedUTF16Length == (content as NSString).length)
    }

    @Test("增量提取不会重复已经朗读的句子")
    func resumesAfterConsumedPrefix() {
        let firstSentence = "第一段已经完整生成。"
        let secondSentence = "第二段也已经完整生成！"
        let chunk = BackgroundReplySpeechChunker.nextChunk(
            in: firstSentence + secondSentence,
            consumedUTF16Length: (firstSentence as NSString).length,
            isFinal: false
        )

        #expect(chunk?.text == secondSentence)
        #expect(chunk?.consumedUTF16Length == ((firstSentence + secondSentence) as NSString).length)
    }

    @Test("长回复会限制单次交给朗读器的文本长度")
    func capsLongFinalChunk() {
        let content = String(repeating: "字", count: 1_000)
        let chunk = BackgroundReplySpeechChunker.nextChunk(
            in: content,
            consumedUTF16Length: 0,
            isFinal: true
        )

        #expect(chunk?.consumedUTF16Length == 640)
        #expect(chunk.map { ($0.text as NSString).length } == 640)
    }
}

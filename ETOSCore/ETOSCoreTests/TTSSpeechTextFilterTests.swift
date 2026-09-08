import Foundation
import Testing
@testable import ETOSCore

@Suite("TTS 代码与 HTML 内容过滤")
struct TTSSpeechTextFilterTests {
    @Test("HTML 围栏保留正文并移除属性、脚本、样式及注释", arguments: [false, true])
    func htmlBodySurvivesBothPreprocessingModes(lightweight: Bool) {
        let source = """
        开场。
        ```html
        <!doctype html><html><head><title>内部标题</title><style>.card { color: red; }</style></head>
        <body><div class="card" data-tip="1 > 0"><p>你好，<b>旅行者</b>。</p><p>欢迎回来。</p></div>
        <!-- 不朗读的注释 --><script>const value = "<div>脚本内容</div>";</script></body></html>
        ```
        结束。
        """
        #expect(prepare(source, lightweight: lightweight) == "开场。\n你好，旅行者。\n欢迎回来。\n结束。")
    }

    @Test("裸 HTML 的属性引号不会被选作台词")
    func quoteSelectionRunsAfterFiltering() {
        let source = #"<div class="card" title='说明'>旁白。<p>她说：&ldquo;你好，世界。&rdquo;</p></div>"#
        #expect(prepare(source, mode: .quotedOnly) == "你好，世界。")
    }

    @Test("HTML 斜体与 Markdown 斜体仍可组合筛选")
    func italicSelectionKeepsSemanticBoundaries() {
        let source = #"<p>普通 <i class="voice">第一段</i> 和 *第二段*。</p>"#
        #expect(prepare(source, mode: .italicOnly) == "第一段\n第二段")
        #expect(prepare(source, mode: .nonItalic) == "普通 和 。")
        #expect(prepare(source, mode: .fullText) == "普通 第一段 和 第二段。")
    }

    @Test("括号筛选作用于 HTML 正文")
    func parenthesesSelectionUsesVisibleText() {
        #expect(prepare("<p>你好（挥手），欢迎。</p>", mode: .outsideParentheses) == "你好 ，欢迎。")
    }

    @Test("没有引号时只回退到过滤后的正文")
    func fallbackCannotRestoreCode() {
        let source = """
        <p class="不要读属性">正常正文。</p>
        ```javascript
        console.log("不要读代码");
        ```
        """
        #expect(prepare(source, mode: .quotedOnly) == "正常正文。")
    }

    @Test("纯代码或隐藏内容不会触发全文回退", arguments: TTSTextSelectionMode.allCases)
    func codeOnlyHasNoSpeech(mode: TTSTextSelectionMode) {
        let source = """
        ```swift
        print("不要读我")
        ```
        <style>.hidden { display: none; }</style><script>alert("不要读我");</script>
        <pre><code>不要读我</code></pre><!-- 不要读我 -->
        """
        #expect(prepare(source, mode: mode).isEmpty)
    }

    @Test("波浪线围栏、长围栏、无语言 HTML 与行内代码均可处理")
    func differentCodeDelimitersAreHandled() {
        let source = """
        ~~~html
        <p>第一段</p>
        ~~~
        ````javascript
        ```
        console.log("不朗读");
        ````
        ```
        <p>第二段</p>
        ```
        前 `let x = 1` 后 ``<b>`code`</b>``。
        """
        #expect(prepare(source) == "第一段\n第二段\n前 后 。")
    }

    @Test("未闭合的普通代码围栏跳过余下源码，HTML 围栏仍保留已输出正文")
    func unfinishedFencesDoNotReadSourceCode() {
        #expect(prepare("正文\n```js\nalert('不要读')") == "正文")
        #expect(prepare("```html\n<p>已输出正文</p><script>未完成脚本") == "已输出正文")
        #expect(prepare("<p>正文</p><div title=\"未闭合属性") == "正文")
    }

    @Test("显式隐藏的节点被跳过，普通属性值中的 hidden 不影响正文")
    func hiddenNodesAreExcluded() {
        let source = #"<div hidden><span>隐藏</span></div><p style="display: none !important">隐藏</p><p style='visibility:hidden'>隐藏</p><p title="hidden">可见</p>"#
        #expect(prepare(source) == "可见")
    }

    @Test("HTML 实体恢复文字而不重新解析解码后的尖括号")
    func entitiesAndComparisonsRemainReadable() {
        let source = "<p>Tom &amp; Jerry&nbsp;&#20320;&#x597D; &lt;b&gt; &quot;台词&quot;</p><p>1 < 2，3 > 2</p>"
        #expect(prepare(source) == "Tom & Jerry 你好 <b> \"台词\"\n1 < 2，3 > 2")
        #expect(prepare(source, mode: .quotedOnly) == "台词")
    }

    @Test("长度预算不被 HTML 样式耗尽")
    func characterLimitAppliesToFilteredBody() {
        let source = "<style>" + String(repeating: "body { color: red; }", count: 100)
            + "</style><p>一二三四五六七八九十</p>"
        #expect(prepare(source, maxCharacters: 5) == "一二三四五")
    }

    @Test("关闭过滤时保留现有轻量预处理行为")
    func disabledFilterPreservesLightweightInput() {
        let source = #"<div class="card">原文</div>"#
        #expect(TTSManager.preprocessText(
            source, mode: .fullText, filterCodeAndHTML: false,
            lightweight: true, maxCharacters: 6_000
        ) == source)
    }

    @Test("过滤设置默认关闭并随配置同步")
    func configurationDefaultsAndSyncPolicy() {
        #expect(AppConfigKey.ttsFilterCodeAndHTML.defaultValue == .bool(false))
        #expect(AppConfigKey.ttsFilterCodeAndHTML.participatesInSync)
    }

    @MainActor
    @Test("同步导入过滤开关后，页面状态和导出快照保持一致")
    func importedSettingUpdatesPublishedStateAndSnapshot() {
        let store = AppConfigStore.shared
        let previous = store.ttsFilterCodeAndHTML
        defer { store.ttsFilterCodeAndHTML = previous }
        let key = AppConfigKey.ttsFilterCodeAndHTML
        store.apply(snapshot: [key.rawValue: !previous])
        #expect(store.ttsFilterCodeAndHTML == !previous)
        #expect(store.value(for: key) == .bool(!previous))
        #expect(store.snapshot()[key.rawValue] as? Bool == !previous)
    }

    @Test("向导可检索过滤说明及对应字段")
    func guideExplainsFilteringAndItsLimits() async throws {
        let service = GuideKnowledgeService()
        let references = await service.search("代码过滤", limit: 3)
        #expect(references.contains { $0.id == "tts" })
        let document = try #require(await service.document(id: "tts"))
        #expect(document.content.contains("filter_code_and_html"))
        #expect(document.content.contains("原生确认"))
        #expect(document.content.contains("不运行 JavaScript"))
    }

    @MainActor
    @Test("停止会取消待处理的朗读，旧结果不能恢复播放")
    func stopCancelsPendingPreparation() async {
        let manager = TTSManager()
        manager.speak("准备朗读的正文。")
        let pending = manager.preparationTask
        manager.stop()
        await pending?.value
        #expect(manager.queue.isEmpty)
        #expect(manager.workerTask == nil)
        #expect(!manager.isSpeaking)
        #expect(manager.playbackState.status == .idle)
    }

    @MainActor
    @Test("预处理期间暂停后仍可恢复到加载状态")
    func pendingPreparationCanPauseAndResume() async {
        let manager = TTSManager()
        manager.speak("准备朗读的正文。")
        let pending = manager.preparationTask
        manager.pause()
        #expect(manager.isPausedByUser)
        #expect(manager.playbackState.status == .paused)
        manager.resume()
        #expect(!manager.isPausedByUser)
        #expect(manager.playbackState.status == .buffering)
        manager.stop()
        await pending?.value
    }

    @MainActor
    @Test("新的空朗读替换旧请求后不会重新播放旧正文")
    func replacementInvalidatesPreviousPreparation() async {
        let manager = TTSManager()
        manager.speak("旧正文。")
        let previous = manager.preparationTask
        manager.speak("   ")
        await manager.preparationTask?.value
        await previous?.value
        #expect(manager.queue.isEmpty)
        #expect(manager.lastReplayRequest == nil)
        #expect(!manager.isSpeaking)
        #expect(manager.playbackState.status == .idle)
    }

    private func prepare(
        _ text: String,
        mode: TTSTextSelectionMode = .fullText,
        lightweight: Bool = false,
        maxCharacters: Int = 12_000
    ) -> String {
        TTSManager.preprocessText(
            text, mode: mode, filterCodeAndHTML: true,
            lightweight: lightweight, maxCharacters: maxCharacters
        )
    }
}

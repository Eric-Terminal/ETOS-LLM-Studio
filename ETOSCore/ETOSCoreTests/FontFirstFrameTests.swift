import Combine
import Foundation
import SwiftUI
import Testing
@testable import ETOSCore

private final class FontFixtureBundleMarker {}

extension FontRouteSyncTests {
    @Test("英文优先字体缺少中文时，新消息和 Markdown 首帧直接使用第二字体", arguments: [1.0, 1.5])
    @MainActor
    func mixedTextUsesPreparedFontOnFirstFrame(scale: Double) async throws {
        try await withIsolatedFontStore {
            let (latin, mixed) = try installFirstFrameFixtures(scale: scale)
            let message = ChatMessage(role: .user, content: "Hello 中文")
            let snapshot = await Task.detached {
                ChatMessageListSnapshot(messages: [message], sessionID: nil)
            }.value
            let preview = try #require(snapshot.userContentPreviews[message.id])
            let renderState = ChatMessageRenderState(message: message, userContentPreview: preview)
            let fonts = try #require(renderState.textFontSnapshot)
            #expect(fonts.names.body == mixed.postScriptName)
            #expect(FontLibrary.resolvePostScriptName(for: .body, sampleText: "Hello") == latin.postScriptName)

            let expected = Font.custom(mixed.postScriptName, size: 17 * CGFloat(scale), relativeTo: .body)
            let state = ETPreparedFontState()
            state.request = ETFontPreparationRequest(
                descriptor: .body, sampleText: preview.content, text: nil,
                locale: Locale(identifier: "zh_CN"), calendar: Calendar(identifier: .gregorian),
                timeZone: TimeZone(secondsFromGMT: 0)!, sizeCategory: .extraExtraLarge,
                revision: FontLibrary.adapterCacheToken(), textFontSnapshot: fonts
            )
            // 在让出 MainActor 之前检查首帧，不能靠等待后台任务让这个断言通过。
            #expect(state.displayFont == expected)
            #expect(!state.needsPreparation)
            let markdown = ETPreparedMarkdownFontState()
            markdown.request = ETMarkdownFontRequest(
                sampleText: preview.content, revision: FontLibrary.adapterCacheToken(), textFontSnapshot: fonts
            )
            #expect(markdown.displayNames.body == mixed.postScriptName)
            #expect(markdown.displayNames.strong == nil)
            #expect(!markdown.needsPreparation)

            let export = ETFontExportPreparation()
            let renderer = ImageRenderer(content: Text(verbatim: preview.content)
                .modifier(ETFontModifier(.body, sampleText: preview.content))
                .environment(\.etTextFontSnapshot, fonts)
                .environment(\.sizeCategory, .extraExtraLarge)
                .environment(\.etFontExportPreparation, export))
            var firstSize = CGSize.zero
            renderer.render { size, _ in firstSize = size }
            let reference = ImageRenderer(content: Text(verbatim: preview.content)
                .font(expected).environment(\.sizeCategory, .extraExtraLarge))
            var expectedSize = CGSize.zero
            reference.render { size, _ in expectedSize = size }
            #expect(firstSize.width > 0)
            #expect(firstSize == expectedSize)
            #expect(try await !export.preparePendingFonts())

            let markdownRenderer = ImageRenderer(content: ETMarkdownFontPreparation(sampleText: preview.content) { names in
                Text(verbatim: preview.content).font(names.body.map {
                    Font.custom($0, size: 17 * CGFloat(scale), relativeTo: .body)
                } ?? .body)
            }
                .environment(\.etTextFontSnapshot, fonts)
                .environment(\.sizeCategory, .extraExtraLarge)
                .environment(\.etFontExportPreparation, export))
            var markdownSize = CGSize.zero
            markdownRenderer.render { size, _ in markdownSize = size }
            #expect(markdownSize == expectedSize)
            #expect(try await !export.preparePendingFonts())
        }
    }

    @Test("字体配置刷新后，即使解析结果相同也通知界面离开临时首选字体")
    @MainActor
    func unchangedResolutionStillPublishesAfterRevisionChange() async throws {
        try await withIsolatedFontStore {
            let (_, mixed) = try installFirstFrameFixtures(scale: 1)
            let state = ETPreparedMarkdownFontState()
            state.request = ETMarkdownFontRequest(sampleText: "Hello 中文", revision: FontLibrary.adapterCacheToken())
            #expect(try await state.prepare())
            #expect(state.displayNames.body == mixed.postScriptName)
            FontLibrary.preloadRuntimeCache(forceReload: true)
            state.request = ETMarkdownFontRequest(sampleText: "Hello 中文", revision: FontLibrary.adapterCacheToken())
            #expect(state.displayNames.body != mixed.postScriptName)
            var notifications = 0
            let subscription = state.objectWillChange.sink { notifications += 1 }
            #expect(try await state.prepare())
            #expect(notifications == 1)
            #expect(state.displayNames.body == mixed.postScriptName)
            subscription.cancel()
        }
    }

    @Test("正文快照独立于共享缓存存活，编辑和字体配置变更不复用旧选择")
    @MainActor
    func preparedFontSurvivesCachePressureAndRejectsStaleContent() async throws {
        try await withIsolatedFontStore {
            let (latin, mixed) = try installFirstFrameFixtures(scale: 1)
            let message = ChatMessage(role: .user, content: "Hello 中文")
            let original = await Task.detached {
                ChatMessageListSnapshot(messages: [message], sessionID: nil)
            }.value
            let preview = try #require(original.userContentPreviews[message.id])
            let fonts = preview.fontSnapshot
            await Task.detached {
                for index in 0..<600 {
                    _ = FontLibrary.resolvePostScriptName(for: .body, sampleText: "Other \(index)")
                }
            }.value
            #expect(fonts.font(for: .body) == Font.custom(mixed.postScriptName, size: 17, relativeTo: .body))
            #expect(fonts.matches(sampleText: message.content, revision: FontLibrary.adapterCacheToken()))
            #expect(!fonts.matches(sampleText: "Hello", revision: FontLibrary.adapterCacheToken()))

            let state = ChatMessageRenderState(message: message, userContentPreview: preview)
            var edited = message
            edited.content = "Hello"
            let editedPreview = await Task.detached { [edited] in
                ChatUserMessagePreview(content: edited.content)
            }.value
            state.updateVisualMessage(edited, fontSnapshot: editedPreview.fontSnapshot)
            #expect(state.textFontSnapshot?.names.body == latin.postScriptName)

            FontLibrary.updateChain([latin.id], for: .body)
            #expect(!fonts.matches(sampleText: message.content, revision: FontLibrary.adapterCacheToken()))
            let refreshed = await Task.detached {
                ChatMessageListSnapshot(messages: [message], sessionID: nil, previous: original)
            }.value
            #expect(refreshed.userContentPreviews[message.id]?.fontSnapshot.names.body == nil)
            FontLibrary.updateRuntimeSettings(isCustomFontEnabled: true, fallbackScope: .character, customFontScale: 1)
            #expect(FontLibrary.resolvePostScriptName(for: .body, sampleText: message.content) == latin.postScriptName)
        }
    }

    private func installFirstFrameFixtures(scale: Double) throws -> (FontAssetRecord, FontAssetRecord) {
        FontLibrary.updateRuntimeSettings(isCustomFontEnabled: true, fallbackScope: .segment, customFontScale: scale)
        let bundle = Bundle(for: FontFixtureBundleMarker.self)
        let records = try ["ELSFontFixtureLatin", "ELSFontFixtureMixed"].map { name in
            let url = try #require(bundle.url(forResource: name, withExtension: "ttf"))
            return try FontLibrary.importFont(data: Data(contentsOf: url), fileName: url.lastPathComponent)
        }
        FontLibrary.updateChain(records.map(\.id), for: .body)
        for role in [FontSemanticRole.emphasis, .strong, .code] {
            FontLibrary.updateChain([], for: role)
        }
        return (records[0], records[1])
    }
}
